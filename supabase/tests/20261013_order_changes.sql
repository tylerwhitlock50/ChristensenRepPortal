/*============================================================================
  20261013_order_changes.sql — the nightly order change capture
  (20261013150003) and the Overview activity feed (20261013150004).

  Runs in a transaction and ROLLS BACK; creates throwaway auth users and ERP
  rows. Dev or a local harness only — never prod (it truncates the
  snapshot inside its own transaction to start from a known state).

      psql "$DATABASE_URL" -f supabase/tests/20261013_order_changes.sql

  A clean run prints "ALL ORDER CHANGE TESTS PASSED".

  What is at stake
  ----------------
  1. capture_order_changes() is the LAST step of the nightly load. If it
     ever raises, the whole night is recorded as a failed run (freshness
     stamp frozen, AI batch skipped). T6 forces an internal error and
     requires a normal return.
  2. The events are per-account facts about a dealer's orders. A rep must
     never read another rep's (T4), and the feed view inherits that (T7).
  3. The first night must not announce every open line as news (T1), and a
     second run over unchanged data must announce nothing (T3).
============================================================================*/

begin;

\set ON_ERROR_STOP on

-- The capture pins America/Denver; date the fixtures on the same calendar.
set local timezone to 'America/Denver';

--------------------------------------------------------------------------
-- Production grants. _local_harness_grants.sql grants authenticated
-- everything on every public table and function, which would make the
-- privilege assertions below pass or fail for the wrong reason. Restate
-- exactly what 20261013150003 / 150004 grant.
--------------------------------------------------------------------------
revoke all on public.order_line_snapshot from anon, authenticated, public;
revoke all on public.order_change_events from anon, authenticated, public;
grant select on public.order_change_events to authenticated;
revoke execute on function public.capture_order_changes() from public, anon, authenticated;
revoke all on public.v_territory_recent_events from anon, public;

-- Start from a known state on a database where the capture already ran.
truncate public.order_line_snapshot;
delete from public.order_change_events;

--------------------------------------------------------------------------
-- Fixtures: rep A owns OCE-A (and the inactive OCE-X), rep B owns OCE-B.
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-7777-4777-8777-777777777777'),
  ('rep_b', 'bbbbbbbb-8888-4888-8888-888888888888'),
  ('admin', 'cccccccc-9999-4999-8999-999999999999');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@changes.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'OCE REPA'
  where user_id = (select id from t_user where label = 'rep_a');
update public.profiles set sales_rep_key = 'OCE REPB'
  where user_id = (select id from t_user where label = 'rep_b');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag, internal_customer_flag)
values ('OCE-A', 'OCE-A', 'Rep A Dealer',    'OCE REPA', 'Y', 'N'),
       ('OCE-B', 'OCE-B', 'Rep B Dealer',    'OCE REPB', 'Y', 'N'),
       ('OCE-X', 'OCE-X', 'Rep A Inactive',  'OCE REPA', 'N', 'N');

insert into erp.dim_part (part_key, part_id, part_description)
values ('OCE-P1', 'OCE-MPR-308', 'MPR 308 Win 16in'),
       ('OCE-P2', 'OCE-MESA-65', 'Mesa 6.5 CM 22in')
on conflict (part_key) do nothing;

-- yyyymmdd key n days from today (Mountain).
create or replace function pg_temp.dk(n int) returns int
language sql stable as $$ select to_char(current_date + n, 'YYYYMMDD')::int $$;

-- Tonight's book, before anything changes:
--   OCE-SO1  rep A, ordered 30 days ago, line 1 open past its promise
--            (a backorder), line 2 open with a future promise.
--   OCE-SO2  rep A, ordered today, one open line promised in 10 days.
--   OCE-SO3  rep B, ordered 20 days ago, one open line.
--   OCE-SO4  rep A, ordered 12 days ago, open — will be cancelled.
--   OCE-OLD  rep A, ordered 400 days ago, long closed — never news.
insert into erp.fact_order_line
  (order_id, line_num, customer_key, part_key, customer_po_number, order_status,
   line_status, order_date_key, promise_date_key, order_qty, bookings,
   total_shipped_qty_to_date, backlog_qty, backlog_amount, is_backlog_line)
