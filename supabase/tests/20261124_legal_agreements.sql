/*============================================================================
  20261124_legal_agreements.sql — assertions for the Terms of Use / Privacy
  Policy click-wrap.

  Companion to 20261124090000_legal_agreements.sql (and the documents seeded
  by 20261124090100). Proves that:
    - anyone, signed in or not, reads the documents in force, and nobody
      sees a version before its effective date;
    - a document version cannot be changed or removed, by anyone;
    - accept_legal_documents() is the only write path, stamps the caller,
      the time, a profile snapshot, the hash of what was agreed to, and the
      request's IP and browser; is idempotent; and refuses a stale version,
      a future one, an MCP session, a connected app's token and a
      deactivated account;
    - an agreement record cannot be changed or removed, but survives the
      deletion of the profile with user_id cleared;
    - a new version puts everyone back to "not agreed", remembering the
      last version they did agree to;
    - an admin viewing as a rep is asked about, and agrees for, themselves;
      inside sales can agree;
    - only an admin reads other people's agreements or admin_legal_status();
    - legal_documents carries both read-only triggers, legal_acceptances
      neither (the sweep exemption), and a sweep that attaches them anyway
      still lets inside sales and an admin mid-view-as agree;
    - the Data API refuses someone who has not agreed (always for an MCP
      session, for portal sessions once legal.enforce_data_api is on),
      except the calls the sign-in and the agreement screen need;
    - log_usage() records nothing before the agreement;
    - legal_gate_open() answers only about yourself (admins: anyone);
    - not even service_role writes a document or an agreement, and an
      insert cannot choose its own version, hash or time.

  Runs entirely inside a transaction and ROLLS BACK.

      psql "$DATABASE_URL" -f supabase/tests/20261124_legal_agreements.sql

  Any error is a failure; a clean run printing "ALL LEGAL AGREEMENT TESTS
  PASSED" is the pass condition.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('admin',  'a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1'),
  ('rep',    'b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2'),
  ('rep2',   'c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3'),
  ('entry',  'd4d4d4d4-d4d4-4d4d-8d4d-d4d4d4d4d4d4'),
  ('gone',   'e5e5e5e5-e5e5-4e5e-8e5e-e5e5e5e5e5e5'),
  ('off',    'f6f6f6f6-f6f6-4f6f-8f6f-f6f6f6f6f6f6');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@legal.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set role = 'admin', full_name = 'Lena Admin', email = 'admin@legal.test'
  where user_id = (select id from t_user where label = 'admin');
update public.profiles set full_name = 'Rex Rep', email = 'rep@legal.test', sales_rep_key = 'LG REP'
  where user_id = (select id from t_user where label = 'rep');
update public.profiles set full_name = 'Rae Rep', email = 'rep2@legal.test'
  where user_id = (select id from t_user where label = 'rep2');
update public.profiles set role = 'order_entry', full_name = 'Ivy Inside'
  where user_id = (select id from t_user where label = 'entry');
update public.profiles set full_name = 'Gus Gone'
  where user_id = (select id from t_user where label = 'gone');
update public.profiles set full_name = 'Otto Off', active = false
  where user_id = (select id from t_user where label = 'off');

-- This file's own current versions, newer than anything seeded, so the
-- assertions do not depend on the seeded text. Plus one older version of
-- each (stale) and one not yet in force (future).
create temporary table t_doc (label text primary key, id bigint) on commit drop;
with ins as (
  insert into public.legal_documents (doc_key, version, title, summary, body_md, effective_at)
  values
    ('terms',   'test-old',    'Old Terms',    null,        'Old terms body.',    now() - interval '2 days'),
    ('privacy', 'test-old',    'Old Privacy',  null,        'Old privacy body.',  now() - interval '2 days'),
    ('terms',   'test-cur',    'Terms of Use', 'Be good.',  'Terms body.',        now() - interval '1 second'),
    ('privacy', 'test-cur',    'Privacy',      'We count.', 'Privacy body.',      now() - interval '1 second'),
    ('terms',   'test-future', 'Future Terms', null,        'Future terms body.', now() + interval '7 days')
  returning id, doc_key, version
)
insert into t_doc (label, id)
select doc_key || ':' || version, id from ins;

-- The helpers below read these from inside `set local role` blocks.
grant select on t_user, t_doc to anon, authenticated;

create or replace function pg_temp.doc(p_label text) returns bigint
language sql stable as $$ select id from t_doc where label = p_label $$;

create or replace function pg_temp.uid(p_label text) returns uuid
language sql stable as $$ select id from t_user where label = p_label $$;

/** Claims for p_user; p_extra merges into them (app_metadata, client_id). */
create or replace function pg_temp.be(p_user uuid, p_extra jsonb default '{}'::jsonb) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     (jsonb_build_object('sub', p_user, 'role', 'authenticated') || p_extra)::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.headers',
                     jsonb_build_object('x-forwarded-for', '203.0.113.7, 10.0.0.1',
                                        'user-agent', 'LegalTest/1.0 (iPhone)')::text, true);
