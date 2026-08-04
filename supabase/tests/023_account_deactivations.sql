/*============================================================================
  023_account_deactivations.sql — assertions for the rep deactivation flow.

  Same harness as 010/019: runs entirely inside a transaction and ROLLS BACK,
  creates throwaway auth users, and raises on every failure so a clean run
  printing "ALL DEACTIVATION TESTS PASSED" is the pass condition.

      psql "$DATABASE_URL" -f supabase/tests/023_account_deactivations.sql

  Run it against dev. Never prod.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures. Suffixed so they cannot collide with a real ERP load. DEAD is
-- rep A's account to write off; LIVE stays active for contrast; OTHER
-- belongs to rep B and exists to prove the fence.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name, active_flag,
                              internal_customer_flag, assigned_sales_rep_id)
values
  ('ZZDX-DEAD',  'ZZDX-DEAD',  'Closed Store',   'Y', 'N', 'ZZDXREP-A'),
  ('ZZDX-LIVE',  'ZZDX-LIVE',  'Open Store',     'Y', 'N', 'ZZDXREP-A'),
  ('ZZDX-OTHER', 'ZZDX-OTHER', 'Other Rep Book', 'Y', 'N', 'ZZDXREP-B');

insert into erp.dim_sales_rep (sales_rep_key, sales_rep_id, sales_rep_name, is_placeholder_rep)
values ('ZZDXREP-A', 'ZZDXREP-A', 'Rep A', false),
       ('ZZDXREP-B', 'ZZDXREP-B', 'Rep B', false);

-- Enough recent history that both of rep A's accounts are scorable.
insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, invoice_date_key, revenue, is_memo)
values ('ZZDXI1', 1, 'E', 'ZZDX-DEAD', to_char(current_date - 30, 'YYYYMMDD')::int, 5000, false),
       ('ZZDXI2', 1, 'E', 'ZZDX-LIVE', to_char(current_date - 30, 'YYYYMMDD')::int, 5000, false);

--------------------------------------------------------------------------
-- Throwaway users. The handle_new_user trigger creates each profile.
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('repa',  '11111111-1111-4111-8111-111111111111'),
  ('repb',  '22222222-2222-4222-8222-222222222222'),
  ('admin', '33333333-3333-4333-8333-333333333333');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@deactivation.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles p set sales_rep_key = 'ZZDXREP-A'
  where p.user_id = (select id from t_user where label='repa');
update public.profiles p set sales_rep_key = 'ZZDXREP-B'
  where p.user_id = (select id from t_user where label='repb');
update public.profiles p set role = 'admin'
  where p.user_id = (select id from t_user where label='admin');

-- Open work on the account about to be written off: one system rec (with a
-- rule stamp) and one mission-style rec that REQUIRES a visit — the trigger
-- must clear both, visit guard notwithstanding.
insert into public.rule_settings (rule_key, description, params)
values ('zzdx_rule', 'test rule', '{}') on conflict (rule_key) do nothing;
insert into public.recommendations (customer_key, source, rule_key, title, status)
values ('ZZDX-DEAD', 'system', 'zzdx_rule', 'call them', 'open');
insert into public.recommendations (customer_key, source, title, status, requires_visit)
values ('ZZDX-DEAD', 'admin', 'visit them', 'open', true);

select public.refresh_account_signals();

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.as_user(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end; $$;

--------------------------------------------------------------------------
-- 1. Rep A deactivates their own account, as themselves, through RLS.
--------------------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  insert into public.account_deactivations (customer_key, reason, note)
  values ('ZZDX-DEAD', 'store_closed', 'Front door chained shut in March');
  select count(*) into n from public.account_deactivations
   where customer_key = 'ZZDX-DEAD' and reactivated_at is null;
  reset role;
  if n <> 1 then
    raise exception 'deactivate FAILED: rep A wrote % open rows, expected 1', n;
  end if;
  raise notice 'rep can deactivate their own account ok';
end $$;

--------------------------------------------------------------------------
-- 2. The trigger cleared the open work immediately — both recommendations
--    dismissed with the account_deactivated outcome (the requires_visit one
--    included: dismissal is the escape hatch 016 left open on purpose), and
--    the signals row is gone without waiting for the nightly refresh.
--------------------------------------------------------------------------
do $$
declare n_open int; n_dismissed int; n_signals int;
begin
  select count(*) filter (where status in ('open','acted')),
         count(*) filter (where status = 'dismissed' and outcome = 'account_deactivated'
                          and closed_by is not null and closed_at is not null)
    into n_open, n_dismissed
  from public.recommendations where customer_key = 'ZZDX-DEAD';
  if n_open <> 0 or n_dismissed <> 2 then
    raise exception 'trigger FAILED: % still open, % dismissed as account_deactivated (expected 0 / 2)',
                    n_open, n_dismissed;
  end if;
  select count(*) into n_signals from public.account_signals where customer_key = 'ZZDX-DEAD';
  if n_signals <> 0 then
    raise exception 'trigger FAILED: account_signals row survived deactivation';
  end if;
  raise notice 'trigger dismisses open work and de-scores immediately ok';
end $$;

--------------------------------------------------------------------------
-- 3. Only one open period per account: a second deactivate is a 23505,
--    which is exactly what the client translates for the rep.
--------------------------------------------------------------------------
do $$
declare duplicated boolean := false;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  begin
    insert into public.account_deactivations (customer_key, reason)
    values ('ZZDX-DEAD', 'other');
    duplicated := true;
  exception when unique_violation then
    null;   -- expected
  end;
  reset role;
  if duplicated then
    raise exception 'uniqueness FAILED: two open deactivations on one account';
  end if;
  raise notice 'one open period per account ok';
end $$;

--------------------------------------------------------------------------
-- 4. The fence. Rep B can neither see nor write a deactivation for rep A's
--    accounts. The write attempt targets ZZDX-LIVE — an account with NO
--    existing deactivation — so the only thing that can reject it is the
--    RLS with check (42501), not a unique violation masking a broken policy.
--------------------------------------------------------------------------
do $$
declare n int; allowed boolean := false;
begin
  perform pg_temp.as_user((select id from t_user where label='repb'));
  set local role authenticated;
  select count(*) into n from public.account_deactivations where customer_key = 'ZZDX-DEAD';
  begin
    insert into public.account_deactivations (customer_key, reason)
    values ('ZZDX-LIVE', 'other');
    allowed := true;
  exception when insufficient_privilege then
    null;   -- expected: new row violates RLS
  end;
  reset role;
  if n <> 0 then
    raise exception 'RLS FAILED: rep B read % of rep A''s deactivations', n;
  end if;
  if allowed then
    raise exception 'RLS FAILED: rep B deactivated an account outside their book';
  end if;
  raise notice 'RLS: rep B fenced out of rep A''s deactivations ok';
end $$;

--------------------------------------------------------------------------
-- 5. A rep cannot spoof authorship: deactivated_by must be auth.uid().
--------------------------------------------------------------------------
do $$
declare spoofed boolean := false;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  begin
    insert into public.account_deactivations (customer_key, reason, deactivated_by)
    values ('ZZDX-LIVE', 'other', (select id from t_user where label='repb'));
    spoofed := true;
  exception when others then
    null;   -- expected: with check deactivated_by = auth.uid()
  end;
  reset role;
  if spoofed then
    raise exception 'RLS FAILED: rep A stamped rep B as the deactivator';
  end if;
  raise notice 'authorship cannot be spoofed ok';
end $$;

--------------------------------------------------------------------------
-- 6. Exclusions, all four surfaces, checked while the account is out:
--    signals refresh, v_account_list flag, coverage, mission scope.
--------------------------------------------------------------------------
select public.refresh_account_signals();

do $$
declare n int;
begin
  select count(*) into n from public.account_signals where customer_key = 'ZZDX-DEAD';
  if n <> 0 then
    raise exception 'refresh FAILED: deactivated account was re-scored';
  end if;
  select count(*) into n from public.account_signals where customer_key = 'ZZDX-LIVE';
  if n <> 1 then
    raise exception 'refresh FAILED: the live account fell out too';
  end if;
  raise notice 'refresh_account_signals skips deactivated accounts ok';
end $$;

do $$
declare v_deact timestamptz; v_reason text;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  select deactivated_at, deactivation_reason into v_deact, v_reason
    from public.v_account_list where customer_key = 'ZZDX-DEAD';
  reset role;
  if v_deact is null or v_reason <> 'store_closed' then
    raise exception 'v_account_list FAILED: deactivation not surfaced (%, %)', v_deact, v_reason;
  end if;
  raise notice 'v_account_list carries the open deactivation ok';
end $$;

do $$
declare n int;
begin
  perform pg_temp.as_user((select id from t_user where label='admin'));
  set local role authenticated;
  select count(*) into n from public.account_coverage where customer_key = 'ZZDX-DEAD';
  reset role;
  if n <> 0 then
    raise exception 'coverage FAILED: deactivated account still in the denominator';
  end if;
  raise notice 'account_coverage excludes deactivated accounts ok';
end $$;

do $$
declare n int;
begin
  perform pg_temp.as_user((select id from t_user where label='admin'));
  set local role authenticated;
  -- Dry run over rep A's book, active only: LIVE counts, DEAD does not.
  select created_count into n
    from public.create_mission('zz test', null, 'normal', null, false,
                               'rep', 'ZZDXREP-A', null, true, true);
  if n <> 1 then
    raise exception 'mission scope FAILED: active-only counted % of rep A''s accounts, expected 1', n;
  end if;
  -- Explicitly asking for inactive accounts brings it back.
  select created_count into n
    from public.create_mission('zz test', null, 'normal', null, false,
                               'rep', 'ZZDXREP-A', null, false, true);
  reset role;
  if n <> 2 then
    raise exception 'mission scope FAILED: include-inactive counted %, expected 2', n;
  end if;
  raise notice 'create_mission active-only skips deactivated accounts ok';
end $$;

--------------------------------------------------------------------------
-- 7. The column-grant lockdown: a rep's UPDATE may touch nothing but the
--    reactivation stamp. Rewriting the reason is a permission error.
--------------------------------------------------------------------------
do $$
declare rewritten boolean := false;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  begin
    update public.account_deactivations set reason = 'other'
     where customer_key = 'ZZDX-DEAD' and reactivated_at is null;
    rewritten := true;
  exception when insufficient_privilege then
    null;   -- expected: no UPDATE grant on `reason`
  end;
  reset role;
  if rewritten then
    raise exception 'GRANT FAILED: a rep rewrote a deactivation reason';
  end if;
  raise notice 'update is confined to the reactivation stamp ok';
end $$;

--------------------------------------------------------------------------
-- 8. Reactivation: rep A ends the period; history stays; the next refresh
--    brings the account back into scoring.
--------------------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  update public.account_deactivations
     set reactivated_at = now(),
         reactivated_by = auth.uid()
   where customer_key = 'ZZDX-DEAD' and reactivated_at is null;
  select count(*) into n from public.account_deactivations
   where customer_key = 'ZZDX-DEAD';   -- the closed period is still readable
  reset role;
  if n <> 1 then
    raise exception 'reactivate FAILED: history row missing after reactivation';
  end if;
  raise notice 'rep can reactivate, history kept ok';
end $$;

select public.refresh_account_signals();

do $$
declare n int;
begin
  select count(*) into n from public.account_signals where customer_key = 'ZZDX-DEAD';
  if n <> 1 then
    raise exception 'reactivate FAILED: account did not re-enter scoring on refresh';
  end if;
  raise notice 'reactivated account re-enters scoring ok';
end $$;

\echo ''
\echo 'ALL DEACTIVATION TESTS PASSED'

rollback;