values
  ('OCE-SO1', 1, 'OCE-A', 'OCE-P1', 'PO-OCE-1', 'R', 'A', pg_temp.dk(-30), pg_temp.dk(-3),  3, 5700, 0, 3, 5700, true),
  ('OCE-SO1', 2, 'OCE-A', 'OCE-P2', 'PO-OCE-1', 'R', 'A', pg_temp.dk(-30), pg_temp.dk(14),  2, 2600, 0, 2, 2600, true),
  ('OCE-SO2', 1, 'OCE-A', 'OCE-P2', 'PO-OCE-2', 'R', 'A', pg_temp.dk(0),   pg_temp.dk(10),  1, 1300, 0, 1, 1300, true),
  ('OCE-SO3', 1, 'OCE-B', 'OCE-P1', 'PO-OCE-3', 'R', 'A', pg_temp.dk(-20), pg_temp.dk(5),   4, 7600, 0, 4, 7600, true),
  ('OCE-SO4', 1, 'OCE-A', 'OCE-P1', 'PO-OCE-4', 'R', 'A', pg_temp.dk(-12), pg_temp.dk(20),  1, 1900, 0, 1, 1900, true),
  ('OCE-OLD', 1, 'OCE-A', 'OCE-P1', 'PO-OCE-0', 'C', 'C', pg_temp.dk(-400), pg_temp.dk(-390), 1, 1900, 1, 0, 0, false);

create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  select id into uid from t_user where label = p_label;
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

create temporary table t_run (n int primary key, outcome text, events bigint, snapshot_rows bigint)
  on commit drop;

--------------------------------------------------------------------------
-- T1. The first run seeds the snapshot and announces nothing.
--------------------------------------------------------------------------
insert into t_run select 1, r.* from public.capture_order_changes() r;

select pg_temp.assert(
  (select outcome from t_run where n = 1) = 'seeded'
  and (select events from t_run where n = 1) = 0,
  'T1 first run: outcome seeded, zero events');
select pg_temp.assert(
  (select count(*) from public.order_change_events) = 0,
  'T1 first run wrote no events');
select pg_temp.assert(
  (select array_agg(order_id || '/' || line_num order by order_id, line_num)
     from public.order_line_snapshot where order_id like 'OCE-%')
  = array['OCE-SO1/1','OCE-SO1/2','OCE-SO2/1','OCE-SO3/1','OCE-SO4/1'],
  'T1 snapshot keeps open and recent lines, not the long-closed order');
select pg_temp.assert(
  (select bool_and(snapped_on = current_date) from public.order_line_snapshot),
  'T1 snapshot is dated today (Mountain)');

--------------------------------------------------------------------------
-- T2. The next night: everything that can change, changes.
--------------------------------------------------------------------------
-- SO1/1, the backorder, ships in full — with a tracking number.
update erp.fact_order_line
   set total_shipped_qty_to_date = 3, backlog_qty = 0, backlog_amount = 0,
       is_backlog_line = false, line_status = 'C', last_shipped_date_key = pg_temp.dk(0)
 where order_id = 'OCE-SO1' and line_num = 1;
insert into erp.fact_shipment_line
  (packlist_id, line_num, order_id, order_line_no, customer_key, part_key,
   tracking_number, ship_date_key, shipped_qty, shipped_revenue)
values ('OCE-PL1', 1, 'OCE-SO1', 1, 'OCE-A', 'OCE-P1', '1ZOCE0000000001', pg_temp.dk(0), 3, 5700);

-- SO1/2's promise date slides a week.
update erp.fact_order_line set promise_date_key = pg_temp.dk(21)
 where order_id = 'OCE-SO1' and line_num = 2;

-- SO2/1, today's order, ships one unit straight away: an ordinary shipment.
update erp.fact_order_line
   set total_shipped_qty_to_date = 1, backlog_qty = 0, backlog_amount = 0,
       is_backlog_line = false, line_status = 'C'
 where order_id = 'OCE-SO2' and line_num = 1;

-- SO4 is cancelled.
update erp.fact_order_line
   set order_status = 'X', is_backlog_line = false, backlog_qty = 0, backlog_amount = 0
 where order_id = 'OCE-SO4';

