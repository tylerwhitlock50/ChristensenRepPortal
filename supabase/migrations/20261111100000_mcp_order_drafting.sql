/*============================================================================
  20261111100000_mcp_order_drafting.sql
  Purpose: the switches, provenance and audit trail that let Claude DRAFT
           portal orders over MCP (docs/plans/mcp-order-creation.md,
           "Scope confirmed by Tyler" + "Revised design").

  The rule this file exists to enforce: Claude never submits. It creates,
  updates and cancels drafts through the mcp_* RPCs (20261111100100); a
  person opens the draft in the portal, ticks the acknowledgement, and
  submit_order(p_order_id, p_acknowledged => true) sends it on. Nothing here
  touches the ERP: Tyler's middleware reads v_orders_ready_for_erp.

  1. feature.mcp_orders (seeded OFF) plus mcp_order_users, the allow-list
     table (one row per person who may draft; no row = not allowed, no
     wildcard). Independent of feature.orders (hand entry). feature_enabled(),
     mcp_orders_user_allowed() and mcp_orders_gate() read them; the gate is
     the SQL authority every mcp_* write RPC calls first. Admins add/remove
     rows in the portal; an MCP session can never write the table.
  2. mcp_tokens.scopes ('orders:draft' is the only scope). mcp_token_create
     gains p_scopes (old 3-arg signature dropped), mcp_token_resolve returns
     scopes. The edge function only honours the scope for header tokens and
     signs it into app_metadata.mcp_scopes; the gate re-checks the claim AND
     the token row.
  3. orders provenance + acknowledgement columns, guarded by a trigger: a
     portal session cannot set or alter them. Only code that sets the
     transaction-local GUC app.mcp_order_write='on' (the mcp_* RPCs and
     submit_order) may.
  4. submit_order(p_order_id, p_acknowledged default false): the live
     20261030140000 body (verified identical to pg_get_functiondef on
     2026-11-11) plus: a non-portal order needs p_acknowledged, and an
     acknowledgement is stamped.
  5. mcp_tool_calls + mcp_log_call(): append-only audit of every MCP write
     tool call, written by the edge function AFTER the RPC's own transaction,
     so refusals are kept too.
  6. v_orders_ready_for_erp: the middleware's stable read of submitted orders.

  View-as: mcp_tool_calls is EXEMPT from the block_writes_while_impersonating
  sweep (like impersonation_events / login_events): it is an audit table, and
  a refused call made while an admin is viewing-as must still be recorded.
  Every other write path stays blocked while viewing-as (orders keeps its
  trigger; mcp_order_users gets one), so a view-as MCP draft fails with
  read_only_while_viewing_as.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The setting and its helpers
--------------------------------------------------------------------------
insert into public.app_settings (setting_key, enabled, params, description) values
  ('feature.mcp_orders', false,
   jsonb_build_object(
     'max_lines', 40,
     'max_units_per_line', 200,
     'max_order_value', 250000,
     'max_drafts_per_user_per_day', 25,
     'duplicate_window_days', 14),
   'Claude drafts portal orders over MCP (a person submits in the portal). '
   'Who may draft: public.mcp_order_users (no row = nobody).')
on conflict (setting_key) do nothing;

create or replace function public.feature_enabled(p_key text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce((select s.enabled from public.app_settings s where s.setting_key = p_key), false);
$$;

comment on function public.feature_enabled(text) is
  'True when the app_settings row exists and is enabled. Missing = off.';

-- Who may draft orders over MCP: one row per person, managed by admins in
-- the portal (Admin -> Feature flags -> Claude order drafting). No row = not
-- allowed; there is no wildcard. Changes take effect on the next tool call.
create table if not exists public.mcp_order_users (
    user_id  uuid primary key references public.profiles (user_id) on delete cascade,
    added_by uuid references public.profiles (user_id) on delete set null default auth.uid(),
    added_at timestamptz not null default now(),
    note     text check (note is null or length(note) <= 200)
);
alter table public.mcp_order_users enable row level security;

comment on table public.mcp_order_users is
  'Allow-list for Claude order drafting (feature.mcp_orders). Admins insert/'
  'delete; a user may read only their own row; an MCP session can never '
  'write it (trg_mcp_order_users_not_from_mcp), so Claude cannot grant itself drafting.';

drop policy if exists "admin reads mcp order users" on public.mcp_order_users;
create policy "admin reads mcp order users" on public.mcp_order_users
  for select to authenticated using ((select public.is_admin()));
drop policy if exists "user reads own mcp order user row" on public.mcp_order_users;
create policy "user reads own mcp order user row" on public.mcp_order_users
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "admin adds mcp order users" on public.mcp_order_users;
create policy "admin adds mcp order users" on public.mcp_order_users
  for insert to authenticated with check ((select public.is_admin()));
drop policy if exists "admin removes mcp order users" on public.mcp_order_users;
create policy "admin removes mcp order users" on public.mcp_order_users
  for delete to authenticated using ((select public.is_admin()));

revoke all on public.mcp_order_users from anon, public, authenticated;
grant select, insert, delete on public.mcp_order_users to authenticated;

-- Every RLS table is read-only while an admin is viewing as a rep (20260901190200).
drop trigger if exists trg_mcp_order_users_no_write_while_viewing_as on public.mcp_order_users;
create trigger trg_mcp_order_users_no_write_while_viewing_as
  before insert or update or delete on public.mcp_order_users
  for each row execute function public.block_writes_while_impersonating();

-- An MCP session (an admin's token included) can never change who may draft.
-- On insert, added_by is always the caller (null for the migration seed), so
-- the "Added by" shown to admins cannot be written by hand.
create or replace function public.mcp_order_users_not_from_mcp()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp' then
    raise exception 'mcp_cannot_change_allow_list: the order-drafting list can only be changed in the portal'
      using errcode = '42501';
  end if;
  if tg_op = 'INSERT' then
    new.added_by := auth.uid();
  end if;
  return coalesce(new, old);
end $$;
revoke execute on function public.mcp_order_users_not_from_mcp() from public, anon, authenticated;

drop trigger if exists trg_mcp_order_users_not_from_mcp on public.mcp_order_users;
create trigger trg_mcp_order_users_not_from_mcp
  before insert or update or delete on public.mcp_order_users
  for each row execute function public.mcp_order_users_not_from_mcp();

-- v1 pilot: Tyler. Nothing is inserted where that account does not exist.
insert into public.mcp_order_users (user_id, added_by, note)
select p.user_id, null, 'v1 pilot'
from public.profiles p
join auth.users u on u.id = p.user_id
where lower(u.email) = 'tylerw@christensenarms.com'
on conflict (user_id) do nothing;

-- Is this user on the order-drafting list with an active profile? The flag
-- itself is checked by the callers. Internal: callers are definer functions.
create or replace function public.mcp_orders_user_allowed(p_user_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select p_user_id is not null and exists (
    select 1
    from public.mcp_order_users m
    join public.profiles p on p.user_id = m.user_id
    where m.user_id = p_user_id and p.active);
$$;

--------------------------------------------------------------------------
-- 2. Token scopes
--------------------------------------------------------------------------
alter table public.mcp_tokens
  add column if not exists scopes text[] not null default '{}';

alter table public.mcp_tokens drop constraint if exists mcp_tokens_scopes_known;
alter table public.mcp_tokens
  add constraint mcp_tokens_scopes_known check (scopes <@ array['orders:draft']::text[]);

comment on column public.mcp_tokens.scopes is
  'Write scopes. ''orders:draft'' lets Claude create/update/cancel order DRAFTS '
  '(never submit). Honoured only for header-delivered tokens, while '
  'feature.mcp_orders is on and the user is allowed. Empty = read-only.';

-- The ConnectView list shows which tokens can draft orders.
grant select (scopes) on public.mcp_tokens to authenticated;

-- The gate: SQL authority for every mcp_* write RPC. Raises 'code: text';
-- returns the feature params when every check passes.
create or replace function public.mcp_orders_gate()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_app    jsonb := coalesce(auth.jwt() -> 'app_metadata', '{}'::jsonb);
  v_set    record;
  v_tok    text;
  v_scopes text[];
begin
  select s.enabled, s.params into v_set
  from public.app_settings s where s.setting_key = 'feature.mcp_orders';
  if not found then
    raise exception 'mcp_orders_disabled: drafting orders over MCP is turned off';
  end if;
  if not coalesce(v_set.enabled, false) then
    raise exception 'mcp_orders_disabled: drafting orders over MCP is turned off';
  end if;

  if v_uid is null or v_app ->> 'provider' is distinct from 'mcp' then
    raise exception 'not_mcp_session: order drafting is only available to an MCP client';
  end if;

  if jsonb_typeof(v_app -> 'mcp_scopes') is distinct from 'array'
     or not (v_app -> 'mcp_scopes') ? 'orders:draft' then
    raise exception 'mcp_scope_missing: this connection is read-only (the token has no orders:draft scope, or it was sent in the URL instead of a header)';
  end if;

  -- The claim is signed by the edge function; the token row is the truth.
  -- A token revoked (or narrowed) in the last five minutes stops here.
  v_tok := v_app ->> 'mcp_token_id';
  if v_tok is null or v_tok !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'not_mcp_session: the session carries no MCP token';
  end if;
  select t.scopes into v_scopes
  from public.mcp_tokens t
  where t.id = v_tok::uuid
    and t.user_id = v_uid
    and t.revoked_at is null
    and t.expires_at > now();
  if not found then
    raise exception 'not_mcp_session: the MCP token is revoked, expired or not yours';
  end if;
  if not ('orders:draft' = any (v_scopes)) then
    raise exception 'mcp_scope_missing: the token has no orders:draft scope';
  end if;

  -- Active first: mcp_orders_user_allowed() is false for an inactive
  -- profile too, and the clearer reason should win.
  if not exists (select 1 from public.profiles p where p.user_id = v_uid and p.active) then
    raise exception 'account_inactive: your account has been deactivated';
  end if;

  if not public.mcp_orders_user_allowed(v_uid) then
    raise exception 'mcp_user_not_allowed: your account is not enabled for drafting orders over MCP';
  end if;

  return v_set.params;
end;
$$;

comment on function public.mcp_orders_gate() is
  'Every mcp_* write RPC calls this first. Raises mcp_orders_disabled, '
  'not_mcp_session, mcp_scope_missing, mcp_user_not_allowed or '
  'account_inactive (message ''code: text''); returns feature.mcp_orders params.';

-- mcp_token_create: adding p_scopes changes the signature, so drop the
-- 3-arg version (create or replace would add an overload). Body = the live
-- pg_get_functiondef (2026-11-11) plus the scope block.
drop function if exists public.mcp_token_create(text, uuid, int);

create function public.mcp_token_create(
    p_name    text   default 'Claude',
    p_user_id uuid   default null,
    p_days    int    default 365,
    p_scopes  text[] default '{}'
)
returns table (
    token_id   uuid,
    token      text,
    token_name text,
    expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_caller  uuid := auth.uid();
    v_target  uuid;
    v_token   text;
    v_name    text;
    v_days    int;
    v_live    int;
    v_id      uuid;
    v_expires timestamptz;
    v_scopes  text[];
begin
    if v_caller is null then
        raise exception 'not signed in' using errcode = '42501';
    end if;

    v_target := coalesce(p_user_id, v_caller);

    -- Minting FOR SOMEONE ELSE is an admin act. Minting for yourself is not:
    -- the token can only ever reach what you can already reach in the SPA.
    if v_target <> v_caller and not public.is_admin() then
        raise exception 'only an admin can create a token for another user'
          using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.profiles p
        where p.user_id = v_target and p.active
    ) then
        raise exception 'no active profile for that user' using errcode = '23503';
    end if;

    v_name := nullif(pg_catalog.btrim(coalesce(p_name, '')), '');
    if v_name is null then
        v_name := 'Claude';
    end if;
    v_name := pg_catalog.left(v_name, 60);

    -- GREATEST/LEAST are SQL constructs, not functions - they cannot be
    -- schema-qualified, and pinning search_path to '' does not hide them.
    v_days := greatest(1, least(coalesce(p_days, 365), 730));

    -- Scopes: de-duplicated; 'orders:draft' is the only one there is.
    select coalesce(pg_catalog.array_agg(distinct s order by s), '{}'::text[]) into v_scopes
    from pg_catalog.unnest(coalesce(p_scopes, '{}'::text[])) as s
    where s is not null;

    if not (v_scopes operator(pg_catalog.<@) array['orders:draft']::text[]) then
        raise exception 'invalid_scope: the only token scope is orders:draft'
          using errcode = '22023';
    end if;

    if 'orders:draft' = any (v_scopes) then
        -- A write token only for yourself (an admin holding the plaintext of
        -- a rep's drafting token would draft as that rep), only while the
        -- feature is on and the user is allowed, for 90 days at most, and
        -- one live write token per user.
        if v_target <> v_caller then
            raise exception 'invalid_scope: an order-drafting token can only be created for yourself'
              using errcode = '42501';
        end if;
        if not public.feature_enabled('feature.mcp_orders') then
            raise exception 'mcp_orders_disabled: drafting orders over MCP is turned off'
              using errcode = '42501';
        end if;
        if not public.mcp_orders_user_allowed(v_target) then
            raise exception 'mcp_user_not_allowed: that account is not enabled for drafting orders over MCP'
              using errcode = '42501';
        end if;
        v_days := least(v_days, 90);
        if exists (
            select 1 from public.mcp_tokens t
            where t.user_id = v_target
              and t.revoked_at is null
              and t.expires_at > pg_catalog.now()
              and 'orders:draft' = any (t.scopes)
        ) then
            raise exception 'write_token_exists: revoke the existing order-drafting token first';
        end if;
    end if;

    -- A cap, not a policy: five live tokens is more clients than anyone has,
    -- and an unbounded list is how a stale credential hides.
    select pg_catalog.count(*) into v_live
    from public.mcp_tokens t
    where t.user_id = v_target
      and t.revoked_at is null
      and t.expires_at > pg_catalog.now();

    if v_live >= 5 then
        raise exception 'that user already has 5 active tokens - revoke one first';
    end if;

    v_token := 'crp_'
      || pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '')
      || pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '');

    insert into public.mcp_tokens (
        user_id, name, token_prefix, token_hash,
        created_by, expires_at, scopes
    )
    values (
        v_target,
        v_name,
        pg_catalog.left(v_token, 12),
        pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_token, 'UTF8')), 'hex'),
        v_caller,
        pg_catalog.now() + pg_catalog.make_interval(days => v_days),
        v_scopes
    )
    returning mcp_tokens.id, mcp_tokens.expires_at
    into v_id, v_expires;

    token_id   := v_id;
    token      := v_token;
    token_name := v_name;
    expires_at := v_expires;
    return next;
end;
$$;

comment on function public.mcp_token_create(text, uuid, int, text[]) is
  'Mints an MCP token and returns the plaintext ONCE - it is stored hashed '
  'and cannot be recovered. Self-service for the caller; p_user_id requires '
  'is_admin(). Lifetime clamped to 1-730 days, five live tokens per user. '
  'p_scopes: ''{}'' (read-only) or {orders:draft}, which needs feature.mcp_orders '
  'on and the user allowed, lasts 90 days at most, one live per user.';

-- mcp_token_resolve: the return type changes, so drop and recreate. Body =
-- the live pg_get_functiondef (2026-11-11) plus scopes.
drop function if exists public.mcp_token_resolve(text);

create function public.mcp_token_resolve(p_token text)
returns table (
    token_id            uuid,
    user_id             uuid,
    full_name           text,
    user_role           text,
    sales_rep_key       text,
    rep_group_vendor_id text,
    expires_at          timestamptz,
    scopes              text[]
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_hash text;
    v_row  record;
begin
    if p_token is null or pg_catalog.length(p_token) < 20 then
        return;
    end if;

    v_hash := pg_catalog.encode(
        pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8')), 'hex');

    -- An inactive profile must not be reachable by token. This is the hole
    -- 010's closing note describes for account_assignments, closed here at
    -- the door rather than left for the policies: deactivating a user has to
    -- kill their MCP clients too, and unlike a browser JWT this credential
    -- does not expire on its own within the hour.
    --
    -- Every name is table-qualified: the OUT columns of a RETURNS TABLE are
    -- plpgsql variables, so a bare `user_id` here would be ambiguous.
    select t.id            as f_token_id,
           t.user_id       as f_user_id,
           p.full_name     as f_full_name,
           p.role          as f_role,
           p.sales_rep_key as f_rep_key,
           p.rep_group_vendor_id as f_vendor_id,
           t.expires_at    as f_expires,
           t.scopes        as f_scopes
      into v_row
      from public.mcp_tokens t
      join public.profiles p on p.user_id = t.user_id
     where t.token_hash = v_hash
       and t.revoked_at is null
       and t.expires_at > pg_catalog.now()
       and p.active;

    if not found then
        return;
    end if;

    -- last_used_at at most every five minutes: a write per request would put
    -- a row update in front of every tool call for a field nobody reads to
    -- the minute. (Write tools exist now, but they write through their own
    -- RPCs; resolving a token stays as cheap as it was.)
    update public.mcp_tokens t
       set last_used_at = pg_catalog.now()
     where t.id = v_row.f_token_id
       and (t.last_used_at is null
            or t.last_used_at < pg_catalog.now() - pg_catalog.make_interval(mins => 5));

    token_id            := v_row.f_token_id;
    user_id             := v_row.f_user_id;
    full_name           := v_row.f_full_name;
    user_role           := v_row.f_role;
    sales_rep_key       := v_row.f_rep_key;
    rep_group_vendor_id := v_row.f_vendor_id;
    expires_at          := v_row.f_expires;
    scopes              := v_row.f_scopes;
    return next;
end;
$$;

comment on function public.mcp_token_resolve(text) is
  'Resolves a plaintext MCP token to its user and scopes. service_role ONLY - '
  'it is the mcp Edge Function''s single privileged call, made before any data '
  'is read. Rejects revoked, expired, and deactivated-profile tokens.';

revoke execute on function public.mcp_token_create(text, uuid, int, text[]) from public, anon;
revoke execute on function public.mcp_token_resolve(text) from public, anon, authenticated;
grant execute on function public.mcp_token_create(text, uuid, int, text[]) to authenticated, service_role;
grant execute on function public.mcp_token_resolve(text) to service_role;

revoke execute on function public.feature_enabled(text) from public, anon;
grant execute on function public.feature_enabled(text) to authenticated, service_role;
revoke execute on function public.mcp_orders_user_allowed(uuid) from public, anon, authenticated;
revoke execute on function public.mcp_orders_gate() from public, anon;
grant execute on function public.mcp_orders_gate() to authenticated;

--------------------------------------------------------------------------
-- 3. orders: provenance and acknowledgement
--------------------------------------------------------------------------
alter table public.orders
  add column if not exists source               text not null default 'portal',
  add column if not exists created_by           uuid references public.profiles (user_id),
  add column if not exists mcp_token_id         uuid references public.mcp_tokens (id) on delete set null,
  add column if not exists client_request_id    text,
  add column if not exists request_hash         text,
  add column if not exists customer_contact_key text,
  add column if not exists source_ref           jsonb,
  add column if not exists mcp_warnings         jsonb,
  add column if not exists acknowledged_at      timestamptz,
  add column if not exists acknowledged_by      uuid references public.profiles (user_id);

alter table public.orders drop constraint if exists orders_source_check;
alter table public.orders
  add constraint orders_source_check check (source in ('portal', 'mcp', 'inbox'));

create unique index if not exists uq_orders_client_request
  on public.orders (user_id, client_request_id) where client_request_id is not null;
create index if not exists idx_orders_mcp_token
  on public.orders (mcp_token_id) where mcp_token_id is not null;
create index if not exists idx_orders_created_by_day
  on public.orders (created_by, created_at) where source <> 'portal';

comment on column public.orders.source is
  'Who drafted it: portal (typed in the portal), mcp (Claude over MCP), inbox (reserved: the inbox bot).';
comment on column public.orders.created_by is
  'The person (or bot) that made the draft; user_id stays the owner.';
comment on column public.orders.mcp_token_id is
  'The MCP token that drafted this order. Revoke it and its drafts can be found here.';
comment on column public.orders.client_request_id is
  'The MCP client''s idempotency_key; unique per owner. request_hash is the sha256 of the request body.';
comment on column public.orders.customer_contact_key is
  'erp.dim_customer_contact.customer_contact_key of the buyer, when given.';
comment on column public.orders.source_ref is
  'Where the order came from when not typed: {kind:"email", sender, subject, received_at, excerpt}. Untrusted text, shown to the reviewer.';
comment on column public.orders.mcp_warnings is
  'The warnings the MCP draft preview showed (stock, FFL, ship-to, credit), for the reviewer.';
comment on column public.orders.acknowledged_at is
  'Stamped by submit_order(p_acknowledged => true): the submitter confirmed they reviewed the order. Required for non-portal orders.';

-- A portal session (any request with a user identity) cannot set or alter
-- provenance or acknowledgement. The mcp_* RPCs and submit_order set the
-- transaction-local GUC app.mcp_order_write='on' around their own writes
-- and put it back afterwards. Sessions with no user identity (ETL,
-- maintenance as postgres/service_role) are not portal sessions.
--
-- Status, too: draft -> submitted happens only inside submit_order (the
-- acknowledgement check lives there), so a direct PATCH - which admin RLS
-- would otherwise allow - cannot submit an unreviewed MCP draft. A new row
-- starts as a draft. A recall (submitted -> draft) clears the
-- acknowledgement: it was for the order as it was.
--
-- An MCP session (app_metadata.provider='mcp') writes orders ONLY through
-- the mcp_* RPCs: no direct insert/update/delete over PostgREST at all,
-- whatever its RLS role would allow.
create or replace function public.orders_protect_provenance()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.mcp_order_write', true), '') = 'on'
     or auth.uid() is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp' then
    raise exception 'mcp_direct_write: an MCP session changes orders only through the order-drafting tools'
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.status is distinct from 'draft' then
      raise exception 'protected_status: a new order starts as a draft; submit_order() submits it'
        using errcode = '42501';
    end if;
    if new.source is distinct from 'portal'
       or new.mcp_token_id is not null
       or new.client_request_id is not null
       or new.request_hash is not null
       or new.source_ref is not null
       or new.mcp_warnings is not null
       or new.acknowledged_at is not null
       or new.acknowledged_by is not null
       or (new.created_by is not null and new.created_by <> auth.uid()) then
      raise exception 'protected_column: source, provenance and acknowledgement are set by the server'
        using errcode = '42501';
    end if;
    new.created_by := auth.uid();
  elsif (new.source, new.created_by, new.mcp_token_id, new.client_request_id, new.request_hash,
         new.source_ref, new.mcp_warnings, new.acknowledged_at, new.acknowledged_by)
        is distinct from
        (old.source, old.created_by, old.mcp_token_id, old.client_request_id, old.request_hash,
         old.source_ref, old.mcp_warnings, old.acknowledged_at, old.acknowledged_by) then
    raise exception 'protected_column: source, provenance and acknowledgement are set by the server'
      using errcode = '42501';
  elsif old.status = 'draft' and new.status = 'submitted' then
    raise exception 'protected_status: submit an order with submit_order(), not a direct update'
      using errcode = '42501';
  elsif old.status = 'submitted' and new.status = 'draft' then
    new.acknowledged_at := null;
    new.acknowledged_by := null;
  end if;
  return new;
end;
$$;

revoke execute on function public.orders_protect_provenance() from public, anon, authenticated;

drop trigger if exists trg_orders_protect_provenance on public.orders;
create trigger trg_orders_protect_provenance
  before insert or update or delete on public.orders
  for each row execute function public.orders_protect_provenance();

--------------------------------------------------------------------------
-- 4. submit_order(p_order_id, p_acknowledged). Positional submit_order(id)
--    calls keep working through the default.
--------------------------------------------------------------------------
drop function if exists public.submit_order(bigint);

create function public.submit_order(p_order_id bigint, p_acknowledged boolean default false)
returns public.orders
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
  v_cust  record;
  v_ship  erp.dim_ship_to;
  v_bad   text;
  v_needs boolean;
  v_ffl   text;
  v_exp   date;
  v_ack   boolean := coalesce(p_acknowledged, false);
  v_guc   text := current_setting('app.mcp_order_write', true);
begin
  -- A JWT outlives deactivation; the profile is the cutoff, not the token.
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;
  -- Claude never submits. An MCP session reaches this only through the
  -- draft preview's dry run (mcp_order_preview sets app.mcp_dry_run and
  -- always rolls the subtransaction back).
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp'
     and coalesce(current_setting('app.mcp_dry_run', true), '') <> 'on' then
    raise exception 'mcp_cannot_submit: Claude drafts orders; a person submits them in the portal'
      using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if not (v_order.user_id = v_uid or public.is_admin()) then
    raise exception 'only the order''s owner may submit it';
  end if;
  if v_order.status <> 'draft' then
    raise exception 'order % is %, only drafts can be submitted',
      p_order_id, v_order.status;
  end if;
  -- Claude (or any non-portal source) drafted it: a person must confirm it.
  if v_order.source <> 'portal' and not v_ack then
    raise exception 'acknowledge_required: order % was drafted by %; confirm you have reviewed it before submitting',
      p_order_id, case v_order.source when 'mcp' then 'Claude' else v_order.source end;
  end if;
  if not exists (select 1 from public.order_lines where order_id = p_order_id) then
    raise exception 'order % has no lines', p_order_id;
  end if;

  select c.customer_name, c.customer_type into v_cust
  from erp.dim_customer c where c.customer_key = v_order.customer_key;
  if not found then
    raise exception 'customer % not found in the ERP', v_order.customer_key;
  end if;

  -- Ship-to: one of this account's own Visual ship-to addresses (CUST_ADDRESS,
  -- so it has a SHIPTO_ID the order can carry), and still active.
  if v_order.ship_to_key is null then
    raise exception 'pick a ship-to address for this order';
  end if;
  select s.* into v_ship from erp.dim_ship_to s where s.ship_to_key = v_order.ship_to_key;
  if not found
     or v_ship.customer_id is distinct from v_order.customer_key
     or v_ship.address_source is distinct from 'ShipTo'
     or coalesce(v_ship.is_unknown_ship_to, false)
     or nullif(trim(v_ship.ship_to_id), '') is null then
    raise exception 'ship-to % is not one of this account''s ship-to addresses', v_order.ship_to_key;
  end if;
  if upper(coalesce(v_ship.active_flag, 'Y')) = 'N' then
    raise exception 'ship-to % (%) is inactive in the ERP; pick another address',
      v_ship.ship_to_id, v_ship.ship_to_name;
  end if;

  -- FFL: only when a line is a firearm (part_requires_ffl). The ship-to's
  -- licence on file is used when it is complete and current; the rep enters
  -- one only when it is not (or to give a renewed licence). Whether an
  -- entered licence matches Visual is order entry's check: the loader
  -- refuses to write until the ship-to in Visual carries it.
  v_needs := exists (select 1 from public.order_lines l
                     where l.order_id = p_order_id and public.part_requires_ffl(l.part_id));
  if not v_needs then
    v_ffl := null;
    v_exp := null;
  elsif nullif(trim(v_order.ffl_license_number), '') is null
        and public.ffl_on_file_current(v_ship.ffl_license_number, v_ship.ffl_expiration_raw) then
    v_ffl := upper(trim(v_ship.ffl_license_number));
    v_exp := public.parse_ffl_expiry(v_ship.ffl_expiration_raw);
  else
    if length(public.ffl_normalize(v_order.ffl_license_number)) <> 15 then
      raise exception 'this order has firearms and ship-to % has no current FFL on file: enter the FFL '
        'number (15 characters, e.g. 1-23-456-78-9A-12345)', v_ship.ship_to_id;
    end if;
    if v_order.ffl_expires_on is null then
      raise exception 'the FFL expiration date is required';
    end if;
    if v_order.ffl_expires_on < current_date then
      raise exception 'the FFL expired on %; get the renewed licence before submitting',
        v_order.ffl_expires_on;
    end if;
    v_ffl := upper(trim(v_order.ffl_license_number));
    v_exp := v_order.ffl_expires_on;
  end if;

  -- Every line must sit on a list effective today for this customer type,
  -- and its captured price must still be the published price.
  select string_agg(distinct l.part_id, ', ') into v_bad
  from public.order_lines l
  where l.order_id = p_order_id
    and not exists (
      select 1
      from public.effective_price_lists(v_cust.customer_type) epl
      join public.price_list_items i
        on i.price_list_id = epl.id and i.part_id = l.part_id
      where epl.id = l.price_list_id
        and i.unit_price = l.unit_price
    );
  if v_bad is not null then
    raise exception 'lines no longer valid against today''s price lists: %. '
      'Re-open the draft to refresh pricing.', v_bad;
  end if;

  -- Authoritative promo pass (overwrites whatever the client previewed).
  with totals as (
    select l.price_list_id,
           sum(l.qty)::numeric as total_qty,
           pl.promo_buy_qty, pl.promo_get_qty
    from public.order_lines l
    join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = p_order_id
    group by l.price_list_id, pl.promo_buy_qty, pl.promo_get_qty
  ),
  pct as (
    select price_list_id,
           case
             when promo_buy_qty is null then 0::numeric
             else round(
               100 * (floor(total_qty / (promo_buy_qty + promo_get_qty))
                      * promo_get_qty) / total_qty, 4)
           end as discount_pct
    from totals
  )
  update public.order_lines l
  set discount_pct         = pct.discount_pct,
      effective_unit_price = round(l.unit_price * (1 - pct.discount_pct / 100), 2)
  from pct
  where l.order_id = p_order_id
    and l.price_list_id = pct.price_list_id;

  -- acknowledged_at/by are protected columns: open the write window for
  -- this one statement, then put the GUC back as it was.
  perform set_config('app.mcp_order_write', 'on', true);
  update public.orders o
  set status        = 'submitted',
      customer_name = coalesce(v_cust.customer_name, v_order.customer_key),
      customer_type = v_cust.customer_type,
      ship_to_id      = v_ship.ship_to_id,
      ship_to_addr_no = v_ship.addr_no,
      ship_to_name    = v_ship.ship_to_name,
      ship_to_address = concat_ws(', ',
                          nullif(trim(v_ship.address1), ''), nullif(trim(v_ship.address2), ''),
                          nullif(trim(v_ship.address3), ''), nullif(trim(v_ship.city), ''),
                          nullif(trim(concat_ws(' ', v_ship.state, v_ship.zip_code)), '')),
      requires_ffl               = v_needs,
      ffl_license_number         = v_ffl,
      ffl_expires_on             = v_exp,
      ffl_on_file_number         = v_ship.ffl_license_number,
      ffl_on_file_expiration_raw = v_ship.ffl_expiration_raw,
      total_amount  = (select sum(line_total) from public.order_lines
                       where order_id = p_order_id),
      submitted_at  = now(),
      acknowledged_at = case when v_ack then now() else o.acknowledged_at end,
      acknowledged_by = case when v_ack then v_uid else o.acknowledged_by end
  where o.id = p_order_id
  returning * into v_order;
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);

  return v_order;
end;
$$;

revoke execute on function public.submit_order(bigint, boolean) from public, anon;
grant execute on function public.submit_order(bigint, boolean) to authenticated, service_role;

comment on function public.submit_order(bigint, boolean) is
  'draft -> submitted, with the authoritative pricing/ship-to/FFL pass. An '
  'order with source <> ''portal'' needs p_acknowledged => true '
  '(acknowledge_required otherwise); an acknowledgement stamps acknowledged_at/by.';

--------------------------------------------------------------------------
-- 5. mcp_tool_calls: append-only audit of MCP write tool calls
--------------------------------------------------------------------------
create table if not exists public.mcp_tool_calls (
    id         bigint generated always as identity primary key,
    created_at timestamptz not null default now(),
    -- No cascade: the audit outlives the profile (orders.user_id is NO ACTION too).
    user_id    uuid not null references public.profiles (user_id),
    token_id   uuid references public.mcp_tokens (id) on delete set null,
    tool       text not null,
    args       jsonb,
    outcome    text not null check (outcome in ('ok', 'refused', 'error')),
    error      text,
    order_id   bigint          -- no FK: a refused call may name an order that does not exist
);
alter table public.mcp_tool_calls enable row level security;

create index if not exists idx_mcp_tool_calls_user on public.mcp_tool_calls (user_id, created_at desc);
create index if not exists idx_mcp_tool_calls_order on public.mcp_tool_calls (order_id) where order_id is not null;

comment on table public.mcp_tool_calls is
  'Append-only audit of MCP write tool calls (create/update/cancel order drafts), '
  'written by mcp_log_call() from the edge function after each call, refusals '
  'included. Exempt from the view-as write block (an audit table).';

drop policy if exists "read own mcp tool calls" on public.mcp_tool_calls;
create policy "read own mcp tool calls" on public.mcp_tool_calls
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

revoke all on public.mcp_tool_calls from anon, public, authenticated;
grant select on public.mcp_tool_calls to authenticated;

create or replace function public.mcp_log_call(
  p_tool     text,
  p_args     jsonb,
  p_outcome  text,
  p_error    text   default null,
  p_order_id bigint default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_app  jsonb := coalesce(auth.jwt() -> 'app_metadata', '{}'::jsonb);
  v_tok  uuid;
  v_args jsonb := p_args;
  v_id   bigint;
begin
  if v_uid is null or v_app ->> 'provider' is distinct from 'mcp' then
    raise exception 'not_mcp_session: only an MCP client writes the MCP call log';
  end if;
  if p_outcome is null or p_outcome not in ('ok', 'refused', 'error') then
    raise exception 'invalid_input:outcome: must be ok, refused or error';
  end if;
  if nullif(btrim(coalesce(p_tool, '')), '') is null or length(p_tool) > 64 then
    raise exception 'invalid_input:tool: a tool name (64 characters at most) is required';
  end if;
  if (v_app ->> 'mcp_token_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_tok := (v_app ->> 'mcp_token_id')::uuid;
    if not exists (select 1 from public.mcp_tokens t where t.id = v_tok and t.user_id = v_uid) then
      v_tok := null;
    end if;
  end if;
  -- Bounded: an email excerpt is the largest legitimate argument.
  if v_args is not null and octet_length(v_args::text) > 16384 then
    v_args := jsonb_build_object('truncated', true, 'bytes', octet_length(v_args::text));
  end if;

  insert into public.mcp_tool_calls (user_id, token_id, tool, args, outcome, error, order_id)
  values (v_uid, v_tok, btrim(p_tool), v_args, p_outcome, left(p_error, 2000), p_order_id)
  returning id into v_id;

  return jsonb_build_object('logged', true, 'id', v_id);
end;
$$;

revoke execute on function public.mcp_log_call(text, jsonb, text, text, bigint) from public, anon;
grant execute on function public.mcp_log_call(text, jsonb, text, text, bigint) to authenticated;

--------------------------------------------------------------------------
-- 6. v_orders_ready_for_erp: what Tyler's middleware pulls. security_invoker:
--    the middleware's own key decides what it sees; order_entry sees every
--    submitted order through orders RLS, a rep only their own book's.
--------------------------------------------------------------------------
create or replace view public.v_orders_ready_for_erp
with (security_invoker = true) as
select
  o.id                         as order_id,
  o.status,
  o.source,
  o.user_id,
  o.created_by,
  o.created_at,
  o.submitted_at,
  o.acknowledged_at,
  o.acknowledged_by,
  o.customer_key,
  o.customer_name,
  o.customer_type,
  o.po_number,
  o.requested_ship_date,
  o.notes,
  o.customer_contact_key,
  o.ship_to_key,
  o.ship_to_id,
  o.ship_to_addr_no,
  o.ship_to_name,
  o.ship_to_address,
  o.requires_ffl,
  o.ffl_license_number,
  o.ffl_expires_on,
  o.ffl_on_file_number,
  o.ffl_on_file_expiration_raw,
  o.total_amount,
  o.mcp_token_id,
  o.client_request_id,
  o.source_ref,
  o.mcp_warnings,
  o.updated_at,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'line_id',              l.id,
             'part_id',              l.part_id,
             'description',          l.description,
             'qty',                  l.qty,
             'price_list_id',        l.price_list_id,
             'price_list_name',      pl.name,
             'unit_price',           l.unit_price,
             'discount_pct',         l.discount_pct,
             'effective_unit_price', l.effective_unit_price,
             'line_total',           l.line_total)
           order by l.id)
    from public.order_lines l
    join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = o.id), '[]'::jsonb) as lines
from public.orders o
where o.status = 'submitted'
  -- A non-portal order is ready only once a person acknowledged THIS
  -- submission (submit_order stamps both with the same now(); a recall
  -- clears the acknowledgement).
  and (o.source = 'portal'
       or (o.acknowledged_at is not null and o.acknowledged_at >= o.submitted_at));

revoke all on public.v_orders_ready_for_erp from anon, public;
grant select on public.v_orders_ready_for_erp to authenticated, service_role;

comment on view public.v_orders_ready_for_erp is
  'Submitted portal orders with lines, ship-to/FFL snapshot, acknowledgement and '
  'source: the stable read for the ERP middleware. Nothing here writes the ERP.';