end;
$$;

/** accept_legal_documents() as the user, under RLS. */
create or replace function pg_temp.accept_as(p_user uuid, p_ids bigint[], p_extra jsonb default '{}'::jsonb)
returns jsonb
language plpgsql as $$
declare j jsonb;
begin
  perform pg_temp.be(p_user, p_extra);
  execute 'set local role authenticated';
  select public.accept_legal_documents(p_ids) into j;
  execute 'reset role';
  return j;
exception when others then
  execute 'reset role';
  raise;
end;
$$;

/** The SQLERRM accept_legal_documents() raises for this call, or null. */
create or replace function pg_temp.accept_error(p_user uuid, p_ids bigint[], p_extra jsonb default '{}'::jsonb)
returns text
language plpgsql as $$
begin
  perform pg_temp.accept_as(p_user, p_ids, p_extra);
  return null;
exception when others then
  return sqlerrm;
end;
$$;

create or replace function pg_temp.status_as(p_user uuid) returns jsonb
language plpgsql as $$
declare j jsonb;
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select public.legal_status() into j;
  execute 'reset role';
  return j;
end;
$$;

/** The status entry for one doc_key. */
create or replace function pg_temp.entry(p_status jsonb, p_key text) returns jsonb
language sql immutable as $$
  select d from jsonb_array_elements(p_status -> 'documents') d where d ->> 'doc_key' = p_key
$$;

/** The error postgrest_pre_request() raises for this request, or null. */
create or replace function pg_temp.pre_request_error(
  p_user uuid, p_path text, p_method text, p_extra jsonb default '{}'::jsonb)
returns text
language plpgsql as $$
begin
  perform pg_temp.be(p_user, p_extra);
  perform set_config('request.path', coalesce(p_path, ''), true);
  perform set_config('request.method', p_method, true);
  execute 'set local role authenticated';
  perform public.postgrest_pre_request();
  execute 'reset role';
  perform set_config('request.path', '', true);
  return null;
exception when others then
  execute 'reset role';
  perform set_config('request.path', '', true);
  return sqlerrm;
end;
$$;

/** log_usage() as the user; rows written. */
create or replace function pg_temp.log_usage_as(p_user uuid) returns integer
language plpgsql as $$
declare n integer;
begin
  perform pg_temp.be(p_user);
  execute 'set local role authenticated';
  select public.log_usage(jsonb_build_array(jsonb_build_object('event', 'page_view', 'page', 'overview'))) into n;
  execute 'reset role';
  return n;
end;
$$;

/** As nobody in particular: what a migration or the table owner sees. */
create or replace function pg_temp.nobody() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.headers', '', true);
end;
$$;

do $$
declare
  v_admin uuid := pg_temp.uid('admin');
  v_rep   uuid := pg_temp.uid('rep');
  v_rep2  uuid := pg_temp.uid('rep2');
  v_entry uuid := pg_temp.uid('entry');
  v_gone  uuid := pg_temp.uid('gone');
  v_off   uuid := pg_temp.uid('off');
  v_cur   bigint[] := array[pg_temp.doc('terms:test-cur'), pg_temp.doc('privacy:test-cur')];
  j       jsonb;
  n       integer;
  t1      timestamptz;
  e       text;
  r       record;