-- A brand-new order for rep A (two lines) and one for rep B; and a new
-- order that arrives already cancelled, which is not news.
insert into erp.fact_order_line
  (order_id, line_num, customer_key, part_key, customer_po_number, order_status,
   line_status, order_date_key, promise_date_key, order_qty, bookings,
   total_shipped_qty_to_date, backlog_qty, backlog_amount, is_backlog_line)
values
  ('OCE-SO5', 1, 'OCE-A', 'OCE-P1', 'PO-OCE-5', 'R', 'A', pg_temp.dk(0), pg_temp.dk(30), 2, 3800, 0, 2, 3800, true),
  ('OCE-SO5', 2, 'OCE-A', 'OCE-P2', 'PO-OCE-5', 'R', 'A', pg_temp.dk(0), pg_temp.dk(30), 1, 1300, 0, 1, 1300, true),
  ('OCE-SO6', 1, 'OCE-B', 'OCE-P2', 'PO-OCE-6', 'R', 'A', pg_temp.dk(0), pg_temp.dk(30), 1, 1300, 0, 1, 1300, true),
  ('OCE-SO7', 1, 'OCE-A', 'OCE-P2', 'PO-OCE-7', 'X', 'X', pg_temp.dk(0), null,           1, 1300, 0, 0,    0, false);

insert into t_run select 2, r.* from public.capture_order_changes() r;

select pg_temp.assert(
  (select outcome from t_run where n = 2) = 'captured',
  'T2 second run: outcome captured');

select pg_temp.assert(
  (select array_agg(kind || ':' || order_id || coalesce('/' || line_no, '')
                    order by kind, order_id, line_no)
     from public.order_change_events)
  = array['backorder_shipped:OCE-SO1/1',
          'line_shipped:OCE-SO2/1',
          'order_cancelled:OCE-SO4',
          'order_new:OCE-SO5',
          'order_new:OCE-SO6',
          'promise_slipped:OCE-SO1/2'],
  'T2 exactly the right kinds, on the right orders and lines');

select pg_temp.assert(
  (select events from t_run where n = 2) = 6,
  'T2 the run reports the six events it wrote');

select pg_temp.assert(
  (select after ->> 'tracking_numbers' from public.order_change_events
    where kind = 'backorder_shipped') = '1ZOCE0000000001'
  and (select (after ->> 'shipped_now')::numeric from public.order_change_events
    where kind = 'backorder_shipped') = 3,
  'T2 backorder_shipped carries the tracking number and the units shipped');

select pg_temp.assert(
  (select (before ->> 'promise_date')::date = current_date + 14
      and (after  ->> 'promise_date')::date = current_date + 21
      and (after  ->> 'days_later')::int = 7
     from public.order_change_events where kind = 'promise_slipped'),
  'T2 promise_slipped carries the old date, the new date and the slip');

select pg_temp.assert(
  (select (after ->> 'line_count')::int = 2
      and (after ->> 'bookings')::numeric = 5100
      and after ->> 'customer_po_number' = 'PO-OCE-5'
     from public.order_change_events where kind = 'order_new' and order_id = 'OCE-SO5'),
  'T2 order_new is one row per order, with its PO, lines and bookings');

select pg_temp.assert(
  (select line_no is null and part_key is null
     from public.order_change_events where kind = 'order_cancelled'),
  'T2 order_cancelled is order-level');

select pg_temp.assert(
  (select bool_and(detected_on = current_date) from public.order_change_events),
  'T2 events are dated today (Mountain)');

--------------------------------------------------------------------------
-- T3. A rerun over unchanged data announces nothing.
--------------------------------------------------------------------------
insert into t_run select 3, r.* from public.capture_order_changes() r;

select pg_temp.assert(
  (select outcome from t_run where n = 3) = 'captured'
  and (select events from t_run where n = 3) = 0
  and (select count(*) from public.order_change_events) = 6,
  'T3 idempotent rerun: zero new events');

select pg_temp.assert(
  (select count(*) from public.job_runs
    where job_name = 'etl:order_changes' and status = 'success') >= 3,
  'T3 every run logs etl:order_changes success');

--------------------------------------------------------------------------
-- T4. RLS: reps read their own book only; nobody in the app writes.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(
  (select count(*) from public.order_change_events) = 5
  and (select bool_and(customer_key = 'OCE-A') from public.order_change_events),
  'T4 rep A reads exactly rep A''s five events');

