/*============================================================================
  20261116_mcp_oauth.sql: assertions for 20261116120000_mcp_oauth (Claude
  signs in to the MCP endpoint with OAuth).

  Same harness as 034_mcp_access.sql / 20261111_mcp_orders.sql: one
  transaction, ROLLED BACK, throwaway users. JWTs are faked with
  request.jwt.claims, in the three shapes that matter here:

    portal    a signed-in person            {sub, role, app_metadata.provider=email}
    raw       the access token Supabase     the same plus client_id and
              Auth gives an OAuth client    session_id
    mcp       what the mcp Edge Function    {sub, role, app_metadata.provider=mcp,
              mints after checking a raw    mcp_oauth_connection_id,
              token                         mcp_oauth_session_id}

      psql "$DATABASE_URL" -f supabase/tests/20261116_mcp_oauth.sql

  A clean run prints "ALL MCP OAUTH TESTS PASSED"; any error is a failure.

  What is being proved
  --------------------
  1. Resolving an OAuth token is the gateway's job alone, answers only for a
     live grant of an active user, and records the connection.
  2. The order-drafting gate treats an OAuth connection like a token row,
     and stops the moment the grant is revoked.
  3. The raw token is good for nothing but the MCP endpoint: the Data API
     refuses it, no table accepts a write under it, Storage shows it
     nothing. A portal session is untouched by all three.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'd1d1d1d1-1111-4111-8111-111111111111'),
  ('other', 'd2d2d2d2-2222-4222-8222-222222222222'),
  ('admin', 'd3d3d3d3-3333-4333-8333-333333333333'),
  ('gone',  'd4d4d4d4-4444-4444-8444-444444444444');
grant select on t_user to authenticated, service_role;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@mcpoauth.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'OA REP', full_name = 'Oa Rep'
  where user_id = (select id from t_user where label = 'rep');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');
update public.profiles set active = false
  where user_id = (select id from t_user where label = 'gone');

-- OAuth clients (auth.oauth_clients ids) and the sessions Supabase Auth
-- would hold for them.
create temporary table t_ref (label text primary key, id uuid) on commit drop;
insert into t_ref (label, id) values
  ('claude',       'c1a0de00-0000-4000-8000-000000000001'),
  ('other_client', 'c1a0de00-0000-4000-8000-000000000002'),
  ('s_rep',        '5e550000-0000-4000-8000-000000000001'),  -- rep, via claude
  ('s_rep_portal', '5e550000-0000-4000-8000-000000000002'),  -- rep, signed in to the portal
  ('s_rep_old',    '5e550000-0000-4000-8000-000000000003'),  -- rep, via claude, expired
  ('s_admin',      '5e550000-0000-4000-8000-000000000004'),  -- admin, via claude
  ('s_gone',       '5e550000-0000-4000-8000-000000000005'),  -- deactivated user, via claude
  ('s_other',      '5e550000-0000-4000-8000-000000000006');  -- other, via claude
grant select on t_ref to authenticated, service_role;

insert into auth.sessions (id, user_id, oauth_client_id, not_after) values
  ((select id from t_ref where label = 's_rep'),        (select id from t_user where label = 'rep'),
   (select id from t_ref where label = 'claude'), null),
  ((select id from t_ref where label = 's_rep_portal'), (select id from t_user where label = 'rep'),
   null, null),
  ((select id from t_ref where label = 's_rep_old'),    (select id from t_user where label = 'rep'),
   (select id from t_ref where label = 'claude'), now() - interval '1 minute'),
  ((select id from t_ref where label = 's_admin'),      (select id from t_user where label = 'admin'),
   (select id from t_ref where label = 'claude'), now() + interval '1 day'),
  ((select id from t_ref where label = 's_gone'),       (select id from t_user where label = 'gone'),
   (select id from t_ref where label = 'claude'), null),
  ((select id from t_ref where label = 's_other'),      (select id from t_user where label = 'other'),
   (select id from t_ref where label = 'claude'), null);

create temporary table t_out (label text primary key, id uuid, at timestamptz) on commit drop;
grant select, insert, update on t_out to authenticated, service_role;

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.u(p_label text) returns uuid
language sql stable as $$ select id from t_user where label = p_label $$;
create or replace function pg_temp.r(p_label text) returns uuid
language sql stable as $$ select id from t_ref where label = p_label $$;

create or replace function pg_temp.claims(p_claims jsonb, p_role text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', p_claims::text, true);
  perform set_config('role', p_role, true);
end $$;

-- A person signed in to the portal.
create or replace function pg_temp.become(p_label text) returns void
language sql as $$
  select pg_temp.claims(jsonb_build_object(
    'sub', pg_temp.u(p_label), 'role', 'authenticated',
    'app_metadata', jsonb_build_object('provider', 'email')), 'authenticated');
$$;

-- The access token Supabase Auth issues to an OAuth client, used as is.
create or replace function pg_temp.become_raw(p_label text, p_session text) returns void
language sql as $$
  select pg_temp.claims(jsonb_build_object(
    'sub', pg_temp.u(p_label), 'role', 'authenticated',
    'client_id', pg_temp.r('claude'), 'session_id', pg_temp.r(p_session),
    'app_metadata', jsonb_build_object('provider', 'email')), 'authenticated');
$$;

-- The JWT the mcp Edge Function mints for an OAuth caller.
create or replace function pg_temp.become_mcp(p_label text, p_conn uuid, p_session uuid) returns void
language sql as $$
  select pg_temp.claims(jsonb_build_object(
    'sub', pg_temp.u(p_label), 'role', 'authenticated',
    'app_metadata', jsonb_build_object(
      'provider', 'mcp',
      'mcp_oauth_connection_id', p_conn,
      'mcp_oauth_session_id', p_session,
      'mcp_oauth_client_id', pg_temp.r('claude'),
      'mcp_scopes', '[]'::jsonb)), 'authenticated');
$$;

create or replace function pg_temp.become_service() returns void
language sql as $$
  select pg_temp.claims(jsonb_build_object('role', 'service_role'), 'service_role');
$$;

create or replace function pg_temp.super() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  reset role;
end $$;

create or replace function pg_temp.rows(p_sql text) returns bigint
language plpgsql as $$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text) returns void
language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

create or replace function pg_temp.assert_fails(p_sql text, p_like text, p_what text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not ilike p_like then
      raise exception 'FAILED: % (rejected, but with "%")', p_what, sqlerrm;
    end if;
    raise notice 'ok  % (rejected: %)', p_what, sqlerrm;
    return;
  end;
  raise exception 'FAILED: % (statement succeeded but should have been rejected)', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. Resolving a token to a user is the gateway's job alone
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert_fails(
  $$select * from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('claude'), pg_temp.r('s_rep'))$$,
  '%permission denied%', 'a signed-in user cannot call mcp_oauth_resolve');
select pg_temp.assert_fails(
  $$select public.mcp_oauth_session_live(pg_temp.u('rep'), pg_temp.r('claude'), pg_temp.r('s_rep'))$$,
  '%permission denied%', 'nor ask whether a session is live');

select pg_temp.super();
select pg_temp.assert(
  not has_function_privilege('anon', 'public.mcp_oauth_resolve(uuid, uuid, uuid)', 'execute')
  and has_function_privilege('service_role', 'public.mcp_oauth_resolve(uuid, uuid, uuid)', 'execute'),
  'mcp_oauth_resolve: service_role yes, anon no');

--------------------------------------------------------------------------
-- 2. The happy path, and that it records the connection once
--------------------------------------------------------------------------
select pg_temp.become_service();
select pg_temp.assert(
  (select count(*) = 1
          and bool_and(r.user_id = pg_temp.u('rep'))
          and bool_and(r.full_name = 'Oa Rep')
          and bool_and(r.user_role = 'rep')
          and bool_and(r.sales_rep_key = 'OA REP')
          and bool_and(r.connection_id is not null)
   from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('claude'), pg_temp.r('s_rep')) r),
  'a live grant of an active user resolves to that user');

insert into t_out (label, id, at)
select 'conn_rep', c.id, c.last_used_at
from public.mcp_oauth_connections c
where c.user_id = pg_temp.u('rep') and c.client_id = pg_temp.r('claude');
select pg_temp.assert((select count(*) = 1 from t_out where label = 'conn_rep'),
  'the first call records one connection');

select pg_temp.assert(
  (select r.connection_id = (select id from t_out where label = 'conn_rep')
   from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('claude'), pg_temp.r('s_rep')) r),
  'a second call returns the same connection');
select pg_temp.assert(
  (select count(*) = 1 and bool_and(c.last_used_at = (select at from t_out where label = 'conn_rep'))
   from public.mcp_oauth_connections c
   where c.user_id = pg_temp.u('rep')),
  'and does not write it again inside five minutes');

select pg_temp.super();
update public.mcp_oauth_connections set last_used_at = now() - interval '10 minutes'
  where id = (select id from t_out where label = 'conn_rep');
select pg_temp.become_service();
select count(*) from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('claude'), pg_temp.r('s_rep'));
select pg_temp.assert(
  (select c.last_used_at > now() - interval '1 minute'
   from public.mcp_oauth_connections c where c.id = (select id from t_out where label = 'conn_rep')),
  'last_used_at moves once the last stamp is older than five minutes');

--------------------------------------------------------------------------
-- 3. Everything that must NOT resolve
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_oauth_resolve(pg_temp.u('other'), pg_temp.r('claude'), pg_temp.r('s_rep'))),
  'another user''s session does not resolve for this user');
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('other_client'), pg_temp.r('s_rep'))),
  'nor a session that belongs to a different client');
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('claude'),
                                                    '5e550000-0000-4000-8000-0000000000ff')),
  'nor a session that does not exist (a revoked grant)');
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('claude'), pg_temp.r('s_rep_old'))),
  'nor an expired session');
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('claude'), pg_temp.r('s_rep_portal'))),
  'nor the user''s own portal session (it has no OAuth client)');
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_oauth_resolve(pg_temp.u('gone'), pg_temp.r('claude'), pg_temp.r('s_gone'))),
  'nor a live grant of a deactivated user');
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_oauth_resolve(null, null, null)),
  'nor nulls');
select pg_temp.assert(
  (select count(*) = 1 from public.mcp_oauth_connections),
  'and none of those recorded a connection');

-- The admin and the other user connect too, for the sections below.
insert into t_out (label, id)
select 'conn_admin', r.connection_id
from public.mcp_oauth_resolve(pg_temp.u('admin'), pg_temp.r('claude'), pg_temp.r('s_admin')) r;
insert into t_out (label, id)
select 'conn_other', r.connection_id
from public.mcp_oauth_resolve(pg_temp.u('other'), pg_temp.r('claude'), pg_temp.r('s_other')) r;

--------------------------------------------------------------------------
-- 4. The connection list: own rows, admin sees all, nobody writes
--------------------------------------------------------------------------
select pg_temp.become('rep');
select pg_temp.assert(
  (select count(*) = 1 and bool_and(user_id = pg_temp.u('rep')) from public.mcp_oauth_connections),
  'a rep sees their own connection and no one else''s');
select pg_temp.assert_fails(
  $$insert into public.mcp_oauth_connections (user_id, client_id) values (pg_temp.u('rep'), pg_temp.r('other_client'))$$,
  '%permission denied%', 'and cannot add one');
select pg_temp.assert_fails(
  $$update public.mcp_oauth_connections set last_used_at = now()$$,
  '%permission denied%', 'or change one');
select pg_temp.assert_fails(
  $$delete from public.mcp_oauth_connections$$,
  '%permission denied%', 'or delete one');

select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) = 3 from public.mcp_oauth_connections),
  'an admin sees every connection');

--------------------------------------------------------------------------
-- 5. The order-drafting gate
--------------------------------------------------------------------------
select pg_temp.super();
update public.app_settings set enabled = true where setting_key = 'feature.mcp_orders';
insert into public.mcp_order_users (user_id, note)
values (pg_temp.u('rep'), 'oauth test'), (pg_temp.u('admin'), 'oauth test')
on conflict (user_id) do nothing;

select pg_temp.become_mcp('rep', (select id from t_out where label = 'conn_rep'), pg_temp.r('s_rep'));
select pg_temp.assert(
  public.mcp_orders_gate() ? 'max_lines',
  'an OAuth connection of an allowed user passes the gate');

select pg_temp.become_mcp('rep', (select id from t_out where label = 'conn_other'), pg_temp.r('s_rep'));
select pg_temp.assert_fails($$select public.mcp_orders_gate()$$,
  'not_mcp_session: the Claude connection is not yours%', 'someone else''s connection does not');

select pg_temp.become_mcp('rep', (select id from t_out where label = 'conn_rep'), pg_temp.r('s_other'));
select pg_temp.assert_fails($$select public.mcp_orders_gate()$$,
  'not_mcp_session: the Claude connection was disconnected%', 'nor one whose session is another user''s');

select pg_temp.become_mcp('rep', (select id from t_out where label = 'conn_rep'), pg_temp.r('s_rep_old'));
select pg_temp.assert_fails($$select public.mcp_orders_gate()$$,
  'not_mcp_session: the Claude connection was disconnected%', 'nor one whose session has expired');

select pg_temp.claims(jsonb_build_object(
  'sub', pg_temp.u('rep'), 'role', 'authenticated',
  'app_metadata', jsonb_build_object('provider', 'mcp', 'mcp_oauth_connection_id', 'not-a-uuid',
                                     'mcp_oauth_session_id', pg_temp.r('s_rep'))), 'authenticated');
select pg_temp.assert_fails($$select public.mcp_orders_gate()$$,
  'not_mcp_session: the session carries no MCP token%', 'nor a malformed connection id');

select pg_temp.claims(jsonb_build_object(
  'sub', pg_temp.u('rep'), 'role', 'authenticated',
  'app_metadata', jsonb_build_object('provider', 'mcp',
                                     'mcp_oauth_connection_id', (select id from t_out where label = 'conn_rep'))),
  'authenticated');
select pg_temp.assert_fails($$select public.mcp_orders_gate()$$,
  'not_mcp_session: the session carries no MCP token%', 'nor a connection with no session id');

select pg_temp.become_mcp('other', (select id from t_out where label = 'conn_other'), pg_temp.r('s_other'));
select pg_temp.assert_fails($$select public.mcp_orders_gate()$$,
  'mcp_user_not_allowed%', 'a live connection of a user who is not on the list is refused for that reason');

-- The raw token is not an MCP session, whatever it claims in its sub.
select pg_temp.become_raw('rep', 's_rep');
select pg_temp.assert_fails($$select public.mcp_orders_gate()$$,
  'not_mcp_session: order drafting is only available to an MCP client%',
  'the raw OAuth token does not pass the gate');

-- Revoking the grant deletes the session; the gate stops at once, inside the
-- five minutes the minted JWT is still good for.
select pg_temp.super();
delete from auth.sessions where id = pg_temp.r('s_rep');
select pg_temp.become_mcp('rep', (select id from t_out where label = 'conn_rep'), pg_temp.r('s_rep'));
select pg_temp.assert_fails($$select public.mcp_orders_gate()$$,
  'not_mcp_session: the Claude connection was disconnected%', 'a revoked grant stops the gate immediately');
select pg_temp.become_service();
select pg_temp.assert(
  (select count(*) = 0 from public.mcp_oauth_resolve(pg_temp.u('rep'), pg_temp.r('claude'), pg_temp.r('s_rep'))),
  'and no longer resolves at the door');

-- A crp_ token still passes, exactly as before.
select pg_temp.become('admin');
insert into t_out (label, id)
select 'tok_admin', t.token_id from public.mcp_token_create('oauth test token') t;
select pg_temp.claims(jsonb_build_object(
  'sub', pg_temp.u('admin'), 'role', 'authenticated',
  'app_metadata', jsonb_build_object('provider', 'mcp',
                                     'mcp_token_id', (select id from t_out where label = 'tok_admin'))),
  'authenticated');
select pg_temp.assert(public.mcp_orders_gate() ? 'max_lines', 'a crp_ token still passes the gate');

--------------------------------------------------------------------------
-- 6. The audit log names the connection
--------------------------------------------------------------------------
select pg_temp.become_mcp('admin', (select id from t_out where label = 'conn_admin'), pg_temp.r('s_admin'));
select public.mcp_log_call('create_order_draft', '{"probe": "own"}'::jsonb, 'refused', 'test');
select pg_temp.become_mcp('admin', (select id from t_out where label = 'conn_other'), pg_temp.r('s_admin'));
select public.mcp_log_call('create_order_draft', '{"probe": "foreign"}'::jsonb, 'refused', 'test');
select pg_temp.super();
select pg_temp.assert(
  (select c.oauth_connection_id = (select id from t_out where label = 'conn_admin') and c.token_id is null
   from public.mcp_tool_calls c where c.args ->> 'probe' = 'own'),
  'an OAuth call is logged against its connection');
select pg_temp.assert(
  (select c.oauth_connection_id is null from public.mcp_tool_calls c where c.args ->> 'probe' = 'foreign'),
  'a connection id that is not the caller''s is not recorded');

--------------------------------------------------------------------------
-- 7. The Data API refuses the raw token (the PostgREST pre-request function)
--------------------------------------------------------------------------
select pg_temp.assert(
  (select rolconfig @> array['pgrst.db_pre_request=public.postgrest_pre_request']
   from pg_roles where rolname = 'authenticator'),
  'the pre-request function is registered on the authenticator role');
select pg_temp.assert(
  has_function_privilege('anon', 'public.postgrest_pre_request()', 'execute')
  and has_function_privilege('authenticated', 'public.postgrest_pre_request()', 'execute')
  and has_function_privilege('service_role', 'public.postgrest_pre_request()', 'execute'),
  'every API role can run it (one that could not would lose the whole Data API)');

select pg_temp.become_raw('admin', 's_admin');
select pg_temp.assert_fails($$select public.postgrest_pre_request()$$,
  'oauth_client_token:%', 'a raw OAuth token is refused before any Data API request');
select pg_temp.assert(public.is_oauth_client_token(), 'and is recognised as a connected app''s token');

select pg_temp.become('admin');
select public.postgrest_pre_request();
select pg_temp.assert(not public.is_oauth_client_token(), 'a portal session passes');

select pg_temp.become_mcp('admin', (select id from t_out where label = 'conn_admin'), pg_temp.r('s_admin'));
select public.postgrest_pre_request();
select pg_temp.assert(not public.is_oauth_client_token(), 'the JWT the Edge Function mints passes');

select pg_temp.become_service();
select public.postgrest_pre_request();
select pg_temp.claims(jsonb_build_object('role', 'anon'), 'anon');
select public.postgrest_pre_request();
select pg_temp.super();
select set_config('request.jwt.claims', '', true);
select public.postgrest_pre_request();
select pg_temp.claims(jsonb_build_object('sub', pg_temp.u('rep'), 'role', 'authenticated', 'client_id', ''),
                      'authenticated');
select public.postgrest_pre_request();
select pg_temp.assert(true, 'service_role, anon, no claims at all and an empty client_id pass');

--------------------------------------------------------------------------
-- 8. No table takes a write under the raw token, by any path
--------------------------------------------------------------------------
-- Through a SECURITY DEFINER function: minting a crp_ token.
select pg_temp.become_raw('admin', 's_admin');
select pg_temp.assert_fails($$select * from public.mcp_token_create('minted by a raw token')$$,
  'oauth_client_read_only:%', 'a raw OAuth token cannot mint an MCP token');
-- Directly, where RLS alone would say yes: an admin changing who may draft.
select pg_temp.assert_fails(
  $$insert into public.mcp_order_users (user_id, note) values (pg_temp.u('other'), 'raw')$$,
  'oauth_client_read_only:%', 'nor change who may draft orders');
select pg_temp.assert_fails(
  $$delete from public.mcp_order_users where user_id = pg_temp.u('rep')$$,
  'oauth_client_read_only:%', 'nor remove someone');
-- Reads are not this layer's business (the pre-request function refuses
-- them over the API); under SQL the token still reads as its user.
select pg_temp.assert(
  (select count(*) >= 2 from public.mcp_order_users),
  'RLS is unchanged for it: the write block is the trigger, not a policy');

-- The same statements as the same admin, signed in to the portal.
select pg_temp.become('admin');
select pg_temp.assert(
  pg_temp.rows($$insert into public.mcp_order_users (user_id, note) values (pg_temp.u('other'), 'portal')$$) = 1,
  'a portal session still changes the list');
select pg_temp.assert(
  (select count(*) = 1 from public.mcp_token_create('minted in the portal')),
  'and still mints a token');

-- Every RLS table carries the trigger that now holds this check, the new
-- table included (both sweeps).
select pg_temp.super();
select pg_temp.assert(
  (select count(*) = 2 from pg_trigger g
   where g.tgrelid = 'public.mcp_oauth_connections'::regclass
     and g.tgname in ('trg_mcp_oauth_connections_no_write_while_viewing_as',
                      'trg_mcp_oauth_connections_read_only_role')),
  'mcp_oauth_connections carries the view-as and read-only-role triggers');

--------------------------------------------------------------------------
-- 9. Storage shows the raw token nothing
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) = 1 from pg_policies
   where schemaname = 'storage' and tablename = 'objects'
     and policyname = 'no connected app tokens'
     and permissive = 'RESTRICTIVE' and cmd = 'ALL'
     and roles = '{authenticated}'),
  'storage.objects carries the restrictive policy');

-- A bucket anyone signed in may use, so the restrictive policy is the only
-- thing between the raw token and the object. Rolled back with the rest.
create policy "t oauth open bucket" on storage.objects
  for all to authenticated
  using (bucket_id = 't-oauth') with check (bucket_id = 't-oauth');

select pg_temp.become('rep');
select pg_temp.assert(
  pg_temp.rows($$insert into storage.objects (bucket_id, name) values ('t-oauth', 'from-portal.txt')$$) = 1,
  'a portal session uploads to it');
select pg_temp.assert(
  (select count(*) = 1 from storage.objects where bucket_id = 't-oauth'),
  'and sees the object');

select pg_temp.become_raw('other', 's_other');
select pg_temp.assert(
  (select count(*) = 0 from storage.objects where bucket_id = 't-oauth'),
  'a raw OAuth token sees no object');
select pg_temp.assert_fails(
  $$insert into storage.objects (bucket_id, name) values ('t-oauth', 'from-raw.txt')$$,
  '%row-level security%', 'and cannot upload one');
select pg_temp.assert(
  pg_temp.rows($$delete from storage.objects where bucket_id = 't-oauth'$$) = 0,
  'or delete one');

select pg_temp.become_mcp('other', (select id from t_out where label = 'conn_other'), pg_temp.r('s_other'));
select pg_temp.assert(
  (select count(*) = 1 from storage.objects where bucket_id = 't-oauth'),
  'the JWT the Edge Function mints is not affected');

select pg_temp.super();

do $$ begin raise notice 'ALL MCP OAUTH TESTS PASSED'; end $$;

rollback;
