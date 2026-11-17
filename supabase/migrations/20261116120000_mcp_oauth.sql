/*============================================================================
  20261116120000_mcp_oauth.sql

  Purpose: let Claude sign in to the MCP endpoint with OAuth instead of a
           token pasted into the connector URL. One connector URL for the
           whole team; each person signs in as themselves.

  Who does what
  -------------
  Supabase Auth is the OAuth 2.1 authorization server (Dashboard ->
  Authentication -> OAuth Server). It runs the flow, stores clients,
  consents and sessions in the auth schema, and issues the access token.
  The portal hosts the consent screen (/oauth/consent). The mcp Edge
  Function is the resource server: it checks the token, then does exactly
  what it does for an MCP token: one service_role call to learn who the
  caller is (mcp_oauth_resolve, below), then a five-minute JWT of its own
  with app_metadata.provider = 'mcp', and every read under that user's RLS.

  So nothing downstream changes. The order tools, the gate, the triggers
  that keep an MCP session from submitting an order all still see an MCP
  session. This file adds the OAuth way in and one new rule (section 5).

  1. mcp_oauth_connections: one row per (user, OAuth client) that has used
     the endpoint. Written only by mcp_oauth_resolve. It is what the Connect
     page reads "last used" from and what the audit log points at. Whether a
     connection is still allowed is NOT stored here: Supabase Auth owns
     that (auth.oauth_consents, auth.sessions), and revoking a grant deletes
     the session, which is checked on every request.
  2. mcp_oauth_session_live(): is this OAuth session still there? Reads
     auth.sessions. Internal.
  3. mcp_oauth_resolve(): service_role only, the OAuth twin of
     mcp_token_resolve(). Returns no account data.
  4. mcp_orders_gate() and mcp_log_call() accept an OAuth connection where
     they accepted a token row. Every other check is unchanged.
  5. An OAuth access token works at the MCP endpoint and nowhere else.

     This is the part that needs explaining. The token Supabase Auth hands
     Claude is an ordinary user JWT (role authenticated, sub = the user)
     with one extra claim, client_id. PostgREST and Storage would accept it
     as a portal session: it could submit an order, mint an MCP token or,
     for an admin, change who may draft. The crp_ token it replaces could do
     none of that, because it meant nothing outside the Edge Function.
     Supabase Auth has no way to bind a token to one resource yet, so the
     binding is done here, in three places:

       a. postgrest_pre_request(): PostgREST calls it before every Data API
          request. A JWT carrying client_id is refused outright. Reads and
          RPCs included.
       b. block_writes_while_impersonating(), the trigger already on every
          RLS table in public, also refuses a write under such a JWT. This
          is the second layer: it holds if (a) is ever unregistered, and (a)
          holds for a table the sweep has not reached yet.
       c. A restrictive policy on storage.objects (Storage does not run the
          pre-request function).

     The Edge Functions that take a user JWT refuse these tokens in
     _shared/supabase.ts. Supabase Auth itself already refuses them on the
     account endpoints (password, email, grants). Realtime is not covered:
     a token holder could subscribe to changes on rows the user can read.

     The MCP function is not affected by any of this: the JWT it mints has
     no client_id claim.

  Reading auth.sessions
  ---------------------
  Two functions here read auth.sessions (id, user_id, oauth_client_id,
  not_after). That is Supabase's table, not ours. They are plpgsql so the
  reference is resolved when they run, not when this file is applied; if the
  shape ever changes they fail closed (nobody resolves, nobody drafts) and
  say why in the function log.

  Apply with etl/deploy_migrations.py like every other file. It registers a
  PostgREST pre-request function, which every Data API request then runs:
  run supabase/tests/20261116_mcp_oauth.sql against dev first.
============================================================================*/

--------------------------------------------------------------------------
-- 1. mcp_oauth_connections
--------------------------------------------------------------------------
create table if not exists public.mcp_oauth_connections (
    id            uuid primary key default pg_catalog.gen_random_uuid(),
    user_id       uuid not null references public.profiles (user_id) on delete cascade,
    -- auth.oauth_clients.id, as it appears in the token's client_id claim.
    -- No foreign key: the auth schema is Supabase's, and a client deleted
    -- there should not take the usage history with it.
    client_id     uuid not null,
    first_used_at timestamptz not null default now(),
    last_used_at  timestamptz not null default now(),
    constraint mcp_oauth_connections_user_client unique (user_id, client_id)
);

alter table public.mcp_oauth_connections enable row level security;