select pg_temp.become('rep_b');
select pg_temp.assert(
  (select array_agg(order_id) from public.order_change_events) = array['OCE-SO6'],
  'T4 rep B reads only rep B''s new order');

select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) from public.order_change_events) = 6,
  'T4 an admin reads every event');

select public.start_impersonation((select id from t_user where label = 'rep_b'));
select pg_temp.assert(
  (select array_agg(order_id) from public.order_change_events) = array['OCE-SO6'],
  'T4 an admin viewing as rep B reads exactly rep B''s scope');
select public.stop_impersonation();

select pg_temp.become('rep_a');
do $$
begin
  begin
    insert into public.order_change_events (customer_key, order_id, kind)
    values ('OCE-A', 'OCE-FAKE', 'order_new');
    raise exception 'FAILED: T4 a rep could insert an event';
  exception when insufficient_privilege then
    raise notice 'ok  T4 a rep cannot insert an event';
  end;
  begin
    delete from public.order_change_events;
    raise exception 'FAILED: T4 a rep could delete events';
  exception when insufficient_privilege then
    raise notice 'ok  T4 a rep cannot delete events';
  end;
  begin
    perform 1 from public.order_line_snapshot limit 1;
    raise exception 'FAILED: T4 a rep could read the snapshot';
  exception when insufficient_privilege then
    raise notice 'ok  T4 a rep cannot read the snapshot';
  end;
  begin
    perform public.capture_order_changes();
    raise exception 'FAILED: T4 a rep could run the capture';
  exception when insufficient_privilege then
    raise notice 'ok  T4 a rep cannot run the capture';
  end;
end $$;
reset role;

select pg_temp.assert(
  not has_table_privilege('anon', 'public.order_change_events', 'select')
  and not has_table_privilege('anon', 'public.order_line_snapshot', 'select')
  and not has_table_privilege('authenticated', 'public.order_line_snapshot', 'select'),
  'T4 anon holds nothing; authenticated cannot read the snapshot');

--------------------------------------------------------------------------
-- T5. Retention: events older than 60 days are trimmed by the next run.
--------------------------------------------------------------------------
insert into public.order_change_events (customer_key, order_id, kind, detected_on)
values ('OCE-A', 'OCE-ANCIENT', 'order_new', current_date - 61),
       ('OCE-A', 'OCE-KEPT',    'order_new', current_date - 60);
select public.capture_order_changes();
select pg_temp.assert(
  not exists (select 1 from public.order_change_events where order_id = 'OCE-ANCIENT')
  and exists (select 1 from public.order_change_events where order_id = 'OCE-KEPT'),
  'T5 61-day-old events are trimmed, 60-day-old kept');

--------------------------------------------------------------------------
-- T6. A failure inside the capture is logged and swallowed. Break the
--     snapshot's shape so the body fails mid-run; the function must
--     return normally, change nothing, and leave an error in job_runs.
--------------------------------------------------------------------------
update erp.fact_order_line set promise_date_key = pg_temp.dk(40)
 where order_id = 'OCE-SO5';
alter table public.order_line_snapshot rename column shipped_qty to shipped_qty_broken;

insert into t_run select 6, r.* from public.capture_order_changes() r;

select pg_temp.assert(
  (select outcome from t_run where n = 6) = 'error'
  and (select events from t_run where n = 6) = 0,
  'T6 a forced internal error returns (error, 0, 0) instead of raising');
select pg_temp.assert(
  exists (select 1 from public.job_runs
           where job_name = 'etl:order_changes' and status = 'error'
             and error like '42703:%'),
  'T6 the failure is logged to job_runs with its SQLSTATE');
select pg_temp.assert(
  not exists (select 1 from public.order_change_events
               where order_id = 'OCE-SO5' and kind = 'promise_slipped'),
  'T6 the failed run wrote no events (its work rolled back as a unit)');

alter table public.order_line_snapshot rename column shipped_qty_broken to shipped_qty;
select public.capture_order_changes();
select pg_temp.assert(
  (select count(*) from public.order_change_events
    where order_id = 'OCE-SO5' and kind = 'promise_slipped') = 2,
  'T6 the next good run catches up on what the failed one missed');

