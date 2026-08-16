/*============================================================================
  034_mcp_access.sql — assertions for the MCP token layer
  (migration 20260816120000_mcp_access.sql).

  Same harness rules as 010_access_rules.sql and 024_intel_views.sql: runs in
  a transaction and ROLLS BACK, creates throwaway auth users, run against dev
  — never prod.

      psql "$DATABASE_URL" -f supabase/tests/034_mcp_access.sql

  A clean run prints "ALL MCP TESTS PASSED"; any error is a failure.

  What is being proved
  --------------------
  The Edge Function's whole security argument is "a token is an identity, not
  a grant". Two halves have to hold for that:

    1. The token layer itself cannot be abused — no reading someone else's
       token, no minting for someone else, no recovering a hash over the API,
       no using a revoked/expired/deactivated credential (T1–T10).
    2. Presenting the identity gives EXACTLY the rep's normal RLS and nothing
       more (T11–T12). The function mints a JWT with `sub` = user_id and
       `role` = authenticated, which is precisely what pg_temp.as_user()
       simulates here — so these two tests are the real thing, not an
       approximation of it.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures — same pinned book as 010/024.
--------------------------------------------------------------------------
create temporary table t_fix (name text primary key, val text) on commit drop;
insert into t_fix (name, val) values
  ('rep_key', 'TANY MCDO');

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'aaaaaaaa-4444-4444-8444-444444444444'),
  ('other', 'bbbbbbbb-5555-4555-8555-555555555555'),
  ('admin', 'cccccccc-6666-4666-8666-666666666666');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@mcp.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles p set sales_rep_key = (select val from t_fix where name='rep_key')
  where p.user_id = (select id from t_user where label='rep');
update public.profiles p set role = 'admin'
  where p.user_id = (select id from t_user where label='admin');

-- An account outside the rep's book, for the cross-tenant probe.
create temporary table t_keys (label text primary key, customer_key text) on commit drop;
insert into t_keys
select 'foreign', customer_key from erp.dim_customer
 where assigned_sales_rep_id is not null
   and assigned_sales_rep_id <> (select val from t_fix where name='rep_key')
 order by customer_key limit 1;

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.as_user(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text,
                     true);
  execute 'set local role authenticated';
end;
$$;

create or replace function pg_temp.as_super() returns void
language plpgsql as $$
begin
  execute 'reset role';
end;
$$;

--------------------------------------------------------------------------
-- The assertions
--------------------------------------------------------------------------
do $$
declare
  u_rep     uuid := (select id from t_user where label='rep');
  u_other   uuid := (select id from t_user where label='other');
  u_admin   uuid := (select id from t_user where label='admin');
  k_foreign text := (select customer_key from t_keys where label='foreign');
  n     int;
  ok    boolean;
  -- The rep's first token, kept for the whole block. Deliberately plain
  -- variables and not a temp table: everything after T1 runs as
  -- `authenticated`, which cannot write to one.
  v_rep_id  uuid;
  v_rep_tok text;
  -- Scratch, for the throwaway tokens minted mid-block.
  v_tok text;
  v_id  uuid;
begin
  ----------------------------------------------------------------
  -- T1: a rep mints their own token and gets the plaintext once.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_rep);

  select c.token_id, c.token into v_rep_id, v_rep_tok
  from public.mcp_token_create('test rep token') c;

  if v_rep_tok is null or v_rep_tok !~ '^crp_[0-9a-f]{64}$' then
    raise exception 'T1 FAILED: token has the wrong shape: %', v_rep_tok;
  end if;
  raise notice 'T1 ok (rep minted a token)';

  ----------------------------------------------------------------
  -- T2: the plaintext is NOT stored — only its sha256.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  select count(*) into n from public.mcp_tokens t
   where t.id = v_rep_id
     and t.token_hash = encode(sha256(convert_to(v_rep_tok, 'UTF8')), 'hex');
  if n <> 1 then
    raise exception 'T2 FAILED: stored hash does not match sha256(token)';
  end if;
  select count(*) into n from public.mcp_tokens t
   where t.id = v_rep_id and (t.token_prefix = v_rep_tok or t.token_hash = v_rep_tok);
  if n <> 0 then
    raise exception 'T2 FAILED: the plaintext token was stored somewhere';
  end if;
  raise notice 'T2 ok (only the hash is at rest)';

  ----------------------------------------------------------------
  -- T3: token_hash is not selectable by `authenticated` at all. The
  -- column grant is the guard, so this fails even though the RLS policy
  -- lets the rep read their own ROW.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_rep);
  begin
    perform t.token_hash from public.mcp_tokens t where t.id = v_rep_id;
    raise exception 'T3 FAILED: a rep read token_hash';
  exception
    when insufficient_privilege then
      raise notice 'T3 ok (token_hash is not granted to authenticated)';
  end;

  -- …while the metadata columns the UI needs still work.
  select count(*) into n from public.mcp_tokens t where t.id = v_rep_id;
  if n <> 1 then
    raise exception 'T3 FAILED: the rep cannot read their own token row';
  end if;

  ----------------------------------------------------------------
  -- T4: another rep sees nothing of it.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  perform pg_temp.as_user(u_other);
  select count(*) into n from public.mcp_tokens t where t.user_id = u_rep;
  if n <> 0 then
    raise exception 'T4 FAILED: a user can see another user''s tokens';
  end if;
  raise notice 'T4 ok (tokens are private to their owner)';

  ----------------------------------------------------------------
  -- T5: a non-admin cannot mint FOR someone else. This is the one that
  -- matters — minting for another user is minting their access.
  ----------------------------------------------------------------
  begin
    perform public.mcp_token_create('stolen', u_rep);
    raise exception 'T5 FAILED: a rep minted a token for another user';
  exception
    when insufficient_privilege then
      raise notice 'T5 ok (cross-user mint rejected)';
  end;

  ----------------------------------------------------------------
  -- T6: a non-admin cannot revoke someone else's token.
  ----------------------------------------------------------------
  begin
    perform public.mcp_token_revoke(v_rep_id);
    raise exception 'T6 FAILED: a rep revoked another user''s token';
  exception
    when insufficient_privilege then
      raise notice 'T6 ok (cross-user revoke rejected)';
  end;

  ----------------------------------------------------------------
  -- T7: mcp_token_resolve is unreachable from a signed-in user. It takes
  -- a plaintext token and answers "whose is this" — service_role only.
  ----------------------------------------------------------------
  begin
    perform public.mcp_token_resolve(v_rep_tok);
    raise exception 'T7 FAILED: an authenticated user called mcp_token_resolve';
  exception
    when insufficient_privilege then
      raise notice 'T7 ok (resolve is service_role only)';
  end;

  ----------------------------------------------------------------
  -- T8: the table is writable only through the functions.
  ----------------------------------------------------------------
  begin
    insert into public.mcp_tokens (user_id, name, token_prefix, token_hash, expires_at)
    values (u_other, 'forged', 'crp_dead', 'deadbeef', now() + interval '1 day');
    raise exception 'T8 FAILED: a rep inserted a token row directly';
  exception
    when insufficient_privilege then
      raise notice 'T8 ok (direct insert rejected)';
  end;

  begin
    update public.mcp_tokens set revoked_at = null where id = v_rep_id;
    raise exception 'T8 FAILED: a rep updated a token row directly';
  exception
    when insufficient_privilege then
      raise notice 'T8 ok (direct update rejected)';
  end;

  ----------------------------------------------------------------
  -- T9: resolve accepts a live token and returns the right identity —
  -- and nothing about accounts.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  select count(*) into n
  from public.mcp_token_resolve(v_rep_tok) r
  where r.user_id = u_rep and r.sales_rep_key = (select val from t_fix where name='rep_key');
  if n <> 1 then
    raise exception 'T9 FAILED: resolve did not return the owning rep';
  end if;
  raise notice 'T9 ok (resolve identifies the owner)';

  ----------------------------------------------------------------
  -- T10: revoked, expired, and deactivated-profile tokens all resolve to
  -- nothing. The third is the one a browser JWT would NOT give us for
  -- free, because an MCP credential outlives an access token by months.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_rep);
  ok := public.mcp_token_revoke(v_rep_id);
  if not ok then
    raise exception 'T10 FAILED: revoking a live token returned false';
  end if;
  if public.mcp_token_revoke(v_rep_id) then
    raise exception 'T10 FAILED: revoke is not idempotent';
  end if;

  perform pg_temp.as_super();
  select count(*) into n from public.mcp_token_resolve(v_rep_tok) r;
  if n <> 0 then
    raise exception 'T10 FAILED: a revoked token still resolves';
  end if;

  -- Expired.
  perform pg_temp.as_user(u_rep);
  select c.token_id, c.token into v_id, v_tok from public.mcp_token_create('expiring') c;
  perform pg_temp.as_super();
  update public.mcp_tokens set expires_at = now() - interval '1 minute' where id = v_id;
  select count(*) into n from public.mcp_token_resolve(v_tok) r;
  if n <> 0 then
    raise exception 'T10 FAILED: an expired token still resolves';
  end if;

  -- Deactivated profile.
  perform pg_temp.as_user(u_rep);
  select c.token_id, c.token into v_id, v_tok from public.mcp_token_create('deactivating') c;
  perform pg_temp.as_super();
  update public.profiles set active = false where user_id = u_rep;
  select count(*) into n from public.mcp_token_resolve(v_tok) r;
  if n <> 0 then
    raise exception 'T10 FAILED: a deactivated user''s token still resolves';
  end if;
  update public.profiles set active = true where user_id = u_rep;
  raise notice 'T10 ok (revoked / expired / deactivated all refused)';

  ----------------------------------------------------------------
  -- T11: presenting the identity is NOT a widening. The Edge Function
  -- mints exactly the claims as_user() sets, so this is the access an MCP
  -- client actually gets.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_rep);

  select count(*) into n from public.v_account_list where customer_key = k_foreign;
  if n <> 0 then
    raise exception 'T11 FAILED: the MCP identity reached a foreign account';
  end if;

  if exists (
    select 1 from public.v_territory_account_yoy t
    where t.customer_key not in (select public.my_customer_keys())
    limit 1
  ) then
    raise exception 'T11 FAILED: the MCP identity saw outside my_customer_keys()';
  end if;
  raise notice 'T11 ok (MCP identity ⊆ the rep''s own book)';

  ----------------------------------------------------------------
  -- T12: every relation the tools read is reachable under that identity.
  -- A tool pointed at a relation the rep cannot select is a 403 the model
  -- reports as "no data", which is the worst possible failure here.
  ----------------------------------------------------------------
  perform count(*) from public.v_account_list;
  perform count(*) from public.v_account_summary;
  perform count(*) from public.v_account_goal_progress;
  perform count(*) from public.v_my_goal_rollup;
  perform count(*) from public.v_territory_account_yoy;
  perform count(*) from public.v_territory_sku_sales;
  perform count(*) from public.v_sku_sales_by_account;
  perform count(*) from public.v_backlog_by_sku;
  perform count(*) from public.v_ats_list;
  perform count(*) from public.v_account_recent_order_headers;
  perform count(*) from public.v_account_order_lines;
  perform count(*) from public.v_account_recent_shipment_headers;
  perform count(*) from public.v_account_shipment_lines;
  perform count(*) from public.v_account_contacts;
  perform count(*) from public.v_data_freshness;
  perform count(*) from public.account_signals;
  perform count(*) from public.recommendations;
  perform count(*) from public.notes;
  perform count(*) from public.actions;
  perform count(*) from public.visits;
  perform count(*) from public.report_global_product_sales(12, 10);
  raise notice 'T12 ok (every relation the MCP tools read is selectable)';

  ----------------------------------------------------------------
  -- T13: an admin may mint for another user, and sees every token.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  perform pg_temp.as_user(u_admin);

  select c.token_id, c.token into v_id, v_tok
  from public.mcp_token_create('minted by admin', u_other) c;
  if v_tok is null then
    raise exception 'T13 FAILED: admin could not mint for another user';
  end if;

  select count(*) into n from public.mcp_tokens t where t.user_id = u_other;
  if n < 1 then
    raise exception 'T13 FAILED: admin cannot see another user''s tokens';
  end if;

  if not public.mcp_token_revoke(v_id) then
    raise exception 'T13 FAILED: admin could not revoke another user''s token';
  end if;
  raise notice 'T13 ok (admin can mint for, see and revoke others)';

  ----------------------------------------------------------------
  -- T14: the five-live-token cap holds.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  perform pg_temp.as_user(u_other);
  for n in 1..5 loop
    perform public.mcp_token_create('cap test ' || n);
  end loop;

  -- The cap raises a plain P0001, which is also what `raise exception` here
  -- would raise — so the outcome is recorded in a flag and asserted OUTSIDE
  -- the block, rather than by a handler that would happily swallow its own
  -- failure message and print "ok".
  ok := false;
  begin
    perform public.mcp_token_create('one too many');
  exception
    when raise_exception then
      ok := true;
  end;
  if not ok then
    raise exception 'T14 FAILED: a sixth live token was minted';
  end if;
  raise notice 'T14 ok (five live tokens is the cap)';

  perform pg_temp.as_super();
  raise notice '--- ALL MCP TESTS PASSED ---';
end;
$$;

rollback;