comment on table public.mcp_oauth_connections is
  'One row per (user, OAuth client) that has called the mcp Edge Function '
  'with an OAuth access token. Written only by mcp_oauth_resolve(). Usage '
  'history, not permission: Supabase Auth decides whether the connection is '
  'still allowed (a revoked grant deletes its auth.sessions row).';

drop policy if exists "read own mcp oauth connections" on public.mcp_oauth_connections;
create policy "read own mcp oauth connections" on public.mcp_oauth_connections
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

-- No INSERT/UPDATE/DELETE for anyone: mcp_oauth_resolve() owns the writes.
revoke all on public.mcp_oauth_connections from anon, public, authenticated;
grant select on public.mcp_oauth_connections to authenticated;

-- Both sweeps (view-as, 20260901190200; inside sales, 20261113090000) cover
-- every RLS table. Nothing writes this one under a user JWT, so the triggers
-- never fire in practice; they are here so the coverage tests stay true.
drop trigger if exists trg_mcp_oauth_connections_no_write_while_viewing_as on public.mcp_oauth_connections;
create trigger trg_mcp_oauth_connections_no_write_while_viewing_as
  before insert or update or delete on public.mcp_oauth_connections
  for each row execute function public.block_writes_while_impersonating();

drop trigger if exists trg_mcp_oauth_connections_read_only_role on public.mcp_oauth_connections;
create trigger trg_mcp_oauth_connections_read_only_role
  before insert or update or delete on public.mcp_oauth_connections
  for each row execute function public.block_writes_for_read_only_role();