--------------------------------------------------------------------------
-- T7. The activity feed view.
--------------------------------------------------------------------------
-- An inactive account's order: never in the feed.
insert into erp.fact_order_line
  (order_id, line_num, customer_key, order_status, order_date_key, bookings, order_qty, is_backlog_line)
values ('OCE-SOX', 1, 'OCE-X', 'R', pg_temp.dk(-1), 999, 1, true);

select pg_temp.become('rep_a');
select pg_temp.assert(
  (select array_agg(distinct kind order by kind) from public.v_territory_recent_events
    where customer_key = 'OCE-A')
  = array['backorder_shipped', 'order_new', 'promise_slipped', 'shipped'],
  'T7 rep A''s feed has new orders, shipments and both called-out events');
select pg_temp.assert(
  not exists (select 1 from public.v_territory_recent_events where customer_key <> 'OCE-A'),
  'T7 rep A''s feed holds nothing from rep B or the inactive account');
select pg_temp.assert(
  (select tracking_numbers from public.v_territory_recent_events
    where kind = 'shipped' and order_id = 'OCE-SO1') = '1ZOCE0000000001',
  'T7 a shipment row carries its tracking number');
select pg_temp.assert(
  (select customer_po_number from public.v_territory_recent_events
    where kind = 'shipped' and order_id = 'OCE-SO1') = 'PO-OCE-1'
  and (select customer_po_number from public.v_territory_recent_events
    where kind = 'promise_slipped' and order_id = 'OCE-SO1') = 'PO-OCE-1',
  'T7 shipment and event rows carry the dealer''s PO (what Send tracking leads with)');
select pg_temp.assert(
  (select part_id = 'OCE-MESA-65' and line_no = 2
          and promise_before = current_date + 14
          and promise_after  = current_date + 21
     from public.v_territory_recent_events
    where kind = 'promise_slipped' and order_id = 'OCE-SO1'),
  'T7 a slip names the line''s part and both dates');
select pg_temp.assert(
  not exists (select 1 from public.v_territory_recent_events where order_id in ('OCE-SO4', 'OCE-SO7')),
  'T7 cancelled orders are not "new orders"');
select pg_temp.assert(
  not exists (select 1 from public.v_territory_recent_events where order_id = 'OCE-OLD'),
  'T7 the window is 14 days');

select pg_temp.become('rep_b');
-- OCE-SO3 was ordered 20 days ago: outside the window, and nothing about
-- it changed. Rep B's one item is today's new order.
select pg_temp.assert(
  (select array_agg(kind || ':' || order_id) from public.v_territory_recent_events)
  = array['order_new:OCE-SO6'],
  'T7 rep B''s feed is rep B''s alone');
reset role;

select pg_temp.assert(
  (select array_agg(attname::text order by attnum) from pg_attribute
    where attrelid = 'public.v_territory_recent_events'::regclass and attnum > 0
      and not attisdropped)
  = array['customer_key','customer_name','kind','occurred_on','order_id',
          'customer_po_number','packlist_id','line_no','part_id',
          'part_description','amount','qty','line_count','tracking_numbers',
          'ship_via','promise_before','promise_after','has_backlog','event_id'],
  'T7 the feed''s columns, in order (append-only from here)');

select pg_temp.assert(
  (select reloptions @> array['security_invoker=true'] from pg_class
    where oid = 'public.v_territory_recent_events'::regclass)
  and not has_table_privilege('anon', 'public.v_territory_recent_events', 'select'),
  'T7 security_invoker, nothing for anon');

--------------------------------------------------------------------------
-- T8. The function itself: definer, pinned, job-only.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select prosecdef and proconfig @> array['search_path=""', 'TimeZone=America/Denver']
     from pg_proc where oid = 'public.capture_order_changes()'::regprocedure),
  'T8 SECURITY DEFINER with search_path and TimeZone pinned');
select pg_temp.assert(
  not has_function_privilege('authenticated', 'public.capture_order_changes()', 'execute')
  and not has_function_privilege('anon', 'public.capture_order_changes()', 'execute'),
  'T8 no app role can execute it');

do $$ begin raise notice 'ALL ORDER CHANGE TESTS PASSED'; end $$;

rollback;
