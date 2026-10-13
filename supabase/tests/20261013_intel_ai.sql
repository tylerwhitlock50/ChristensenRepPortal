/*============================================================================
  20261013_intel_ai.sql — assertions for
    20261013140000_ai_batch_targets_signals.sql   ai_batch_targets() v2
    20261013140001_ai_brief_items_feedback.sql     ai_briefs.items, ai_feedback
    20261013140002_reorder_recency_family_mix.sql  report_account_family_mix()
                                                   (+ service_role parity for
                                                   report_reorder_candidates)

  Same harness rules as the other files here: runs in a transaction and ROLLS
  BACK, creates throwaway users and ERP rows, dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261013_intel_ai.sql

  A clean run prints "ALL INTEL AI TESTS PASSED".

  The parity tests matter more than they look: the nightly batch builds the
  AI account context as service_role and a rep builds it with their own JWT,
  and the cache is keyed on a hash of that context. Any read that answers
  differently for the two roles makes every rep open after a batch run look
  "changed" and pay for a regeneration.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a',    'aaaaaaaa-7171-4171-8171-717171717171'),
  ('rep_b',    'bbbbbbbb-7272-4272-8272-727272727272'),
  ('admin',    'cccccccc-7373-4373-8373-737373737373'),
  ('inactive', 'dddddddd-7474-4474-8474-747474747474');
grant select on t_user to authenticated, service_role;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@intelai.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'IA REPA'
  where user_id = (select id from t_user where label='rep_a');
update public.profiles set sales_rep_key = 'IA REPB'
  where user_id = (select id from t_user where label='rep_b');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label='admin');
update public.profiles set sales_rep_key = 'IA REPI', active = false
  where user_id = (select id from t_user where label='inactive');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag)
values ('IA-A1', 'IA-A1', 'Intel A One',   'IA REPA', 'Y'),
       ('IA-A2', 'IA-A2', 'Intel A Two',   'IA REPA', 'Y'),
       ('IA-A3', 'IA-A3', 'Intel A Three', 'IA REPA', 'Y'),
       ('IA-A4', 'IA-A4', 'Intel A Four',  'IA REPA', 'Y'),
       ('IA-B1', 'IA-B1', 'Intel B One',   'IA REPB', 'Y'),
       ('IA-I1', 'IA-I1', 'Inactive rep',  'IA REPI', 'Y');

create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  select id into uid from t_user where label = p_label;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

-- The nightly batch: service_role, no JWT subject at all.
create or replace function pg_temp.become_service() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'service_role', true);
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. ai_batch_targets(): score ranking, no recommendation needed, fresh
--    summaries skipped before the cap.
--
--   rep A:  A1 90 (summarised 2h ago → skip)   A2 80   A3 70 (old summary)
--           A4 60 (closed recommendation 2 days ago → suppressed)
--   rep B:  B1 50
--   inactive rep: I1 99 → never a target
--------------------------------------------------------------------------
insert into public.account_signals (customer_key, score) values
  ('IA-A1', 90), ('IA-A2', 80), ('IA-A3', 70), ('IA-A4', 60),
  ('IA-B1', 50), ('IA-I1', 99);

insert into public.ai_summaries (customer_key, content, generated_at) values
  ('IA-A1', 'fresh',  now() - interval '2 hours'),
  ('IA-A3', 'stale',  now() - interval '30 hours');

insert into public.recommendations (customer_key, title, status, outcome, closed_at)
values ('IA-A4', 'Closed recently', 'closed', 'order_received', now() - interval '2 days');

select pg_temp.become_service();

select pg_temp.assert(
  (select array_agg(customer_key order by customer_key)
     from public.ai_batch_targets(2) where customer_key like 'IA-%')
  = array['IA-A2','IA-A3','IA-B1'],
  'per rep, top 2 by score: no recommendation needed; the fresh A1 is skipped '
  'BEFORE the cap so A3 makes the list; the old summary does not block A3');

select pg_temp.assert(
  (select count(*) from public.ai_batch_targets(25) where customer_key = 'IA-A4') = 0,
  'an account with a recommendation closed inside the cooldown stays quiet');

select pg_temp.assert(
  (select count(*) from public.ai_batch_targets(25) where customer_key = 'IA-I1') = 0,
  'an inactive rep''s book is never targeted');

select pg_temp.assert(
  (select array_agg(customer_key order by customer_key)
     from public.ai_batch_targets(1) where customer_key like 'IA-%')
  = array['IA-A2','IA-B1'],
  'per_rep 1: rep A''s first NON-fresh account, rep B''s top');

-- A repeat call after the batch wrote A2 moves on down rep A's list.
reset role;
insert into public.ai_summaries (customer_key, content, generated_at)
values ('IA-A2', 'just written', now());
select pg_temp.become_service();
select pg_temp.assert(
  (select array_agg(customer_key order by customer_key)
     from public.ai_batch_targets(1) where customer_key like 'IA-%')
  = array['IA-A3','IA-B1'],
  'a repeat call makes progress: A2 is now fresh, so rep A''s slot goes to A3');

-- Job only. _local_harness_grants.sql grants every public function to
-- authenticated after the migrations run; restate the migration's revoke
-- (the dim_part pattern below) and prove a rep's call is refused.
reset role;
revoke execute on function public.ai_batch_targets(int) from public, anon, authenticated;
select pg_temp.become('rep_a');
do $$ begin
  perform public.ai_batch_targets(5);
  raise exception 'FAILED: a rep could call ai_batch_targets()';
exception when insufficient_privilege then
  raise notice 'ok  job only: a rep cannot call ai_batch_targets()';
end $$;
reset role;
select pg_temp.assert(
  not has_function_privilege('anon', 'public.ai_batch_targets(int)', 'execute')
  and has_function_privilege('service_role', 'public.ai_batch_targets(int)', 'execute'),
  'anon cannot execute; the batch (service_role) can');
select pg_temp.assert(
  (select prosecdef and proconfig @> array['search_path=""']
     from pg_proc where oid = 'public.ai_batch_targets(int)'::regprocedure),
  'SECURITY DEFINER with a pinned empty search_path');

--------------------------------------------------------------------------
-- 2. ai_briefs.items
--------------------------------------------------------------------------
select pg_temp.assert(
  (select data_type = 'jsonb' and is_nullable = 'YES'
     from information_schema.columns
    where table_schema = 'public' and table_name = 'ai_briefs'
      and column_name = 'items'),
  'ai_briefs.items exists, jsonb, nullable');

select pg_temp.become('rep_a');
insert into public.ai_briefs (user_id, action, subject_key, content, items)
values ((select id from t_user where label='rep_a'), 'territory.brief', '', 'HEADLINES',
        '{"headlines":[{"text":"x","customer_key":"IA-A1","account_name":"Intel A One"}]}');
select pg_temp.assert(
  (select items -> 'headlines' -> 0 ->> 'customer_key' from public.ai_briefs
    where user_id = (select id from t_user where label='rep_a')) = 'IA-A1',
  'a rep writes and reads their own brief''s items');

--------------------------------------------------------------------------
-- 3. ai_feedback
--------------------------------------------------------------------------
-- Production grants: select/insert, and update of verdict + note only.
-- _local_harness_grants.sql re-grants every table wholesale; restate.
reset role;
revoke all on public.ai_feedback from authenticated;
grant select, insert on public.ai_feedback to authenticated;
grant update (verdict, note) on public.ai_feedback to authenticated;

select pg_temp.become('rep_a');

insert into public.ai_feedback (surface, subject_key, prompt_version, verdict)
values ('territory_brief', '', '2.0.0', 'helpful');
select pg_temp.assert(
  (select user_id from public.ai_feedback where surface = 'territory_brief')
    = (select id from t_user where label='rep_a'),
  'user_id defaults to the caller');

insert into public.ai_feedback (surface, subject_key, prompt_version, verdict, note)
values ('account_summary', 'IA-A2', '4.0.0', 'wrong', 'Backlog figure looked high');
select pg_temp.assert(
  (select count(*) from public.ai_feedback) = 2,
  'an account_summary vote on an account in the caller''s book');

do $$ begin
  insert into public.ai_feedback (surface, subject_key, verdict)
  values ('account_summary', 'IA-B1', 'wrong');
  raise exception 'FAILED: a vote landed on another rep''s account';
exception when insufficient_privilege then
  raise notice 'ok  an account_summary vote on another rep''s account is refused';
end $$;

do $$ begin
  insert into public.ai_feedback (user_id, surface, subject_key, verdict)
  values ((select id from t_user where label='rep_b'), 'territory_brief', '', 'helpful');
  raise exception 'FAILED: a vote was written under someone else''s user_id';
exception when insufficient_privilege then
  raise notice 'ok  a vote under another user''s id is refused';
end $$;

do $$ begin
  insert into public.ai_feedback (surface, subject_key, verdict)
  values ('territory_brief', '', 'meh');
  raise exception 'FAILED: an unknown verdict was accepted';
exception when check_violation then
  raise notice 'ok  verdict is helpful | wrong';
end $$;

do $$ begin
  -- An accessible subject, so the policy passes and the CHECK decides.
  insert into public.ai_feedback (surface, subject_key, verdict)
  values ('overview', 'IA-A2', 'helpful');
  raise exception 'FAILED: an unknown surface was accepted';
exception when check_violation then
  raise notice 'ok  surface is territory_brief | account_summary';
end $$;

update public.ai_feedback set verdict = 'wrong', note = 'Changed my mind'
 where surface = 'territory_brief';
select pg_temp.assert(
  (select verdict from public.ai_feedback where surface = 'territory_brief') = 'wrong',
  'a user can change their own vote and add a note');

do $$ begin
  update public.ai_feedback set prompt_version = 'forged';
  raise exception 'FAILED: prompt_version was updatable';
exception when insufficient_privilege then
  raise notice 'ok  only verdict and note are updatable';
end $$;

select pg_temp.become('rep_b');
select pg_temp.assert(
  (select count(*) from public.ai_feedback) = 0,
  'rep B reads none of rep A''s votes');
update public.ai_feedback set verdict = 'helpful';
select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.ai_feedback where verdict = 'wrong') = 2,
  'rep B''s update touched none of rep A''s rows');

select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) from public.ai_feedback) = 2,
  'an admin reads every vote');

select public.start_impersonation((select id from t_user where label='rep_a'));
do $$ begin
  insert into public.ai_feedback (surface, subject_key, verdict)
  values ('territory_brief', '', 'helpful');
  raise exception 'FAILED: a vote landed while viewing as a rep';
exception when sqlstate '42501' then
  raise notice 'ok  read-only while viewing as a rep';
end $$;
select public.stop_impersonation();

reset role;
select pg_temp.assert(
  not has_table_privilege('anon', 'public.ai_feedback', 'select')
  and not has_table_privilege('anon', 'public.ai_feedback', 'insert'),
  'anon has no access');
select pg_temp.assert(
  exists (select 1 from pg_trigger
           where tgrelid = 'public.ai_feedback'::regclass
             and tgname = 'trg_ai_feedback_no_write_while_viewing_as'),
  'the view-as write block is attached');

--------------------------------------------------------------------------
-- 4. report_account_family_mix(): the same months of both years.
--------------------------------------------------------------------------
-- dim_part's production column grants (see 20261013_reorder_candidates.sql).
do $$
declare cols text;
begin
  select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
    into cols
  from information_schema.columns c
  where c.table_schema = 'erp' and c.table_name = 'dim_part'
    and c.column_name <> all (array[
      'wholesale_unit_cost', 'unit_material_cost', 'unit_labor_cost',
      'unit_burden_cost', 'unit_service_cost', 'fixed_cost',
      'burden_percent', 'standard_unit_cost']);
  execute 'revoke select on erp.dim_part from authenticated';
  execute format('grant select (%s) on erp.dim_part to authenticated', cols);
end $$;

insert into erp.dim_part (part_key, part_id, part_description, product_code,
                          product_family, chambering)
values ('IA-MESA',  'IA-MESA',  'Mesa',     'FINISHED',  'Mesa',      '308 WIN'),
       ('IA-RIDGE', 'IA-RIDGE', 'Ridgeline','FINISHED',  'Ridgeline', '6.5 CM'),
       ('IA-TRAV',  'IA-TRAV',  'Traverse', 'FINISHED',  'Traverse',  '300 WM'),
       ('IA-COMP',  'IA-COMP',  'Barrel',   'COMPONENT', 'N/A',       'N/A');

-- Through March 2026: this period = Jan..Mar 2026, prior = Jan..Mar 2025.
--   Mesa      2026-02 $3,000 | 2025-01 $1,000   2025-03 $1,000
--   Ridgeline 2026-03 $0 net | 2025-02 $4,000   (never this period → stopped)
--             2025-11 $9,000 is outside the prior window (the old YTD-vs-
--             full-year comparison counted it)
--   Traverse  2026-04 $5,000 is after p_through → not counted
--   Component $50,000 — no real family, left out
insert into erp.agg_sku_month (customer_key, part_key, sales_month, revenue, qty, invoice_count)
values ('IA-A1', 'IA-MESA',  '2026-02-01', 3000, 3, 1),
       ('IA-A1', 'IA-MESA',  '2025-01-01', 1000, 1, 1),
       ('IA-A1', 'IA-MESA',  '2025-03-01', 1000, 1, 1),
       ('IA-A1', 'IA-RIDGE', '2025-02-01', 4000, 2, 1),
       ('IA-A1', 'IA-RIDGE', '2025-11-01', 9000, 5, 1),
       ('IA-A1', 'IA-TRAV',  '2026-04-01', 5000, 2, 1),
       ('IA-A1', 'IA-COMP',  '2026-01-01', 50000, 100, 1),
       ('IA-B1', 'IA-MESA',  '2026-02-01', 7000, 7, 1);

select pg_temp.become('rep_a');

select pg_temp.assert(
  (select array_agg((product_family, revenue, qty, prior_revenue, prior_qty)::text
                    order by product_family)
     from public.report_account_family_mix('IA-A1', '2026-03-01'))
  = array[('Mesa', 3000, 3, 2000, 2)::text, ('Ridgeline', 0, 0, 4000, 2)::text],
  'same months both years; nothing after p_through; no component family');

select pg_temp.assert(
  (select (period_start, period_end, prior_start, prior_end)::text
     from public.report_account_family_mix('IA-A1', '2026-03-15') limit 1)
  = ('2026-01-01'::date, '2026-03-01'::date, '2025-01-01'::date, '2025-03-01'::date)::text,
  'a mid-month p_through snaps to its month; the windows are reported back');

select pg_temp.assert(
  (select array_agg(product_family)
     from public.report_account_family_mix('IA-A1', '2026-03-01'))
  = array['Ridgeline', 'Mesa'],
  'ordered by the larger of the two periods');

select pg_temp.assert(
  (select count(*) from public.report_account_family_mix('IA-B1', '2026-03-01')) = 0,
  'rep A gets nothing for rep B''s account (RLS on agg_sku_month)');

-- Parity: the batch (service_role) reads exactly what the rep reads.
create temporary table t_mix_rep on commit drop as
  select * from public.report_account_family_mix('IA-A1', '2026-03-01');
create temporary table t_reorder_rep on commit drop as
  select * from public.report_reorder_candidates('IA-A1', 10);

reset role;
grant select on t_mix_rep, t_reorder_rep to service_role;

-- Something in stock so the reorder parity check compares real rows.
insert into erp.fact_available_to_sell (part_key, site_key, available_to_sell_qty)
values ('IA-MESA', 'S1', 5);
select pg_temp.become('rep_a');
drop table t_reorder_rep;
create temporary table t_reorder_rep on commit drop as
  select * from public.report_reorder_candidates('IA-A1', 10);
reset role;
grant select on t_reorder_rep to service_role;

select pg_temp.become_service();
select pg_temp.assert(
  (select count(*) from t_reorder_rep) = 1,
  'the reorder parity fixture has a row to compare');
select pg_temp.assert(
  not exists (
    (select * from public.report_account_family_mix('IA-A1', '2026-03-01')
     except all select * from t_mix_rep)
    union all
    (select * from t_mix_rep
     except all select * from public.report_account_family_mix('IA-A1', '2026-03-01'))
  ),
  'family mix: service_role reads the same rows as the rep');
select pg_temp.assert(
  not exists (
    (select * from public.report_reorder_candidates('IA-A1', 10)
     except all select * from t_reorder_rep)
    union all
    (select * from t_reorder_rep
     except all select * from public.report_reorder_candidates('IA-A1', 10))
  ),
  'reorder candidates: service_role reads the same rows as the rep');

reset role;
select pg_temp.assert(
  not has_function_privilege('anon', 'public.report_account_family_mix(text, date)', 'execute')
  and has_function_privilege('authenticated', 'public.report_account_family_mix(text, date)', 'execute'),
  'family mix: authenticated may execute, anon may not');
select pg_temp.assert(
  (select not prosecdef from pg_proc
    where oid = 'public.report_account_family_mix(text, date)'::regprocedure),
  'family mix is SECURITY INVOKER (RLS is the scope)');
select pg_temp.assert(
  exists (select 1 from pg_indexes
           where schemaname = 'erp' and indexname = 'idx_agg_sku_year_part'),
  'agg_sku_year has a part-first index for "who bought this SKU"');

do $$ begin raise notice 'ALL INTEL AI TESTS PASSED'; end $$;

rollback;