--------------------------------------------------------------------------
-- 2. mcp_oauth_session_live: the OAuth session behind a token still exists.
--
-- Supabase Auth creates an auth.sessions row per OAuth grant in use, with
-- oauth_client_id set, and deletes it when the user revokes the grant (or an
-- admin deletes the client or the user). So "the row is there" is "the
-- connection is still allowed", to the second.
--------------------------------------------------------------------------
create or replace function public.mcp_oauth_session_live(
    p_user_id    uuid,
    p_client_id  uuid,
    p_session_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
    if p_user_id is null or p_client_id is null or p_session_id is null then
        return false;
    end if;
    return exists (
        select 1
        from auth.sessions s
        where s.id = p_session_id
          and s.user_id = p_user_id
          and s.oauth_client_id = p_client_id
          and (s.not_after is null or s.not_after > pg_catalog.now())
    );
end;
$$;

comment on function public.mcp_oauth_session_live(uuid, uuid, uuid) is
  'True while the auth.sessions row of an OAuth grant exists for this user '
  'and client. Internal: called by mcp_oauth_resolve() and mcp_orders_gate().';

--------------------------------------------------------------------------
-- 3. mcp_oauth_resolve: "this verified OAuth token says user U, client C,
--    session S. Is that still good, and who is U?"
--
-- The Edge Function has already checked the token's signature, issuer and
-- expiry. This answers what a signature cannot: the grant has not been
-- revoked since, and the profile is still active.
--------------------------------------------------------------------------
create or replace function public.mcp_oauth_resolve(
    p_user_id    uuid,
    p_client_id  uuid,
    p_session_id uuid
)
returns table (
    connection_id       uuid,
    user_id             uuid,
    full_name           text,
    user_role           text,
    sales_rep_key       text,
    rep_group_vendor_id text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_row  record;
    v_conn uuid;
begin
    if not public.mcp_oauth_session_live(p_user_id, p_client_id, p_session_id) then
        return;
    end if;

    -- Deactivating a user ends their Claude connections too, as it does for
    -- tokens (mcp_token_resolve).
    select p.user_id             as f_user_id,
           p.full_name           as f_full_name,
           p.role                as f_role,
           p.sales_rep_key       as f_rep_key,
           p.rep_group_vendor_id as f_vendor_id
      into v_row
      from public.profiles p
     where p.user_id = p_user_id
       and p.active;

    if not found then
        return;
    end if;

    insert into public.mcp_oauth_connections (user_id, client_id)
    values (p_user_id, p_client_id)
    on conflict on constraint mcp_oauth_connections_user_client do nothing;

    -- At most one write every five minutes, as for tokens.
    update public.mcp_oauth_connections c
       set last_used_at = pg_catalog.now()
     where c.user_id = p_user_id
       and c.client_id = p_client_id
       and c.last_used_at < pg_catalog.now() - pg_catalog.make_interval(mins => 5);

    select c.id into v_conn
      from public.mcp_oauth_connections c
     where c.user_id = p_user_id
       and c.client_id = p_client_id;

    connection_id       := v_conn;
    user_id             := v_row.f_user_id;
    full_name           := v_row.f_full_name;
    user_role           := v_row.f_role;
    sales_rep_key       := v_row.f_rep_key;
    rep_group_vendor_id := v_row.f_vendor_id;
    return next;
end;
$$;

comment on function public.mcp_oauth_resolve(uuid, uuid, uuid) is
  'Resolves a verified OAuth access token (user, client, session) to its '
  'user. service_role ONLY: the mcp Edge Function''s one privileged call on '
  'the OAuth path, made before any data is read. Returns nothing for a '
  'revoked grant, an expired session or a deactivated profile.';

revoke execute on function public.mcp_oauth_session_live(uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.mcp_oauth_resolve(uuid, uuid, uuid)      from public, anon, authenticated;
grant execute on function public.mcp_oauth_resolve(uuid, uuid, uuid) to service_role;

--------------------------------------------------------------------------
-- 4a. mcp_orders_gate: an OAuth connection passes where a token row did.
--
-- Body = 20261111150000 with one branch added. A session carries either
-- mcp_token_id (a crp_ token) or mcp_oauth_connection_id (OAuth); the claims
-- are signed by the Edge Function, and the row behind them is the truth.
-- The OAuth branch re-reads auth.sessions, so a grant revoked while the
-- five-minute JWT is still alive stops here, as a revoked token does.
--------------------------------------------------------------------------
create or replace function public.mcp_orders_gate()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_app    jsonb := coalesce(auth.jwt() -> 'app_metadata', '{}'::jsonb);
  v_set    record;
  v_tok    text;
  v_conn   text;
  v_sess   text;
  v_client uuid;
  v_uuid   constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
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

  v_tok  := v_app ->> 'mcp_token_id';
  v_conn := v_app ->> 'mcp_oauth_connection_id';

  if v_tok is null and v_conn is not null then
    -- Signed in with OAuth.
    v_sess := v_app ->> 'mcp_oauth_session_id';
    if v_conn !~* v_uuid or v_sess is null or v_sess !~* v_uuid then
      raise exception 'not_mcp_session: the session carries no MCP token';
    end if;
    select c.client_id into v_client
    from public.mcp_oauth_connections c
    where c.id = v_conn::uuid
      and c.user_id = v_uid;
    if not found then
      raise exception 'not_mcp_session: the Claude connection is not yours';
    end if;
    if not public.mcp_oauth_session_live(v_uid, v_client, v_sess::uuid) then
      raise exception 'not_mcp_session: the Claude connection was disconnected or has expired';
    end if;
  else
    -- A crp_ token. A token revoked in the last five minutes (JWT lifetime)
    -- stops here.
    if v_tok is null or v_tok !~* v_uuid then
      raise exception 'not_mcp_session: the session carries no MCP token';
    end if;
    perform 1
    from public.mcp_tokens t
    where t.id = v_tok::uuid
      and t.user_id = v_uid
      and t.revoked_at is null
      and t.expires_at > now();
    if not found then
      raise exception 'not_mcp_session: the MCP token is revoked, expired or not yours';
    end if;
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
  'Every mcp_* write RPC calls this first. Any live MCP token, or any live '
  'OAuth connection (20261116120000), of an allowed, active user passes. '
  'Raises mcp_orders_disabled, not_mcp_session, account_inactive or '
  'mcp_user_not_allowed (message ''code: text''); returns feature.mcp_orders params.';

--------------------------------------------------------------------------
-- 4b. The audit log names the OAuth connection, as it names the token.
--     Body = 20261111100000 plus the connection lookup.
--------------------------------------------------------------------------
alter table public.mcp_tool_calls
  add column if not exists oauth_connection_id uuid
    references public.mcp_oauth_connections (id) on delete set null;

comment on column public.mcp_tool_calls.oauth_connection_id is
  'The OAuth connection the call came through, when it was not a crp_ token '
  '(token_id is null then).';

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
  v_conn uuid;
  v_args jsonb := p_args;
  v_id   bigint;
  v_uuid constant text := '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
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
  if (v_app ->> 'mcp_token_id') ~* v_uuid then
    v_tok := (v_app ->> 'mcp_token_id')::uuid;
    if not exists (select 1 from public.mcp_tokens t where t.id = v_tok and t.user_id = v_uid) then
      v_tok := null;
    end if;
  end if;
  if (v_app ->> 'mcp_oauth_connection_id') ~* v_uuid then
    v_conn := (v_app ->> 'mcp_oauth_connection_id')::uuid;
    if not exists (select 1 from public.mcp_oauth_connections c where c.id = v_conn and c.user_id = v_uid) then
      v_conn := null;
    end if;
  end if;
  -- Bounded: an email excerpt is the largest legitimate argument.
  if v_args is not null and octet_length(v_args::text) > 16384 then
    v_args := jsonb_build_object('truncated', true, 'bytes', octet_length(v_args::text));
  end if;

  insert into public.mcp_tool_calls (user_id, token_id, oauth_connection_id, tool, args, outcome, error, order_id)
  values (v_uid, v_tok, v_conn, btrim(p_tool), v_args, p_outcome, left(p_error, 2000), p_order_id)
  returning id into v_id;

  return jsonb_build_object('logged', true, 'id', v_id);
end;
$$;

--------------------------------------------------------------------------
-- 5. An OAuth access token works at the MCP endpoint and nowhere else.
--------------------------------------------------------------------------

-- True for a JWT that Supabase Auth issued to an OAuth client (a connected
-- app). A portal session has no client_id claim, and neither has the JWT the
-- mcp Edge Function mints.
create or replace function public.is_oauth_client_token()
returns boolean
language sql
stable
set search_path = ''
as $$
  select nullif(
    nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb ->> 'client_id',
    '') is not null;
$$;

comment on function public.is_oauth_client_token() is
  'True when the request''s JWT carries a client_id claim: an access token '
  'Supabase Auth issued to an OAuth client. Such a token is for the mcp Edge '
  'Function only (20261116120000 section 5).';

revoke execute on function public.is_oauth_client_token() from public, anon;
grant execute on function public.is_oauth_client_token() to authenticated, service_role;

-- 5a. The Data API. PostgREST runs this before every request, as the
--     request's own role, so all three API roles must be able to call it: a
--     role that cannot would lose the whole Data API. It reads one setting
--     and touches no table.
create or replace function public.postgrest_pre_request()
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_claims text := nullif(pg_catalog.current_setting('request.jwt.claims', true), '');
begin
  if v_claims is not null
     and nullif(v_claims::jsonb ->> 'client_id', '') is not null then
    raise exception 'oauth_client_token: this access token was issued to a connected app and only works at the MCP endpoint'
      using errcode = '42501';
  end if;
end;
$$;

comment on function public.postgrest_pre_request() is
  'PostgREST pre-request function (role authenticator, pgrst.db_pre_request). '
  'Refuses a JWT that carries a client_id claim. Do NOT drop or rename it '
  'without first clearing the role setting: PostgREST calls it by name on '
  'every Data API request.';

revoke execute on function public.postgrest_pre_request() from public;
grant execute on function public.postgrest_pre_request() to anon, authenticated, service_role;

alter role authenticator set pgrst.db_pre_request = 'public.postgrest_pre_request';

-- 5b. Writes, whatever the path (a table, or a SECURITY DEFINER function
--     that writes one). Body = 20260816140000 plus the second check.
create or replace function public.block_writes_while_impersonating()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.acting_as_user_id() is not null then
    raise exception 'read_only_while_viewing_as' using errcode = '42501';
  end if;
  if public.is_oauth_client_token() then
    raise exception 'oauth_client_read_only: a connected app''s access token cannot change %', tg_table_name
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke execute on function public.block_writes_while_impersonating()
  from public, anon, authenticated;

-- 5c. Storage. Restrictive: it narrows every other policy on the table and
--     grants nothing by itself.
drop policy if exists "no connected app tokens" on storage.objects;
create policy "no connected app tokens" on storage.objects
  as restrictive
  for all to authenticated
  using ((select not public.is_oauth_client_token()))
  with check ((select not public.is_oauth_client_token()));

-- PostgREST reads role settings with its configuration.
notify pgrst, 'reload config';

/*----------------------------------------------------------------------------
  After this file
  1. Dashboard -> Authentication -> OAuth Server: enable it, set the
     authorization path to /oauth/consent, and either turn on dynamic client
     registration or register one client for Claude under OAuth Apps. Site
     URL (Authentication -> URL Configuration) must be the portal's origin.
     supabase/functions/mcp/README.md has the steps.
  2. Deploy the portal (it serves /oauth/consent) and the function:
       supabase functions deploy mcp --no-verify-jwt
     and redeploy the four functions that share _shared/supabase.ts.
  3. Run supabase/tests/20261116_mcp_oauth.sql against dev.
  4. Existing crp_ tokens and connector URLs keep working. Nothing to
     backfill.
----------------------------------------------------------------------------*/