begin
  ----------------------------------------------------------------------
  -- T1: anyone reads what is in force; nobody sees the future version.
  ----------------------------------------------------------------------
  execute 'set local role anon';
  select count(*) into n from public.legal_current_documents();
  if n <> 2 then raise exception 'T1 FAIL: anon sees % current documents, expected 2', n; end if;
  if exists (select 1 from public.legal_current_documents() c
             where c.id <> all (array[pg_temp.doc('terms:test-cur'), pg_temp.doc('privacy:test-cur')])) then
    raise exception 'T1 FAIL: the current documents are not the newest effective versions';
  end if;
  if exists (select 1 from public.legal_documents where version = 'test-future') then
    raise exception 'T1 FAIL: anon can read a version before its effective date';
  end if;
  if not exists (select 1 from public.legal_documents where version = 'test-old') then
    raise exception 'T1 FAIL: anon cannot read an earlier version that was in force';
  end if;
  begin
    perform public.legal_status();
    raise exception 'T1 FAIL: anon called legal_status()';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.accept_legal_documents(v_cur);
    raise exception 'T1 FAIL: anon called accept_legal_documents()';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';

  ----------------------------------------------------------------------
  -- T2: a document version cannot be written by a user, nor changed or
  -- removed by anyone (the trigger holds even for the table owner).
  ----------------------------------------------------------------------
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  begin
    insert into public.legal_documents (doc_key, version, title, body_md) values ('terms', 'x', 'x', 'x');
    raise exception 'T2 FAIL: an admin inserted a legal document over the API';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  begin
    update public.legal_documents set body_md = 'edited' where id = pg_temp.doc('terms:test-cur');
    raise exception 'T2 FAIL: a published version was edited';
  exception when insufficient_privilege then
    if sqlerrm not like 'legal_documents_immutable%' then raise; end if;
  end;
  begin
    delete from public.legal_documents where id = pg_temp.doc('terms:test-old');
    raise exception 'T2 FAIL: a published version was deleted';
  exception when insufficient_privilege then
    if sqlerrm not like 'legal_documents_immutable%' then raise; end if;
  end;
  if (select content_sha256 from public.legal_documents where id = pg_temp.doc('terms:test-cur'))
     <> encode(sha256(convert_to('Terms of Use' || E'\n\n' || 'Be good.' || E'\n\n' || 'Terms body.', 'UTF8')), 'hex') then
    raise exception 'T2 FAIL: content_sha256 is not the hash of title, summary and body';
  end if;

  ----------------------------------------------------------------------
  -- T3: a new user has agreed to nothing.
  ----------------------------------------------------------------------
  j := pg_temp.status_as(v_rep);
  if (j ->> 'all_accepted')::boolean then raise exception 'T3 FAIL: a new rep counts as agreed'; end if;
  if jsonb_array_length(j -> 'documents') <> 2 then
    raise exception 'T3 FAIL: % documents in the status, expected 2', jsonb_array_length(j -> 'documents');
  end if;
  if (j -> 'documents' -> 0 ->> 'doc_key') <> 'terms' then
    raise exception 'T3 FAIL: the terms do not come first';
  end if;
  if pg_temp.entry(j, 'terms') ->> 'accepted_at' is not null
     or pg_temp.entry(j, 'terms') ->> 'last_accepted_version' is not null then
    raise exception 'T3 FAIL: a new rep shows an agreement';
  end if;

  ----------------------------------------------------------------------
  -- T4: no direct insert; agreeing writes the caller's rows with the
  -- snapshot, the hash and the request's IP and browser.
  ----------------------------------------------------------------------
  perform pg_temp.be(v_rep);
  execute 'set local role authenticated';
  begin
    insert into public.legal_acceptances (user_id, document_id, doc_key, version, content_sha256)
    values (v_rep, v_cur[1], 'terms', 'test-cur', 'x');
    raise exception 'T4 FAIL: a rep inserted an agreement directly';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';

  j := pg_temp.accept_as(v_rep, v_cur);
  if not (j ->> 'all_accepted')::boolean then raise exception 'T4 FAIL: agreeing to both did not complete'; end if;
  if pg_temp.entry(j, 'privacy') ->> 'accepted_at' is null then
    raise exception 'T4 FAIL: the returned status does not show the privacy agreement';
  end if;
  select count(*) into n from public.legal_acceptances where user_id = v_rep;
  if n <> 2 then raise exception 'T4 FAIL: % agreement rows, expected 2', n; end if;
  if exists (
    select 1 from public.legal_acceptances a
    join public.legal_documents d on d.id = a.document_id
    where a.user_id = v_rep
      and not (a.version = d.version and a.doc_key = d.doc_key
               and a.content_sha256 = d.content_sha256 and a.content_sha256 <> ''
               and a.full_name = 'Rex Rep' and a.email = 'rep@legal.test' and a.role = 'rep'
               and a.ip_address = '203.0.113.7'
               and a.user_agent = 'LegalTest/1.0 (iPhone)'
               and a.accepted_at > now() - interval '1 minute')
  ) then
    raise exception 'T4 FAIL: an agreement row is missing its snapshot, hash, IP or user agent';
  end if;

  ----------------------------------------------------------------------
  -- T5: agreeing again changes nothing (the first time is the record).
  ----------------------------------------------------------------------
  select min(accepted_at) into t1 from public.legal_acceptances where user_id = v_rep;
  j := pg_temp.accept_as(v_rep, v_cur);
  select count(*) into n from public.legal_acceptances where user_id = v_rep;
  if n <> 2 then raise exception 'T5 FAIL: agreeing twice wrote % rows', n; end if;
  if (select min(accepted_at) from public.legal_acceptances where user_id = v_rep) <> t1 then
    raise exception 'T5 FAIL: agreeing twice moved the timestamp';
  end if;

  ----------------------------------------------------------------------
  -- T6: only the current version of a document can be agreed to.
  ----------------------------------------------------------------------
  e := pg_temp.accept_error(v_rep2, array[pg_temp.doc('terms:test-old')]);
  if e is null or e not like 'legal_document_not_current%' then
    raise exception 'T6 FAIL: an outdated version was accepted (%)', e;
  end if;
  e := pg_temp.accept_error(v_rep2, array[v_cur[1], pg_temp.doc('terms:test-future')]);
  if e is null or e not like 'legal_document_not_current%' then
    raise exception 'T6 FAIL: a version not yet in force was accepted (%)', e;
  end if;
  e := pg_temp.accept_error(v_rep2, array[]::bigint[]);
  if e is null or e not like 'no_documents%' then
    raise exception 'T6 FAIL: an empty list was accepted (%)', e;
  end if;
  e := pg_temp.accept_error(v_rep2, array[v_cur[1], null]);
  if e is null or e not like 'legal_document_not_current%' then
    raise exception 'T6 FAIL: a null id was accepted (%)', e;
  end if;
  if exists (select 1 from public.legal_acceptances where user_id = v_rep2) then
    raise exception 'T6 FAIL: a refused call left a row behind';
  end if;

  ----------------------------------------------------------------------
  -- T7: Claude never agrees for anyone: not an MCP session, not a
  -- connected app's OAuth token.
  ----------------------------------------------------------------------
  e := pg_temp.accept_error(v_rep2, v_cur, '{"app_metadata": {"provider": "mcp"}}'::jsonb);
  if e is null or e not like 'legal_acceptance_in_portal_only%' then
    raise exception 'T7 FAIL: an MCP session agreed for its user (%)', e;
  end if;
  e := pg_temp.accept_error(v_rep2, v_cur, '{"client_id": "claude-ai"}'::jsonb);
  if e is null or e not like 'legal_acceptance_in_portal_only%' then
    raise exception 'T7 FAIL: a connected app token agreed for its user (%)', e;
  end if;

  ----------------------------------------------------------------------
  -- T8: a deactivated account cannot agree.
  ----------------------------------------------------------------------
  e := pg_temp.accept_error(v_off, v_cur);
  if e is null or e not like 'inactive_profile%' then
    raise exception 'T8 FAIL: a deactivated account agreed (%)', e;
  end if;

  ----------------------------------------------------------------------
  -- T9: reading. Your own rows; another rep's are invisible; an admin
  -- reads all.
  ----------------------------------------------------------------------
  perform pg_temp.be(v_rep2);
  execute 'set local role authenticated';
  if exists (select 1 from public.legal_acceptances) then
    execute 'reset role';
    raise exception 'T9 FAIL: a rep can read another rep''s agreement';
  end if;
  execute 'reset role';
  perform pg_temp.be(v_rep);
  execute 'set local role authenticated';
  select count(*) into n from public.legal_acceptances;
  execute 'reset role';
  if n <> 2 then raise exception 'T9 FAIL: a rep reads % of their own rows, expected 2', n; end if;
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  select count(*) into n from public.legal_acceptances where user_id = v_rep;
  execute 'reset role';
  if n <> 2 then raise exception 'T9 FAIL: an admin reads % of the rep''s rows, expected 2', n; end if;

  ----------------------------------------------------------------------
  -- T10: an agreement record is append-only, even for the table owner,
  -- but survives the deletion of the person's login.
  ----------------------------------------------------------------------
  begin
    update public.legal_acceptances set accepted_at = now() - interval '1 year' where user_id = v_rep;
    raise exception 'T10 FAIL: an agreement was backdated';
  exception when insufficient_privilege then
    if sqlerrm not like 'legal_acceptances_append_only%' then raise; end if;
  end;
  begin
    delete from public.legal_acceptances where user_id = v_rep;
    raise exception 'T10 FAIL: an agreement was deleted';
  exception when insufficient_privilege then
    if sqlerrm not like 'legal_acceptances_append_only%' then raise; end if;
  end;
  perform pg_temp.accept_as(v_gone, v_cur);
  delete from auth.users where id = v_gone;   -- cascades to the profile
  select count(*) into n from public.legal_acceptances
  where user_id is null and full_name = 'Gus Gone';
  if n <> 2 then
    raise exception 'T10 FAIL: deleting the login took the agreement with it (% rows left)', n;
  end if;

  ----------------------------------------------------------------------
  -- T11: an admin viewing as a rep is asked about, and agrees for,
  -- themselves.
  ----------------------------------------------------------------------
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  perform public.start_impersonation(v_rep);
  execute 'reset role';
  j := pg_temp.status_as(v_admin);
  if (j ->> 'all_accepted')::boolean then
    raise exception 'T11 FAIL: viewing as an agreed rep made the admin count as agreed';
  end if;
  j := pg_temp.accept_as(v_admin, v_cur);
  if not (j ->> 'all_accepted')::boolean then
    raise exception 'T11 FAIL: the admin could not agree while viewing as a rep';
  end if;
  if (select count(*) from public.legal_acceptances where user_id = v_admin) <> 2
     or (select count(*) from public.legal_acceptances where user_id = v_rep) <> 2 then
    raise exception 'T11 FAIL: the agreement was recorded against the wrong person';
  end if;
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  perform public.stop_impersonation();
  execute 'reset role';

  ----------------------------------------------------------------------
  -- T12: inside sales can agree (no read-only trigger on the table).
  ----------------------------------------------------------------------
  j := pg_temp.accept_as(v_entry, v_cur);
  if not (j ->> 'all_accepted')::boolean then raise exception 'T12 FAIL: inside sales could not agree'; end if;
  if (select role from public.legal_acceptances where user_id = v_entry limit 1) <> 'order_entry' then
    raise exception 'T12 FAIL: the role snapshot is wrong';
  end if;

  ----------------------------------------------------------------------
  -- T13: admin_legal_status(): the admin sees everyone; a rep sees nothing.
  ----------------------------------------------------------------------
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  select * into r from public.admin_legal_status() where user_id = v_rep;
  if not r.all_accepted or r.accepted_at is null or r.pending <> '{}' then
    raise exception 'T13 FAIL: the agreed rep reads as % / % / %', r.all_accepted, r.accepted_at, r.pending;
  end if;
  select * into r from public.admin_legal_status() where user_id = v_rep2;
  if r.all_accepted or r.accepted_at is not null or r.pending <> array['privacy', 'terms'] then
    raise exception 'T13 FAIL: the rep who never agreed reads as % / % / %', r.all_accepted, r.accepted_at, r.pending;
  end if;
  execute 'reset role';
  perform pg_temp.be(v_rep);
  execute 'set local role authenticated';
  select count(*) into n from public.admin_legal_status();
  execute 'reset role';
  if n <> 0 then raise exception 'T13 FAIL: a rep reads admin_legal_status() (% rows)', n; end if;

  ----------------------------------------------------------------------
  -- T14: a new version puts everyone back to "not agreed", remembering
  -- the last version they did agree to.
  ----------------------------------------------------------------------
  insert into public.legal_documents (doc_key, version, title, body_md, effective_at)
  values ('privacy', 'test-next', 'Privacy', 'Privacy body, revised.', now());
  j := pg_temp.status_as(v_rep);
  if (j ->> 'all_accepted')::boolean then
    raise exception 'T14 FAIL: a new privacy version did not ask the rep again';
  end if;
  if pg_temp.entry(j, 'terms') ->> 'accepted_at' is null then
    raise exception 'T14 FAIL: the unchanged terms lost their agreement';
  end if;
  if pg_temp.entry(j, 'privacy') ->> 'accepted_at' is not null
     or pg_temp.entry(j, 'privacy') ->> 'last_accepted_version' <> 'test-cur'
     or pg_temp.entry(j, 'privacy') ->> 'last_accepted_at' is null then
    raise exception 'T14 FAIL: the privacy entry reads %', pg_temp.entry(j, 'privacy');
  end if;
  e := pg_temp.accept_error(v_rep, array[pg_temp.doc('privacy:test-cur')]);
  if e is null or e not like 'legal_document_not_current%' then
    raise exception 'T14 FAIL: the superseded version could still be agreed to (%)', e;
  end if;

  ----------------------------------------------------------------------
  -- T15: the sweeps. legal_documents carries both read-only triggers;
  -- legal_acceptances neither (inside sales and view-as must agree).
  ----------------------------------------------------------------------
  if (select count(*) from pg_trigger
      where tgrelid = 'public.legal_documents'::regclass
        and tgname in ('trg_legal_documents_no_write_while_viewing_as',
                       'trg_legal_documents_read_only_role')) <> 2 then
    raise exception 'T15 FAIL: legal_documents is missing a read-only trigger';
  end if;
  if exists (select 1 from pg_trigger
             where tgrelid = 'public.legal_acceptances'::regclass
               and tgname in ('trg_legal_acceptances_no_write_while_viewing_as',
                              'trg_legal_acceptances_read_only_role')) then
    raise exception 'T15 FAIL: legal_acceptances carries a read-only trigger; inside sales could never agree';
  end if;

  ----------------------------------------------------------------------
  -- T16: the Data API door (postgrest_pre_request). The rep agrees to the
  -- current versions again (T14 published a new privacy version); rep2
  -- never has.
  ----------------------------------------------------------------------
  perform pg_temp.accept_as(v_rep, array[pg_temp.doc('terms:test-cur'),
    (select id from public.legal_documents where version = 'test-next')]);
  perform pg_temp.nobody();

  -- Claude's sessions: always.
  e := pg_temp.pre_request_error(v_rep2, '/v_account_list', 'GET', '{"app_metadata": {"provider": "mcp"}}');
  if e is null or e not like 'legal_agreement_required%' then
    raise exception 'T16 FAIL: an MCP session read for someone who never agreed (%)', e;
  end if;
  e := pg_temp.pre_request_error(v_rep2, '/rpc/legal_status', 'POST', '{"app_metadata": {"provider": "mcp"}}');
  if e is not null then raise exception 'T16 FAIL: the MCP gate''s own question was refused (%)', e; end if;
  e := pg_temp.pre_request_error(v_rep2, '/rest/v1/rpc/legal_status', 'POST', '{"app_metadata": {"provider": "mcp"}}');
  if e is not null then raise exception 'T16 FAIL: the /rest/v1 prefix was not understood (%)', e; end if;
  e := pg_temp.pre_request_error(v_rep, '/v_account_list', 'GET', '{"app_metadata": {"provider": "mcp"}}');
  if e is not null then raise exception 'T16 FAIL: an MCP session was refused for someone who agreed (%)', e; end if;

  -- Portal sessions: only once the admin switch is on.
  e := pg_temp.pre_request_error(v_rep2, '/v_account_list', 'GET');
  if e is not null then raise exception 'T16 FAIL: the switch is off but a portal read was refused (%)', e; end if;
  perform pg_temp.nobody();
  update public.app_settings set enabled = true where setting_key = 'legal.enforce_data_api';
  if not found then raise exception 'T16 FAIL: the legal.enforce_data_api switch was not seeded'; end if;

  e := pg_temp.pre_request_error(v_rep2, '/v_account_list', 'GET');
  if e is null or e not like 'legal_agreement_required%' then
    raise exception 'T16 FAIL: with the switch on, someone who never agreed read the Data API (%)', e;
  end if;
  e := pg_temp.pre_request_error(v_rep2, '/rpc/graphql', 'POST');
  if e is null then raise exception 'T16 FAIL: GraphQL is not behind the door'; end if;
  if pg_temp.pre_request_error(v_rep2, '/rpc/accept_legal_documents', 'POST') is not null
     or pg_temp.pre_request_error(v_rep2, '/rpc/legal_current_documents', 'POST') is not null
     or pg_temp.pre_request_error(v_rep2, '/legal_documents', 'GET') is not null
     or pg_temp.pre_request_error(v_rep2, '/rpc/acting_context', 'POST') is not null
     or pg_temp.pre_request_error(v_rep2, '/rpc/log_login', 'POST') is not null
     or pg_temp.pre_request_error(v_rep2, '/rpc/stop_impersonation', 'POST') is not null
     or pg_temp.pre_request_error(v_rep2, '/profiles', 'GET') is not null
     or pg_temp.pre_request_error(v_rep2, '/profiles', 'HEAD') is not null then
    raise exception 'T16 FAIL: a call the sign-in or the agreement screen needs was refused';
  end if;
  if pg_temp.pre_request_error(v_rep2, '/profiles', 'PATCH') is null
     or pg_temp.pre_request_error(v_rep2, '/profiles_backup', 'GET') is null
     or pg_temp.pre_request_error(v_rep2, '/rpc/legal_status_x', 'POST') is null
     or pg_temp.pre_request_error(v_rep2, '/x/rpc/legal_status', 'POST') is null
     or pg_temp.pre_request_error(v_rep2, '/rpc/log_usage', 'POST') is null then
    raise exception 'T16 FAIL: the allow-list matches more than it names';
  end if;
  if pg_temp.pre_request_error(v_rep, '/v_account_list', 'GET') is not null then
    raise exception 'T16 FAIL: someone who agreed was refused';
  end if;
  if pg_temp.pre_request_error(v_rep2, null, 'GET') is not null then
    raise exception 'T16 FAIL: a call outside PostgREST (no request.path) was refused';
  end if;
  if pg_temp.pre_request_error(v_rep2, '/v_account_list', 'GET', '{"role": "service_role"}') is not null
     or pg_temp.pre_request_error(v_rep2, '/legal_documents', 'GET', '{"role": "anon"}') is not null then
    raise exception 'T16 FAIL: service_role or anon was put behind the agreement';
  end if;
  e := pg_temp.pre_request_error(v_rep, '/v_account_list', 'GET', '{"client_id": "x"}');
  if e is null or e not like 'oauth_client_token%' then
    raise exception 'T16 FAIL: a connected app''s token is no longer refused first (%)', e;
  end if;
  perform pg_temp.nobody();
  update public.app_settings set enabled = false where setting_key = 'legal.enforce_data_api';

  ----------------------------------------------------------------------
  -- T17: usage is recorded only after the agreement.
  ----------------------------------------------------------------------
  if pg_temp.log_usage_as(v_rep2) <> 0 then
    raise exception 'T17 FAIL: usage was recorded for someone who never agreed';
  end if;
  if pg_temp.log_usage_as(v_rep) <> 1 then
    raise exception 'T17 FAIL: usage was not recorded for someone who agreed';
  end if;

  ----------------------------------------------------------------------
  -- T18: legal_gate_open() answers about yourself, or an admin about
  -- anyone; nobody else learns who has agreed.
  ----------------------------------------------------------------------
  perform pg_temp.be(v_rep);
  execute 'set local role authenticated';
  if public.legal_gate_open(v_rep) is not true then
    execute 'reset role';
    raise exception 'T18 FAIL: the rep cannot see that they agreed';
  end if;
  if public.legal_gate_open(v_rep2) is not null then
    execute 'reset role';
    raise exception 'T18 FAIL: a rep learned whether another rep agreed';
  end if;
  execute 'reset role';
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  if public.legal_gate_open(v_rep2) is not false then
    execute 'reset role';
    raise exception 'T18 FAIL: an admin cannot see who has not agreed';
  end if;
  execute 'reset role';

  ----------------------------------------------------------------------
  -- T19: not even the service key writes the evidence or the documents.
  ----------------------------------------------------------------------
  perform pg_temp.nobody();
  execute 'set local role service_role';
  begin
    insert into public.legal_acceptances (user_id, document_id, doc_key, version, content_sha256)
    values (v_rep2, pg_temp.doc('terms:test-cur'), 'terms', 'bogus', 'deadbeef');
    execute 'reset role';
    raise exception 'T19 FAIL: service_role forged an agreement';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.legal_acceptances set accepted_at = now() - interval '3 years';
    execute 'reset role';
    raise exception 'T19 FAIL: service_role backdated an agreement';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.legal_documents (doc_key, version, title, body_md) values ('terms', 'svc', 'x', 'x');
    execute 'reset role';
    raise exception 'T19 FAIL: service_role published a document';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';

  ----------------------------------------------------------------------
  -- T20: whatever an insert says, the record carries the document's
  -- version and hash and the time it was written.
  ----------------------------------------------------------------------
  insert into public.legal_acceptances (user_id, document_id, doc_key, version, content_sha256, accepted_at)
  values (v_rep2, pg_temp.doc('terms:test-cur'), 'privacy', 'bogus', 'deadbeef', now() - interval '3 years');
  if exists (
    select 1 from public.legal_acceptances a
    join public.legal_documents d on d.id = a.document_id
    where a.user_id = v_rep2
      and (a.doc_key <> d.doc_key or a.version <> d.version or a.content_sha256 <> d.content_sha256
           or a.accepted_at < now() - interval '1 minute')) then
    raise exception 'T20 FAIL: an insert recorded a version, hash or time of its own choosing';
  end if;

  ----------------------------------------------------------------------
  -- T21: a later sweep that attaches its trigger here anyway changes
  -- nothing: inside sales, and an admin mid-view-as, still agree.
  ----------------------------------------------------------------------
  create trigger trg_legal_acceptances_read_only_role
    before insert or update or delete on public.legal_acceptances
    for each row execute function public.block_writes_for_read_only_role();
  create trigger trg_legal_acceptances_no_write_while_viewing_as
    before insert or update or delete on public.legal_acceptances
    for each row execute function public.block_writes_while_impersonating();
  j := pg_temp.accept_as(v_entry, array[pg_temp.doc('terms:test-cur'),
    (select id from public.legal_documents where version = 'test-next')]);
  if not (j ->> 'all_accepted')::boolean then
    raise exception 'T21 FAIL: a swept trigger locked inside sales out';
  end if;
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  perform public.start_impersonation(v_rep);
  execute 'reset role';
  j := pg_temp.accept_as(v_admin, array[pg_temp.doc('terms:test-cur'),
    (select id from public.legal_documents where version = 'test-next')]);
  if not (j ->> 'all_accepted')::boolean then
    raise exception 'T21 FAIL: a swept trigger stopped an admin agreeing mid-view-as';
  end if;
  perform pg_temp.be(v_admin);
  execute 'set local role authenticated';
  perform public.stop_impersonation();
  execute 'reset role';
  -- The other tables keep their read-only rules.
  perform pg_temp.be(v_entry);
  execute 'set local role authenticated';
  begin
    insert into public.notes (customer_key, body) values ('LG-NONE', 'x');
    execute 'reset role';
    raise exception 'T21 FAIL: the exemption leaked to another table';
  exception when insufficient_privilege then
    execute 'reset role';
  end;
  drop trigger trg_legal_acceptances_read_only_role on public.legal_acceptances;
  drop trigger trg_legal_acceptances_no_write_while_viewing_as on public.legal_acceptances;

  raise notice 'ALL LEGAL AGREEMENT TESTS PASSED';
end;
$$;

rollback;
