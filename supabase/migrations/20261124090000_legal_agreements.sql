/*============================================================================
  20261124090000_legal_agreements.sql — the Terms of Use and the Privacy
  Policy, and the record that each user agreed to them.

  Why
  ---
  Everyone who uses the portal (reps, rep-group principals, inside sales,
  admins) must agree to a usage agreement and a privacy policy before they
  see anything: the data in here is Christensen Arms' confidential business
  information, and the portal records what people do in it (login_events,
  usage_events, mcp_tool_calls). The agreement is a click-wrap: the person
  reads both documents in the portal, ticks a box for each, and presses
  "I agree". This file is the server half: what the documents say, which
  version is current, and the evidence of who agreed to which version, when,
  and from where.

  What
  ----
  1. public.legal_documents — one row per published VERSION of a document
     (doc_key 'terms' or 'privacy'). Immutable once inserted: a trigger
     refuses every UPDATE and DELETE, so the text a person agreed to is the
     text that is still there. Publishing a change is a new row (a new
     migration, like 20261124090100). content_sha256 is stamped on insert
     from the title, summary and body, and copied onto every acceptance.
     The current version of a document is its newest row whose effective_at
     has passed; a row dated in the future is invisible until then, and on
     that day everyone is asked to agree again.

     Readable by anyone, signed in or not (anon too): the sign-in page links
     to both documents, and a policy you can only read after agreeing to it
     is not much of a policy. Written by migrations only.

  2. public.legal_acceptances — one row per user per document version they
     agreed to. Append-only (a trigger refuses DELETE, and any UPDATE other
     than the user_id → null a profile deletion makes). Each row snapshots
     the document's version and hash, the person's name, email and role at
     that moment, and the IP address and browser the request came from (as
     the API gateway reported them). user_id is ON DELETE SET NULL, not
     cascade: deleting someone's login does not delete the evidence that
     they agreed to the confidentiality terms; the snapshot still names them.

     Read: your own rows, and an admin reads all. No insert, update or
     delete grant to anyone, service_role included: accept_legal_documents()
     is the only way in, and an insert trigger stamps the time and copies
     the version and hash from the document whatever the caller sent.

  3. legal_current_documents() — the current version of each document, with
     its full text. anon + authenticated: the public /terms and /privacy
     pages and the agreement screen both read it.

  4. legal_status() — for the signed-in person (auth.uid(), the REAL user:
     an admin viewing as a rep is asked about their own agreement, never the
     rep's): each current document, whether they have agreed to it and when,
     and the last version of it they agreed to if that is an older one.
     all_accepted is what the portal's router guard and the MCP endpoint
     gate on.

  5. accept_legal_documents(bigint[]) — the only write path. SECURITY
     DEFINER; stamps auth.uid() and now() itself. Refuses:
       - an MCP session (app_metadata.provider = 'mcp') and a connected
         app's OAuth token: Claude must never be able to agree on a
         person's behalf. Only the person, in the portal;
       - a deactivated profile;
       - an id that is not the CURRENT version of its document
         (legal_document_not_current): the screen was open while a new
         version was published, so the person read old text. The portal
         reloads and shows the new one.
     Idempotent: agreeing twice keeps the first timestamp. Returns the new
     legal_status(). Allowed while an admin is viewing as a rep (it records
     the admin's own agreement, auth.uid()) and for inside sales.

  6. admin_legal_status() — Admin › Users: every profile, whether they have
     agreed to the current versions, when, and what is outstanding.
     Admin-only (empty for anyone else; the policies are the boundary).

  Sweeps
  ------
  legal_documents carries both read-only triggers like any RLS table (nobody
  but a migration writes it anyway).

  legal_acceptances is EXEMPT from both: the view-as sweep
  (20260901190200) and the inside-sales sweep (20261113090000). It is a
  record written on the signed-in person's own behalf, like login_events:
  inside sales must be able to agree (or they could never get in), and an
  admin who is asked mid-view-as agrees for themselves. The exemption is
  IN THE TRIGGER FUNCTIONS (section 2b: both return early for this table),
  so a later re-run or copy of either sweep that attaches its trigger here
  anyway changes nothing. Both sweep tests' exempt lists name it too.

  Enforcement: four doors
  -----------------------
  7. The portal's router guard (frontend/src/router/index.ts) sends every
     signed-in page to /agreements until legal_status() says yes.
  8. The MCP endpoint refuses tools/call until then (functions/mcp/legal.ts).
  9. log_usage() records nothing for someone who has not agreed: usage
     tracking starts with the agreement, on the server as on the client.
     log_login() still records a sign-in before it (the security log; the
     Privacy Policy says so).
  10. postgrest_pre_request() refuses the Data API to someone who has not
     agreed, except the few calls the agreement screen and sign-in need
     (legal_gate_allows_path()):
       - always for an MCP session (provider = 'mcp'), so an mcp function
         deployed before its own gate still cannot read for them;
       - for portal sessions once app_settings 'legal.enforce_data_api' is
         on (Admin › Settings). Seeded OFF: integration logins that use the
         Data API as a user (the order loader signs in as inside sales) must
         agree first, once, by signing in to the portal, or they stop. Turn
         it on after that. With it off, the Data API answers a user who
         skips the portal, as before; the portal itself still gates.

  Deploy
  ------
  Apply this file, then redeploy the mcp function
      supabase functions deploy mcp --no-verify-jwt
  and deploy the portal build, BEFORE 20261124090100 (the file that
  publishes the text and so turns the requirement on). All three are safe
  without it: with no document in force, legal_status() says yes. The
  previous mcp function has no gate of its own; section 10 still refuses
  its tool reads for anyone who has not agreed, with a plainer error.
  Before switching legal.enforce_data_api on, sign in to the portal once as
  every integration login (the order loader's inside-sales account) and
  agree.

  Guarded by tests/20261124_legal_agreements.sql.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Documents
--------------------------------------------------------------------------
create table if not exists public.legal_documents (
    id              bigint generated always as identity primary key,
    doc_key         text not null check (doc_key in ('terms', 'privacy')),
    version         text not null check (version ~ '^[0-9A-Za-z][0-9A-Za-z._-]{0,31}$'),
    title           text not null check (btrim(title) <> ''),
    -- A few plain-language lines shown above the full text. Not a substitute
    -- for it, and the document says so.
    summary         text,
    body_md         text not null check (btrim(body_md) <> ''),
    effective_at    timestamptz not null default now(),
    -- Stamped by the insert trigger below (sha256 of title, summary, body).
    content_sha256  text not null default '',
    created_at      timestamptz not null default now(),
    unique (doc_key, version)
);
alter table public.legal_documents enable row level security;

create index if not exists idx_legal_documents_current
  on public.legal_documents (doc_key, effective_at desc, id desc);

comment on table public.legal_documents is
  'Published versions of the portal''s Terms of Use (doc_key = terms) and '
  'Privacy Policy (privacy). Immutable: publish a change as a new row. The '
  'current version is the newest row whose effective_at has passed. Read by '
  'anyone; written by migrations only.';

create or replace function public.legal_documents_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    new.content_sha256 := encode(
      sha256(convert_to(
        new.title || E'\n\n' || coalesce(new.summary, '') || E'\n\n' || new.body_md,
        'UTF8')),
      'hex');
    return new;
  end if;
  raise exception 'legal_documents_immutable: publish a new version instead of changing or removing one'
    using errcode = '42501';
end;
$$;
revoke execute on function public.legal_documents_guard() from public, anon, authenticated;

drop trigger if exists trg_legal_documents_guard on public.legal_documents;
create trigger trg_legal_documents_guard
  before insert or update or delete on public.legal_documents
  for each row execute function public.legal_documents_guard();

drop policy if exists "anyone reads effective legal documents" on public.legal_documents;
create policy "anyone reads effective legal documents" on public.legal_documents
  for select to anon, authenticated
  using (effective_at <= now());

revoke all on public.legal_documents from anon, public, authenticated;
-- Supabase's default privileges hand service_role every table. Not this one:
-- a version is published by a migration (as the table owner), never by an
-- Edge Function holding the service key.
revoke insert, update, delete, truncate on public.legal_documents from service_role;
grant select on public.legal_documents to anon, authenticated;

-- Both read-only triggers, like every other RLS table (see Sweeps above).
drop trigger if exists trg_legal_documents_no_write_while_viewing_as on public.legal_documents;
create trigger trg_legal_documents_no_write_while_viewing_as
  before insert or update or delete on public.legal_documents
  for each row execute function public.block_writes_while_impersonating();
drop trigger if exists trg_legal_documents_read_only_role on public.legal_documents;
create trigger trg_legal_documents_read_only_role
  before insert or update or delete on public.legal_documents
  for each row execute function public.block_writes_for_read_only_role();

--------------------------------------------------------------------------
-- 2. Acceptances
--------------------------------------------------------------------------
create table if not exists public.legal_acceptances (
    id              bigint generated always as identity primary key,
    -- SET NULL, not cascade: the evidence outlives the login (see header).
    user_id         uuid references public.profiles (user_id) on delete set null,
    document_id     bigint not null references public.legal_documents (id) on delete restrict,
    doc_key         text not null,
    version         text not null,
    content_sha256  text not null,
    accepted_at     timestamptz not null default now(),
    -- Who they were at that moment (the profile can change later).
    full_name       text,
    email           text,
    role            text,
    -- Where the request came from, as the API gateway reported it.
    ip_address      text,
    user_agent      text,
    unique (user_id, document_id)
);
alter table public.legal_acceptances enable row level security;

create index if not exists idx_legal_acceptances_user
  on public.legal_acceptances (user_id, accepted_at desc);
create index if not exists idx_legal_acceptances_document
  on public.legal_acceptances (document_id);

comment on table public.legal_acceptances is
  'Click-wrap record: one row per user per legal_documents version they '
  'agreed to, with the version, its sha256, a snapshot of the person''s '
  'name/email/role, and the request''s IP and user agent. Append-only; '
  'written only by accept_legal_documents(). Own rows readable; admins read '
  'all. Exempt from both read-only sweeps.';

create or replace function public.legal_acceptances_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_doc public.legal_documents%rowtype;
begin
  if tg_op = 'INSERT' then
    -- The record says what was agreed to, not what the writer claims: the
    -- version and hash come from the document, the time from the clock.
    select * into v_doc from public.legal_documents where id = new.document_id;
    if not found then
      raise exception 'legal_document_not_found' using errcode = '23503';
    end if;
    new.doc_key        := v_doc.doc_key;
    new.version        := v_doc.version;
    new.content_sha256 := v_doc.content_sha256;
    new.accepted_at    := now();
    return new;
  end if;
  -- The one update allowed: ON DELETE SET NULL from a deleted profile.
  if tg_op = 'UPDATE'
     and new.user_id is null
     and old.user_id is not null
     and (to_jsonb(new) - 'user_id') = (to_jsonb(old) - 'user_id') then
    return new;
  end if;
  raise exception 'legal_acceptances_append_only: an agreement record cannot be changed or removed'
    using errcode = '42501';
end;
$$;
revoke execute on function public.legal_acceptances_guard() from public, anon, authenticated;

drop trigger if exists trg_legal_acceptances_guard on public.legal_acceptances;
create trigger trg_legal_acceptances_guard
  before insert or update or delete on public.legal_acceptances
  for each row execute function public.legal_acceptances_guard();

drop policy if exists "read own legal acceptances" on public.legal_acceptances;
create policy "read own legal acceptances" on public.legal_acceptances
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

revoke all on public.legal_acceptances from anon, public, authenticated;
-- Not even the service key writes evidence (see legal_documents above).
-- accept_legal_documents() runs as the owner, and so does the SET NULL a
-- profile deletion makes.
revoke insert, update, delete, truncate on public.legal_acceptances from service_role;
grant select on public.legal_acceptances to authenticated;

--------------------------------------------------------------------------
-- 2b. The sweep exemption, where no sweep can undo it
--
-- Both read-only trigger functions return early for legal_acceptances, so
-- the exemption holds even if a later sweep (re-run with --reapply, or
-- copied into a new migration with a stale exempt list) attaches its
-- trigger to the table. Bodies otherwise exactly 20261113090000 and
-- 20261116120000. accept_legal_documents() refuses Claude and connected
-- apps itself, which is the only thing the second check adds there.
--------------------------------------------------------------------------
create or replace function public.block_writes_for_read_only_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- The signed-in person's own agreement (20261124090000).
  if tg_table_schema = 'public' and tg_table_name = 'legal_acceptances' then
    return coalesce(new, old);
  end if;
  if public.is_order_entry() then
    raise exception 'read_only_role: inside sales can view % but not change it', tg_table_name
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;
revoke execute on function public.block_writes_for_read_only_role()
  from public, anon, authenticated;

create or replace function public.block_writes_while_impersonating()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- The signed-in person's own agreement (20261124090000): an admin asked
  -- mid-view-as agrees for themselves.
  if tg_table_schema = 'public' and tg_table_name = 'legal_acceptances' then
    return coalesce(new, old);
  end if;
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

--------------------------------------------------------------------------
-- 3. legal_current_documents(): what is in force right now
--------------------------------------------------------------------------
create or replace function public.legal_current_documents()
returns table (
  id             bigint,
  doc_key        text,
  version        text,
  title          text,
  summary        text,
  body_md        text,
  effective_at   timestamptz,
  content_sha256 text
)
language sql
stable
set search_path = public
as $$
  select distinct on (d.doc_key)
         d.id, d.doc_key, d.version, d.title, d.summary, d.body_md,
         d.effective_at, d.content_sha256
  from public.legal_documents d
  where d.effective_at <= now()
  order by d.doc_key, d.effective_at desc, d.id desc;
$$;

comment on function public.legal_current_documents() is
  'The version of each legal document in force now (newest effective row '
  'per doc_key), full text included. Anyone may call it.';

revoke execute on function public.legal_current_documents() from public;
grant execute on function public.legal_current_documents() to anon, authenticated;

--------------------------------------------------------------------------
-- 4. legal_status(): has the signed-in person agreed to what is current?
--------------------------------------------------------------------------
create or replace function public.legal_status()
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_docs jsonb;
begin
  if v_uid is null then
    return null;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'document_id',           c.id,
           'doc_key',               c.doc_key,
           'version',               c.version,
           'title',                 c.title,
           'effective_at',          c.effective_at,
           'content_sha256',        c.content_sha256,
           'accepted_at',           mine.accepted_at,
           'last_accepted_version', prev.version,
           'last_accepted_at',      prev.accepted_at)
           order by case c.doc_key when 'terms' then 0 else 1 end), '[]'::jsonb)
    into v_docs
  from public.legal_current_documents() c
  left join public.legal_acceptances mine
         on mine.user_id = v_uid and mine.document_id = c.id
  left join lateral (
    select a.version, a.accepted_at
    from public.legal_acceptances a
    where a.user_id = v_uid and a.doc_key = c.doc_key
    order by a.accepted_at desc, a.id desc
    limit 1
  ) prev on true;

  return jsonb_build_object(
    'documents', v_docs,
    'all_accepted', not exists (
      select 1 from jsonb_array_elements(v_docs) d
      where d ->> 'accepted_at' is null));
end;
$$;

comment on function public.legal_status() is
  'For auth.uid() (the real user, never a view-as target): {documents: '
  '[{document_id, doc_key, version, title, effective_at, content_sha256, '
  'accepted_at, last_accepted_version, last_accepted_at}], all_accepted}. '
  'all_accepted is true when every current document has been agreed to '
  '(and when none is published). Null when signed out.';

revoke execute on function public.legal_status() from public, anon;
grant execute on function public.legal_status() to authenticated;

--------------------------------------------------------------------------
-- 5. accept_legal_documents(): the only write path
--------------------------------------------------------------------------
create or replace function public.accept_legal_documents(p_document_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_headers jsonb;
  v_ip      text;
  v_ua      text;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '42501';
  end if;
  -- Claude (an MCP session or a connected app's token) never agrees for anyone.
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp'
     or public.is_oauth_client_token() then
    raise exception 'legal_acceptance_in_portal_only: only the person can agree, in the portal'
      using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where user_id = v_uid;
  if not found or not v_profile.active then
    raise exception 'inactive_profile: this account cannot agree to anything' using errcode = '42501';
  end if;

  if p_document_ids is null or cardinality(p_document_ids) = 0 then
    raise exception 'no_documents: name the documents being agreed to' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(p_document_ids) as x (id)
    where x.id is null
       or x.id not in (select c.id from public.legal_current_documents() c)
  ) then
    raise exception 'legal_document_not_current: a newer version has been published; review it and agree again'
      using errcode = '22023';
  end if;

  -- As the API gateway reported them. Absent (null) outside PostgREST.
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := null;
  end;
  v_ip := btrim(split_part(coalesce(
            nullif(v_headers ->> 'cf-connecting-ip', ''),
            nullif(v_headers ->> 'x-real-ip', ''),
            nullif(v_headers ->> 'x-forwarded-for', ''), ''), ',', 1));
  if v_ip !~ '^[0-9A-Fa-f:.]{2,45}$' then
    v_ip := null;
  end if;
  v_ua := nullif(left(btrim(coalesce(v_headers ->> 'user-agent', '')), 512), '');

  insert into public.legal_acceptances (
    user_id, document_id, doc_key, version, content_sha256,
    full_name, email, role, ip_address, user_agent)
  select v_uid, d.id, d.doc_key, d.version, d.content_sha256,
         nullif(v_profile.full_name, ''), v_profile.email, v_profile.role, v_ip, v_ua
  from public.legal_documents d
  where d.id = any (p_document_ids)
  on conflict (user_id, document_id) do nothing;

  return public.legal_status();
end;
$$;

comment on function public.accept_legal_documents(bigint[]) is
  'Records that the signed-in person agrees to these legal_documents ids, '
  'each of which must be the current version of its document. Stamps '
  'auth.uid(), now(), a profile snapshot and the request''s IP and user '
  'agent. Refused for MCP sessions, connected-app tokens and deactivated '
  'profiles. Idempotent. Returns legal_status().';

revoke execute on function public.accept_legal_documents(bigint[]) from public, anon;
grant execute on function public.accept_legal_documents(bigint[]) to authenticated;

--------------------------------------------------------------------------
-- 6. admin_legal_status(): Admin › Users
--------------------------------------------------------------------------
create or replace function public.admin_legal_status()
returns table (
  user_id          uuid,
  all_accepted     boolean,
  accepted_at      timestamptz,
  pending          text[],
  last_accepted_at timestamptz
)
language sql
stable
set search_path = public
as $$
  select p.user_id,
         count(c.id) filter (where a.id is null) = 0         as all_accepted,
         case when count(c.id) filter (where a.id is null) = 0
              then max(a.accepted_at) end                    as accepted_at,
         coalesce(array_agg(c.doc_key order by c.doc_key)
                    filter (where a.id is null), '{}')       as pending,
         (select max(x.accepted_at) from public.legal_acceptances x
          where x.user_id = p.user_id)                       as last_accepted_at
  from public.profiles p
  cross join public.legal_current_documents() c
  left join public.legal_acceptances a
         on a.user_id = p.user_id and a.document_id = c.id
  where public.is_admin()
  group by p.user_id;
$$;

comment on function public.admin_legal_status() is
  'Admin › Users: per profile, whether every current legal document is '
  'agreed to (accepted_at = when the last of them was), which doc_keys are '
  'outstanding, and the newest agreement to any version. Empty for a '
  'non-admin, and when no document is published.';

revoke execute on function public.admin_legal_status() from public, anon;
grant execute on function public.admin_legal_status() to authenticated;

--------------------------------------------------------------------------
-- 7. legal_gate_open(): the one yes/no every server-side door asks
--------------------------------------------------------------------------
create or replace function public.legal_gate_open(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- Yours to ask about, or an admin's about anyone; null otherwise.
  select case
    when p_user_id is null then false
    when p_user_id is distinct from auth.uid() and not public.is_admin() then null
    else not exists (
      select 1
      from public.legal_current_documents() c
      where not exists (
        select 1 from public.legal_acceptances a
        where a.user_id = p_user_id and a.document_id = c.id))
  end;
$$;

comment on function public.legal_gate_open(uuid) is
  'True when the user has agreed to the current version of every legal '
  'document (and when none is in force). The same rule as '
  'legal_status().all_accepted, for the server-side doors: log_usage() and '
  'postgrest_pre_request(). Callers may ask about themselves; admins about '
  'anyone; anyone else gets null.';

revoke execute on function public.legal_gate_open(uuid) from public, anon;
grant execute on function public.legal_gate_open(uuid) to authenticated, service_role;

--------------------------------------------------------------------------
-- 8. log_usage(): nothing is recorded before the agreement
--
-- Body = 20261116130000 plus the agreement check. The portal waits for the
-- agreement before it sends anything (useUsageTracking.ts); this is the
-- same rule where an old build of the app, or any other client, cannot
-- skip it.
--------------------------------------------------------------------------
create or replace function public.log_usage(p_events jsonb)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null or public.acting_as_user_id() is not null then
    return 0;
  end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' then
    return 0;
  end if;
  if not exists (select 1 from public.profiles p where p.user_id = v_uid) then
    return 0;
  end if;
  -- Not before the person has agreed to the Privacy Policy that describes
  -- this (20261124090000).
  if not public.legal_gate_open(v_uid) then
    return 0;
  end if;
  -- A runaway client (a redirect loop, a script) stops here, not in the table.
  if (select count(*) from public.usage_events e
      where e.user_id = v_uid and e.occurred_at > now() - interval '1 hour') >= 600 then
    return 0;
  end if;

  insert into public.usage_events (user_id, event, page, customer_key, device, detail)
  select
    v_uid,
    e.item ->> 'event',
    nullif(left(btrim(e.item ->> 'page'), 64), ''),
    nullif(left(btrim(e.item ->> 'customer_key'), 64), ''),
    case when e.item ->> 'device' in ('phone', 'tablet', 'desktop')
         then e.item ->> 'device' end,
    case when jsonb_typeof(e.item -> 'detail') = 'object'
              and octet_length((e.item -> 'detail')::text) <= 1024
         then e.item -> 'detail' end
  from (
    select item
    from jsonb_array_elements(p_events) with ordinality as a (item, n)
    where jsonb_typeof(item) = 'object'
    order by n
    limit 20
  ) e
  where (e.item ->> 'event') ~ '^[a-z][a-z0-9_]{0,39}$';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.log_usage(jsonb) is
  'Appends the caller''s usage events ([{event, page, customer_key, device, '
  'detail}]). Stamps auth.uid() and now(); logs nothing while viewing as a '
  'rep, nor for someone who has not agreed to the current Terms of Use and '
  'Privacy Policy (20261124090000). At most 20 events a call and 600 a user '
  'an hour. Returns rows written.';

revoke execute on function public.log_usage(jsonb) from public, anon;
grant execute on function public.log_usage(jsonb) to authenticated;

--------------------------------------------------------------------------
-- 9. The Data API door: postgrest_pre_request()
--------------------------------------------------------------------------
insert into public.app_settings (setting_key, enabled, description) values
  ('legal.enforce_data_api', false,
   'Refuse the Data API to anyone who has not agreed to the current Terms of Use and '
   'Privacy Policy (the portal asks either way). Before turning this on, sign in to '
   'the portal once as every integration login (the order loader) and agree.')
on conflict (setting_key) do nothing;

/*
  What someone who has not agreed may still call: what signing in and the
  agreement screen need, nothing else. Matched on the path PostgREST sees
  (with or without the /rest/v1 prefix the gateway adds) and the method.
*/
create or replace function public.legal_gate_allows_path(p_path text, p_method text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    p_path ~ '^(/rest/v1)?/(rpc/(legal_status|legal_current_documents|accept_legal_documents|acting_context|stop_impersonation|log_login)|legal_documents)/?$'
    or (p_path ~ '^(/rest/v1)?/profiles/?$' and upper(coalesce(p_method, '')) in ('GET', 'HEAD')),
    false);
