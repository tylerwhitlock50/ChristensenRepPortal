/*============================================================================
  019_scoring.sql — assertions for the account priority score.

  Same harness as 010_access_rules.sql: runs entirely inside a transaction and
  ROLLS BACK, creates throwaway auth users, and raises on every failure so a
  clean run printing "ALL SCORING TESTS PASSED" is the pass condition.

      psql "$DATABASE_URL" -f supabase/tests/019_scoring.sql

  Run it against dev. Never prod.

  Unlike 010, this file builds its OWN erp fixtures rather than pinning to real
  values — the arithmetic assertions below need known inputs, and the dealers
  invented here (a weekly buyer, an annual buyer, a monthly buyer gone quiet)
  are the three cases the cadence factor exists to tell apart.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures. Suffixed so they cannot collide with a real ERP load.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name, active_flag,
                              internal_customer_flag, assigned_sales_rep_id, last_order_date)
values
  ('ZZTEST-WEEKLY', 'ZZTEST-WEEKLY', 'Weekly Buyer',  'Y', 'N', 'ZZREP-A', null),
  ('ZZTEST-ANNUAL', 'ZZTEST-ANNUAL', 'Annual Buyer',  'Y', 'N', 'ZZREP-A', null),
  ('ZZTEST-QUIET',  'ZZTEST-QUIET',  'Gone Quiet',    'Y', 'N', 'ZZREP-A', null),
  ('ZZTEST-OTHER',  'ZZTEST-OTHER',  'Other Rep Book','Y', 'N', 'ZZREP-B', null);

insert into erp.dim_sales_rep (sales_rep_key, sales_rep_id, sales_rep_name, is_placeholder_rep)
values ('ZZREP-A', 'ZZREP-A', 'Rep A', false),
       ('ZZREP-B', 'ZZREP-B', 'Rep B', false);

insert into erp.dim_part (part_key, part_id, product_family)
values ('ZZP1','ZZP1','Ridgeline'), ('ZZP2','ZZP2','Mesa'), ('ZZP3','ZZP3','Traverse');

-- WEEKLY: every 7 days, last one 10 days ago. Barely late for them.
insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key, bookings, is_backlog_line)
select 'ZZW'||g, 1, 'ZZTEST-WEEKLY', to_char(current_date - (10 + g*7), 'YYYYMMDD')::int, 500, false
from generate_series(0, 100) g;

-- ANNUAL: once a year. 200 days out is EARLY for them.
insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key, bookings, is_backlog_line)
values ('ZZA1', 1, 'ZZTEST-ANNUAL', to_char(current_date - 200, 'YYYYMMDD')::int, 40000, false),
       ('ZZA2', 1, 'ZZTEST-ANNUAL', to_char(current_date - 565, 'YYYYMMDD')::int, 38000, false),
       ('ZZA3', 1, 'ZZTEST-ANNUAL', to_char(current_date - 930, 'YYYYMMDD')::int, 36000, false);

-- QUIET: monthly, then nothing for 8 months.
insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key, bookings, is_backlog_line)
select 'ZZQ'||g, 1, 'ZZTEST-QUIET', to_char(current_date - (240 + g*30), 'YYYYMMDD')::int, 3000, false
from generate_series(0, 12) g;

insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, part_key, invoice_date_key, revenue, is_memo)
select 'ZZIW'||g, 1, 'E', 'ZZTEST-WEEKLY', 'ZZP1',
       to_char(current_date - (10 + g*7), 'YYYYMMDD')::int, 500, false
from generate_series(0, 100) g;

insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, part_key, invoice_date_key, revenue, is_memo)
select 'ZZIA'||g, 1, 'E', 'ZZTEST-ANNUAL', 'ZZP2',
       to_char(current_date - (200 + g*365), 'YYYYMMDD')::int, 40000, false
from generate_series(0, 1) g;

-- QUIET bought three families last year, one this year: mix erosion.
insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, part_key, invoice_date_key, revenue, is_memo)
select 'ZZIQ'||g, 1, 'E', 'ZZTEST-QUIET', (array['ZZP1','ZZP2','ZZP3'])[1 + (g % 3)],
       to_char(current_date - (400 + g*20), 'YYYYMMDD')::int, 2000, false
from generate_series(0, 12) g;
insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, part_key, invoice_date_key, revenue, is_memo)
values ('ZZIQX', 1, 'E', 'ZZTEST-QUIET', 'ZZP1',
        to_char(current_date - 250, 'YYYYMMDD')::int, 2000, false);

insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, part_key, invoice_date_key, revenue, is_memo)
values ('ZZIO', 1, 'E', 'ZZTEST-OTHER', 'ZZP1',
        to_char(current_date - 30, 'YYYYMMDD')::int, 9000, false);

--------------------------------------------------------------------------
-- Throwaway users. The handle_new_user trigger creates each profile.
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('repa',  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
  ('repb',  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
  ('admin', 'cccccccc-cccc-4ccc-8ccc-cccccccccccc');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@scoring.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles p set sales_rep_key = 'ZZREP-A'
  where p.user_id = (select id from t_user where label='repa');
update public.profiles p set sales_rep_key = 'ZZREP-B'
  where p.user_id = (select id from t_user where label='repb');
update public.profiles p set role = 'admin'
  where p.user_id = (select id from t_user where label='admin');

--------------------------------------------------------------------------
-- Compute
--------------------------------------------------------------------------
select public.refresh_account_signals();
select public.apply_account_scores();

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.assert_num(
  p_label text, p_actual numeric, p_expected numeric
) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception '% FAILED: expected %, got %', p_label, p_expected, p_actual;
  end if;
  raise notice '% ok (%)', p_label, p_actual;
end; $$;

create or replace function pg_temp.as_user(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end; $$;

--------------------------------------------------------------------------
-- 1. The refresh actually leaves rows behind.
--
--    Guarding a real bug: computed_at was originally stamped with now(), the
--    TRANSACTION timestamp, while the stale-row sweep compared against a
--    clock_timestamp() taken at function entry. now() is always earlier, so
--    the delete removed every row it had just written and the table came out
--    empty while the function cheerfully reported three upserts.
--------------------------------------------------------------------------
do $$
declare n int;
begin
  select count(*) into n from public.account_signals where customer_key like 'ZZTEST-%';
  if n <> 4 then
    raise exception 'refresh FAILED: expected 4 fixture rows, got %', n;
  end if;
  raise notice 'refresh leaves rows behind ok (%)', n;
end $$;

--------------------------------------------------------------------------
-- 2. Cadence is judged against the account's OWN rhythm.
--    This is the whole point of the factor and the thing 008's flat
--    "no order in N days" could not express.
--------------------------------------------------------------------------
do $$
declare weekly numeric; annual numeric; quiet numeric;
begin
  select score_cadence into weekly from public.account_signals where customer_key='ZZTEST-WEEKLY';
  select score_cadence into annual from public.account_signals where customer_key='ZZTEST-ANNUAL';
  select score_cadence into quiet  from public.account_signals where customer_key='ZZTEST-QUIET';

  -- 10 days into a 7-day rhythm, and 200 days into a 365-day one, are both
  -- inside the account's normal window.
  perform pg_temp.assert_num('cadence: weekly buyer 10 days out', weekly, 0.0);
  perform pg_temp.assert_num('cadence: annual buyer 200 days out', annual, 0.0);
  -- 240 days into a 30-day rhythm is eight cycles late.
  perform pg_temp.assert_num('cadence: monthly buyer 240 days out', quiet, 100.0);
end $$;

--------------------------------------------------------------------------
-- 3. The annual buyer must not outrank the account that actually went quiet.
--    Under the old rule both would simply have been "no order in >120 days".
--------------------------------------------------------------------------
do $$
declare annual numeric; quiet numeric; quiet_priority text;
begin
  select score into annual from public.account_signals where customer_key='ZZTEST-ANNUAL';
  select score, priority into quiet, quiet_priority
    from public.account_signals where customer_key='ZZTEST-QUIET';
  if quiet <= annual then
    raise exception 'ranking FAILED: quiet account (%) did not outrank annual buyer (%)',
                    quiet, annual;
  end if;
  if quiet_priority <> 'high' then
    raise exception 'ranking FAILED: quiet account banded %, expected high', quiet_priority;
  end if;
  raise notice 'ranking ok (quiet % > annual %)', quiet, annual;
end $$;

--------------------------------------------------------------------------
-- 4. Weights are RELATIVE — the composite renormalizes over whichever
--    factors produced a value, so scaling every weight changes nothing.
--    If this fails, an admin halving one weight silently rescales the book.
--------------------------------------------------------------------------
do $$
declare a numeric; b numeric;
begin
  select score into a from public.account_signals where customer_key='ZZTEST-QUIET';

  perform public.apply_account_scores(
    (true,
     '{"cadence": 3, "recency": 2, "trend": 2, "value": 2, "mix": 1}'::jsonb,
     (select params from public.score_settings where id),
     70, 35, now(), null)::public.score_settings);

  select score into b from public.account_signals where customer_key='ZZTEST-QUIET';
  if a is distinct from b then
    raise exception 'renormalization FAILED: 30/20/20/20/10 gave %, 3/2/2/2/1 gave %', a, b;
  end if;
  raise notice 'weights are relative ok (%)', a;

  perform public.apply_account_scores();   -- back to the stored settings
end $$;

--------------------------------------------------------------------------
-- 5. A NULL factor renormalizes away instead of scoring zero.
--    None of the fixtures has a logged action, so recency must be NULL and
--    must not be dragging every score down.
--------------------------------------------------------------------------
do $$
declare rec numeric; n int;
begin
  select score_recency into rec from public.account_signals where customer_key='ZZTEST-QUIET';
  if rec is not null then
    raise exception 'recency FAILED: expected NULL with no actions logged, got %', rec;
  end if;
  select count(*) into n from public.account_signals
   where customer_key like 'ZZTEST-%' and (factors ? 'recency');
  if n <> 0 then
    raise exception 'recency FAILED: % rows carry a recency factor with no actions', n;
  end if;
  raise notice 'null factor renormalizes away ok';
end $$;

--------------------------------------------------------------------------
-- 6. Suppression — the outcome loop reading back into the ranking.
--    An account that just ordered drops to 40% of its score.
--------------------------------------------------------------------------
do $$
declare before_score numeric; after_score numeric;
begin
  select score into before_score from public.account_signals where customer_key='ZZTEST-QUIET';

  insert into public.recommendations
    (customer_key, source, rule_key, title, status, outcome, closed_at)
  values ('ZZTEST-QUIET', 'system', 'no_order_days', 'test', 'closed',
          'order_received', now() - interval '1 day');

  perform public.refresh_account_signals();
  perform public.apply_account_scores();

  select score into after_score from public.account_signals where customer_key='ZZTEST-QUIET';

  -- Tolerance, not equality: score_account rounds ONCE, at the end, so it
  -- computes round(raw * 0.4, 1) while this test only has the already-rounded
  -- `before_score` to work from. Asserting exact equality here would be
  -- testing double rounding, and would fail on a correct implementation.
  if abs(after_score - before_score * 0.4) > 0.1 then
    raise exception 'suppression FAILED: % should be ~40%% of %',
                    after_score, before_score;
  end if;
  raise notice 'suppression after order_received ok (% -> %)', before_score, after_score;
end $$;

--------------------------------------------------------------------------
-- 7. RLS. The leak test — the single most important one here, because a new
--    table carrying every dealer's revenue is exactly where 011's header
--    warns a leak will appear.
--------------------------------------------------------------------------
do $$
declare n int;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;

  select count(*) into n from public.account_signals where customer_key = 'ZZTEST-OTHER';
  reset role;
  if n <> 0 then
    raise exception 'RLS FAILED: rep A read % rows of rep B''s account_signals', n;
  end if;
  raise notice 'RLS: rep A cannot see rep B''s signals ok';
end $$;

do $$
declare n int;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  select count(*) into n from public.account_signals where customer_key like 'ZZTEST-%';
  reset role;
  if n <> 3 then
    raise exception 'RLS FAILED: rep A saw % of their own 3 fixture accounts', n;
  end if;
  raise notice 'RLS: rep A sees their own book ok (%)', n;
end $$;

--------------------------------------------------------------------------
-- 8. preview_account_scores is admin-only and writes nothing.
--------------------------------------------------------------------------
do $$
declare failed boolean := false;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  begin
    perform public.preview_account_scores(null, null, null, null, 5);
    failed := true;
  exception when others then
    null;   -- expected: not_admin
  end;
  reset role;
  if failed then
    raise exception 'preview FAILED: a rep was allowed to run preview_account_scores';
  end if;
  raise notice 'preview is admin-only ok';
end $$;

do $$
declare n int; before_score numeric; after_score numeric;
begin
  select score into before_score from public.account_signals where customer_key='ZZTEST-QUIET';

  perform pg_temp.as_user((select id from t_user where label='admin'));
  set local role authenticated;
  select count(*) into n from public.preview_account_scores(
    '{"cadence": 100, "recency": 0, "trend": 0, "value": 0, "mix": 0}'::jsonb,
    null, null, null, 10);
  reset role;

  if n = 0 then
    raise exception 'preview FAILED: admin got no rows';
  end if;

  select score into after_score from public.account_signals where customer_key='ZZTEST-QUIET';
  if before_score is distinct from after_score then
    raise exception 'preview FAILED: it wrote to account_signals (% -> %)',
                    before_score, after_score;
  end if;
  raise notice 'preview returns rows and writes nothing ok (% rows)', n;
end $$;

--------------------------------------------------------------------------
-- 9. A rep cannot re-score the book.
--
--    Guarding a hole that existed for about ten minutes: apply_account_scores
--    takes a whole score_settings row and was granted to `authenticated` so
--    the admin screen could call it after saving. That is a write path over
--    every account in the ERP, reachable straight from PostgREST, with no
--    admin check in it — any rep could have re-ranked the entire book under
--    weights of their own choosing.
--
--    It is job-only now, and app users get admin_rescore_accounts(), which
--    takes no arguments and gates on is_admin().
--------------------------------------------------------------------------
do $$
declare allowed boolean := false;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  begin
    perform public.apply_account_scores(
      (true,
       '{"cadence": 100, "recency": 0, "trend": 0, "value": 0, "mix": 0}'::jsonb,
       (select params from public.score_settings where id),
       70, 35, now(), null)::public.score_settings);
    allowed := true;
  exception when others then
    null;   -- expected: permission denied
  end;
  reset role;
  if allowed then
    raise exception 'GRANT FAILED: a rep re-scored the whole book via apply_account_scores';
  end if;
  raise notice 'reps cannot call apply_account_scores ok';
end $$;

do $$
declare allowed boolean := false;
begin
  perform pg_temp.as_user((select id from t_user where label='repa'));
  set local role authenticated;
  begin
    perform public.admin_rescore_accounts();
    allowed := true;
  exception when others then
    null;   -- expected: not_admin
  end;
  reset role;
  if allowed then
    raise exception 'GRANT FAILED: a rep ran admin_rescore_accounts';
  end if;
  raise notice 'admin_rescore_accounts is admin-only ok';
end $$;

do $$
declare n int;
begin
  perform pg_temp.as_user((select id from t_user where label='admin'));
  set local role authenticated;
  n := public.admin_rescore_accounts();
  reset role;
  if n < 1 then
    raise exception 'FAILED: admin_rescore_accounts scored % accounts', n;
  end if;
  raise notice 'admin can re-score ok (% accounts)', n;
end $$;

\echo ''
\echo 'ALL SCORING TESTS PASSED'

rollback;
