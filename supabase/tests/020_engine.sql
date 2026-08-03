/*============================================================================
  020_engine.sql — assertions for the score-driven recommendation engine.

  Transactional, rolls back, raises on failure. Dev only.

      psql "$DATABASE_URL" -f supabase/tests/020_engine.sql

  The headline assertion is #3: a resolved recommendation must not come back
  the same night. That is a behaviour change, and it is the one a rep notices
  first — on main, closing "No order in 140 days" buys them about eighteen
  hours.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures: one account that has clearly gone quiet, one steady annual
-- buyer that must NOT be flagged, and one rep to own them.
--------------------------------------------------------------------------
insert into erp.dim_customer (customer_key, customer_id, customer_name, active_flag,
                              internal_customer_flag, assigned_sales_rep_id, last_order_date)
values
  ('ZZE-QUIET',  'ZZE-QUIET',  'Gone Quiet',   'Y', 'N', 'ZZREP-E', null),
  ('ZZE-ANNUAL', 'ZZE-ANNUAL', 'Annual Buyer', 'Y', 'N', 'ZZREP-E', null);

insert into erp.dim_sales_rep (sales_rep_key, sales_rep_id, sales_rep_name, is_placeholder_rep)
values ('ZZREP-E', 'ZZREP-E', 'Rep E', false);

insert into erp.dim_part (part_key, part_id, product_family)
values ('ZZEP1','ZZEP1','Ridgeline'), ('ZZEP2','ZZEP2','Mesa'), ('ZZEP3','ZZEP3','Traverse');

-- QUIET: monthly buyer, silent for 8 months, revenue collapsed.
insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key, bookings, is_backlog_line)
select 'ZZEQ'||g, 1, 'ZZE-QUIET', to_char(current_date - (240 + g*30), 'YYYYMMDD')::int, 3000, false
from generate_series(0, 12) g;

insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, part_key, invoice_date_key, revenue, is_memo)
select 'ZZEIQ'||g, 1, 'E', 'ZZE-QUIET', (array['ZZEP1','ZZEP2','ZZEP3'])[1 + (g % 3)],
       to_char(current_date - (400 + g*20), 'YYYYMMDD')::int, 4000, false
from generate_series(0, 12) g;
insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, part_key, invoice_date_key, revenue, is_memo)
values ('ZZEIQX', 1, 'E', 'ZZE-QUIET', 'ZZEP1',
        to_char(current_date - 250, 'YYYYMMDD')::int, 6000, false);

-- ANNUAL: orders once a year, last one 200 days ago. Steady revenue.
-- Under the old flat "no order in 120 days" this account was flagged every
-- single year. It must not be now.
insert into erp.fact_order_line (order_id, line_num, customer_key, order_date_key, bookings, is_backlog_line)
values ('ZZEA1', 1, 'ZZE-ANNUAL', to_char(current_date - 200, 'YYYYMMDD')::int, 40000, false),
       ('ZZEA2', 1, 'ZZE-ANNUAL', to_char(current_date - 565, 'YYYYMMDD')::int, 40000, false),
       ('ZZEA3', 1, 'ZZE-ANNUAL', to_char(current_date - 930, 'YYYYMMDD')::int, 40000, false);

insert into erp.fact_invoice_line (invoice_id, invoice_line_no, invoice_entity_id,
                                   customer_key, part_key, invoice_date_key, revenue, is_memo)
select 'ZZEIA'||g, 1, 'E', 'ZZE-ANNUAL', 'ZZEP2',
       to_char(current_date - (200 + g*365), 'YYYYMMDD')::int, 40000, false
from generate_series(0, 1) g;

--------------------------------------------------------------------------
-- 1. The generator runs, reports a refresh step, and creates work.
--------------------------------------------------------------------------
create temporary table t_run1 (rule_key text, created int) on commit drop;
insert into t_run1 select * from public.generate_recommendations();

do $$
declare n int;
begin
  select created into n from t_run1 where rule_key = 'refresh_signals';
  if coalesce(n, 0) < 2 then
    raise exception 'step 0 FAILED: refresh_signals reported % accounts', n;
  end if;
  raise notice 'generator refreshes signals first ok (% accounts)', n;
end $$;

do $$
declare n int;
begin
  select count(*) into n from public.recommendations
   where customer_key = 'ZZE-QUIET' and status = 'open';
  if n = 0 then
    raise exception 'no_order_days FAILED: the quiet account was not flagged';
  end if;
  raise notice 'quiet account flagged ok (% rows)', n;
end $$;

--------------------------------------------------------------------------
-- 2. The annual buyer is NOT flagged.
--    200 days is well past the 120-day threshold, so 008 would have created
--    a recommendation here every year. The score gate is what stops it.
--------------------------------------------------------------------------
do $$
declare n int; s numeric;
begin
  select count(*) into n from public.recommendations where customer_key = 'ZZE-ANNUAL';
  select score into s from public.account_signals where customer_key = 'ZZE-ANNUAL';
  if n <> 0 then
    raise exception 'FAILED: annual buyer flagged % times (score %) — 200 days out '
                    'on a 365-day rhythm is not late', n, s;
  end if;
  raise notice 'annual buyer not flagged ok (score %)', s;
end $$;

--------------------------------------------------------------------------
-- 3. Idempotency — unchanged from 008, still guaranteed by uq_recs_open_rule.
--------------------------------------------------------------------------
do $$
declare total int;
begin
  select coalesce(sum(created), 0) into total
  from (select (public.generate_recommendations()).*) x(rule_key, created)
  where rule_key <> 'refresh_signals';
  if total <> 0 then
    raise exception 'idempotency FAILED: a second run created % rows', total;
  end if;
  raise notice 'second run creates nothing ok';
end $$;

--------------------------------------------------------------------------
-- 4. THE BUG FIX. A resolved recommendation stays resolved.
--
--    uq_recs_open_rule only ever prevented a duplicate OPEN row. Close one
--    and the very next nightly run recreates it, because the account is of
--    course still quiet. Before this migration, this assertion fails.
--------------------------------------------------------------------------
do $$
declare n int;
begin
  update public.recommendations
     set status = 'closed', outcome = 'seasonal'
   where customer_key = 'ZZE-QUIET' and rule_key = 'no_order_days' and status = 'open';

  perform public.generate_recommendations();

  select count(*) into n from public.recommendations
   where customer_key = 'ZZE-QUIET' and rule_key = 'no_order_days' and status = 'open';
  if n <> 0 then
    raise exception 'cooldown FAILED: a closed recommendation re-fired the same night';
  end if;
  raise notice 'resolved work stays resolved ok';
end $$;

--------------------------------------------------------------------------
-- 5. ...and comes back once the cooldown has expired.
--    A cooldown that never lifts is just a delete.
--------------------------------------------------------------------------
do $$
declare n int;
begin
  update public.recommendations
     set closed_at = now() - interval '45 days'
   where customer_key = 'ZZE-QUIET' and rule_key = 'no_order_days' and status = 'closed';

  perform public.generate_recommendations();

  select count(*) into n from public.recommendations
   where customer_key = 'ZZE-QUIET' and rule_key = 'no_order_days' and status = 'open';
  if n <> 1 then
    raise exception 'cooldown FAILED: after 45 days the rule did not re-fire (got %)', n;
  end if;
  raise notice 'cooldown expires ok';
end $$;

--------------------------------------------------------------------------
-- 6. A false positive buys a longer silence than an ordinary close.
--    A rep who takes the trouble to report noise should not be asked again
--    in a month.
--------------------------------------------------------------------------
do $$
declare n int;
begin
  update public.recommendations
     set status = 'dismissed', outcome = 'false_positive',
         closed_at = now() - interval '45 days'
   where customer_key = 'ZZE-QUIET' and rule_key = 'no_order_days' and status = 'open';

  perform public.generate_recommendations();

  select count(*) into n from public.recommendations
   where customer_key = 'ZZE-QUIET' and rule_key = 'no_order_days' and status = 'open';
  if n <> 0 then
    raise exception 'false-positive cooldown FAILED: re-fired after 45 of 90 days';
  end if;
  raise notice 'false positive holds longer ok';
end $$;

--------------------------------------------------------------------------
-- 7. The row carries its score and an explanation.
--    A reordered list nobody can account for is a list reps stop trusting.
--------------------------------------------------------------------------
do $$
declare r record;
begin
  -- Read whatever row is there. score/reason/score_factors are stamped at
  -- INSERT and never rewritten, so status is irrelevant — and reopening a
  -- row here would collide with uq_recs_open_rule against the one test 5
  -- left open.
  select score, reason, score_factors into r
  from public.recommendations
  where customer_key = 'ZZE-QUIET' and rule_key = 'no_order_days'
  order by id limit 1;

  if r.score is null then
    raise exception 'FAILED: recommendation carries no score';
  end if;
  if r.score_factors is null or r.score_factors = '{}'::jsonb then
    raise exception 'FAILED: recommendation carries no factor breakdown';
  end if;
  if r.reason not like '%days%' then
    raise exception 'FAILED: reason has no why-now clause: %', r.reason;
  end if;
  raise notice 'row explains itself ok (score %, "%")', r.score, left(r.reason, 70);
end $$;

--------------------------------------------------------------------------
-- 8. preview_recommendation_counts is admin-only and writes nothing.
--------------------------------------------------------------------------
create temporary table t_user2 (label text primary key, id uuid) on commit drop;
insert into t_user2 values ('admin', 'dddddddd-dddd-4ddd-8ddd-dddddddddddd');
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin)
select '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
       u.label || '@engine.test', '', now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user2 u;
update public.profiles set role = 'admin'
 where user_id = (select id from t_user2 where label = 'admin');

do $$
declare before_n int; after_n int; rows_out int;
begin
  select count(*) into before_n from public.recommendations;

  perform set_config('request.jwt.claims',
    json_build_object('sub', (select id from t_user2 where label='admin'),
                      'role', 'authenticated')::text, true);
  set local role authenticated;
  select count(*) into rows_out from public.preview_recommendation_counts(
    null, null, null, null,
    '{"cadence_overdue": {"enabled": true}}'::jsonb);
  reset role;

  select count(*) into after_n from public.recommendations;
  if before_n <> after_n then
    raise exception 'preview FAILED: it created % rows', after_n - before_n;
  end if;
  if rows_out = 0 then
    raise exception 'preview FAILED: returned no rule rows';
  end if;
  raise notice 'preview counts without writing ok (% rules)', rows_out;
end $$;

\echo ''
\echo 'ALL ENGINE TESTS PASSED'

rollback;