$$;

comment on function public.legal_gate_allows_path(text, text) is
  'The Data API calls postgrest_pre_request() lets through for someone who '
  'has not agreed to the current legal documents: legal_status, '
  'legal_current_documents, accept_legal_documents, legal_documents, '
  'acting_context, stop_impersonation, log_login, and reading profiles.';

revoke execute on function public.legal_gate_allows_path(text, text) from public;
grant execute on function public.legal_gate_allows_path(text, text) to anon, authenticated, service_role;

-- Restated from 20261116120000 with the agreement check after the
-- connected-app refusal. Still callable by every API role (one that could
-- not would lose the whole Data API), and still registered by name: do NOT
-- drop or rename it without clearing pgrst.db_pre_request first.
create or replace function public.postgrest_pre_request()
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_claims text := nullif(pg_catalog.current_setting('request.jwt.claims', true), '');
  v_jwt    jsonb;
  v_path   text;
  v_sub    text;
begin
  if v_claims is null then
    return;
  end if;
  v_jwt := v_claims::jsonb;
  if nullif(v_jwt ->> 'client_id', '') is not null then
    raise exception 'oauth_client_token: this access token was issued to a connected app and only works at the MCP endpoint'
      using errcode = '42501';
  end if;

  -- The agreement (20261124090000). Signed-in users only, on a real Data
  -- API request, outside the calls the agreement screen needs.
  if coalesce(v_jwt ->> 'role', '') <> 'authenticated' then
    return;
  end if;
  v_path := nullif(pg_catalog.current_setting('request.path', true), '');
  if v_path is null
     or public.legal_gate_allows_path(v_path, pg_catalog.current_setting('request.method', true)) then
    return;
  end if;
  -- Claude's sessions always; portal sessions once the admin switch is on.
  if coalesce(v_jwt -> 'app_metadata' ->> 'provider', '') <> 'mcp'
     and not public.feature_enabled('legal.enforce_data_api') then
    return;
  end if;
  v_sub := v_jwt ->> 'sub';
  if v_sub is null or v_sub !~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' then
    return;
  end if;
  if not coalesce(public.legal_gate_open(v_sub::uuid), false) then
    raise exception 'legal_agreement_required: agree to the current Terms of Use and Privacy Policy in the Rep Portal first'
      using errcode = '42501';
  end if;
end;
$$;

comment on function public.postgrest_pre_request() is
  'PostgREST pre-request function (role authenticator, pgrst.db_pre_request). '
  'Refuses a JWT that carries a client_id claim; refuses a signed-in user who '
  'has not agreed to the current Terms of Use and Privacy Policy (always for '
  'an MCP session, for portal sessions while app_settings '
  'legal.enforce_data_api is on), outside legal_gate_allows_path(). Do NOT '
  'drop or rename it without first clearing the role setting: PostgREST '
  'calls it by name on every Data API request.';

revoke execute on function public.postgrest_pre_request() from public;
grant execute on function public.postgrest_pre_request() to anon, authenticated, service_role;

alter role authenticator set pgrst.db_pre_request = 'public.postgrest_pre_request';
notify pgrst, 'reload config';
