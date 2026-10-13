/*============================================================================
  20261013150003_order_change_events.sql — the nightly load remembers what
  changed on the order book.

  Why
  ---
  The ETL replaces erp.fact_order_line wholesale every night (DELETE +
  INSERT from staging), so the database only ever knows today's state. A
  backordered rifle shipping, a promise date sliding a week, a dealer
  cancelling — each is visible only as the absence of yesterday's row, and
  the rep hears about it when the dealer rings to ask. Reps want to make
  the good-news call first ("your backorder just shipped").

  What
  ----
  1. public.order_line_snapshot — the order lines worth comparing tomorrow,
     as they stood after tonight's load. Internal: RLS on, no policies, no
     grants to any app role. Holds only what can still change in a way a
     rep cares about — every open line plus every line of an order placed in
     the last SNAPSHOT_DAYS (45) — so it is tens of thousands of rows, not
     the whole half-million-line history.

  2. public.order_change_events — one row per thing that happened:

       order_new          an order that was not there last night (one row per
                          order; line_no null)
       line_shipped       a line's shipped quantity went up
       backorder_shipped  the same, on a line that had been waiting: its
                          promise date or the dealer's desired ship date had
                          already passed when last seen, or — only when it
                          carried neither date — it had been on order
                          BACKORDER_DAYS (7) or more. Not a ship-from-stock
                          order, and not a dated or pre-season order going
                          out on its date: age alone would call every order
                          placed weeks ahead a backorder.
       promise_slipped    an open line's promise date moved later
       order_cancelled    the order's status became X (one row per order)

     before/after carry the changed values (jsonb). detected_on is the
     Mountain-time date of the run. Reps read their own book through
     my_customer_keys() (view-as aware, like every account-scoped table);
     admins read all; nobody but the capture writes. Kept 60 days.

  3. public.capture_order_changes() — run by the ETL as an optional
     post_load_sql step after scoring (etl/views.yml). Diffs tonight's fact_order_line (and, for shipped
     lines, the shipment lines' tracking) against the snapshot, inserts the
     events, replaces the snapshot, trims old events. The FIRST run only
     seeds the snapshot: with nothing to compare against, every open line
     would otherwise be "new". It takes the snapshot's lock first, so a
     second capture started while one is running (a hand-run push.ps1
     during the scheduled one) waits, then diffs against the first one's
     snapshot instead of writing every event twice.

  ── Failure isolation ─────────────────────────────────────────────────────
  An exception in a required post_load_sql step stops the step list and
  marks the whole night's run failed (push_to_supabase.py): the freshness
  stamp stops advancing and the AI batch is skipped — for a feature that
  only annotates the data. views.yml marks this step optional (a missing
  function on a database without this migration is only logged), and the
  body also runs in its own block that catches
  everything, including a statement timeout (query_canceled is not covered
  by WHEN OTHERS), rolls back its own work as a unit, logs
  'etl:order_changes' / 'error' through log_job_run() and returns
  normally. A missed night is not lost: the next run diffs against the
  last good snapshot, so the changes surface a day late, dated that day.

  ── Why not a diff of staging against live ────────────────────────────────
  The richer design computes events inside each table's swap, from
  etl_stage vs erp. That needs the loader restructured; this needs one
  post-load step and no change to the proven apply path, and a broken
  capture can never touch a load.

  Not here, deliberately: ownership changes (an account moving between
  reps is invisible to the rep who lost it under customer_key RLS — it
  needs rep-keyed visibility, a design of its own), line-level
  cancellations, and anything on invoices.

  Backward compatible: two new tables, one new function. Nothing existing
  changes shape; the deployed frontend, edge functions and MCP server never
  read either table.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The snapshot.
--------------------------------------------------------------------------
create table if not exists public.order_line_snapshot (
    order_id        text    not null,
    line_num        int     not null,
    customer_key    text    not null,
    part_key        text,
    order_date      date,
    order_status    text,
    line_status     text,
    promise_date    date,
    -- What the dealer asked for. A line past it when last seen was waiting
    -- on us (backorder_shipped), even when its promise date moved out.
    desired_ship_date date,
    is_backlog_line boolean,
    backlog_qty     numeric,
    -- fact_order_line.total_shipped_qty_to_date at snapshot time. Cumulative
    -- on the line, so tonight minus this is what shipped in between.
    shipped_qty     numeric,
    snapped_on      date    not null,
    primary key (order_id, line_num)
);
alter table public.order_line_snapshot enable row level security;
-- For a database that ran an earlier draft of this file.
alter table public.order_line_snapshot add column if not exists desired_ship_date date;

comment on table public.order_line_snapshot is
  'Order lines as they stood after the last nightly load — what '
  'capture_order_changes() diffs tonight''s erp.fact_order_line against. '
  'Open lines plus lines of recent orders only. Internal: no policies, no '
  'app grants (20261013150003).';

-- No policy on purpose: RLS on with no policy denies every app role, and
-- the grants below deny them twice. Only the owner (the ETL) touches it.
revoke all on public.order_line_snapshot from anon, authenticated, public;

--------------------------------------------------------------------------
-- 2. The events.
--------------------------------------------------------------------------
create table if not exists public.order_change_events (
    id           bigint generated always as identity primary key,
    -- erp.dim_customer.customer_key, no FK (erp is reloaded wholesale),
    -- same as account_deactivations (023).
    customer_key text   not null,
    order_id     text   not null,
    -- Null for the order-level kinds (order_new, order_cancelled).
    line_no      int,
    part_key     text,
    kind         text   not null
                 check (kind in ('order_new', 'line_shipped', 'backorder_shipped',
                                 'promise_slipped', 'order_cancelled')),
    before       jsonb,
    after        jsonb,
    detected_on  date   not null default current_date,
    created_at   timestamptz not null default now()
);
alter table public.order_change_events enable row level security;

comment on table public.order_change_events is
  'What changed on the order book at each nightly load: new orders, shipped '
  'lines (backorders called out), slipped promise dates, cancellations. '
  'Written only by capture_order_changes(); kept 60 days. Reps read their '
  'own book (20261013150003).';
comment on column public.order_change_events.detected_on is
  'Mountain-time date of the load that noticed the change — not when it '
  'happened in the ERP, which can be earlier if a night''s capture failed.';

-- The feed's read: one account's or the book's recent events, newest
-- first. Leads with customer_key, which is also the RLS predicate.
create index if not exists idx_order_change_events_customer
  on public.order_change_events (customer_key, detected_on desc);
-- The territory feed (unfiltered, RLS-scoped) and the 60-day trim.
create index if not exists idx_order_change_events_detected
  on public.order_change_events (detected_on);

-- Same predicate shape as account_signals (019) and call_list_feedback:
-- scalar subqueries so is_admin() is an InitPlan and my_customer_keys()
-- is uncorrelated. Both resolve the view-as identity, so an admin viewing
-- as a rep reads that rep's events.
drop policy if exists "read own order change events" on public.order_change_events;
create policy "read own order change events" on public.order_change_events
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

-- Read-only for the app: no insert/update/delete policy, and no grant.
revoke all on public.order_change_events from anon, public;
revoke all on public.order_change_events from authenticated;
grant select on public.order_change_events to authenticated;

--------------------------------------------------------------------------
-- 3. The capture.
--------------------------------------------------------------------------
create or replace function public.capture_order_changes()
returns table (outcome text, events bigint, snapshot_rows bigint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- One "today" for the run (Mountain: pinned below, like the refresh).
  today          constant date := current_date;
  started        constant timestamptz := clock_timestamp();
  -- What the snapshot keeps: open lines, plus every line of an order placed
  -- this recently (so tomorrow can tell a new order from an old one).
  snapshot_days  constant int := 45;
  -- A shipped line with neither a promise nor a desired date counts as a
  -- backorder when it had been on order at least this long when last seen.
  backorder_days constant int := 7;
  keep_days      constant int := 60;
  prev_day       date;
  n              bigint;
  n_events       bigint := 0;
  n_rows         bigint := 0;
  err_state      text;
  err_message    text;
begin
  begin
    -- One capture at a time. Without this, two overlapping runs both read
    -- the old snapshot and both insert the same events. Nothing else
    -- reads the snapshot, and the replace below takes this lock anyway.
    lock table public.order_line_snapshot in access exclusive mode;

    select max(s.snapped_on) into prev_day from public.order_line_snapshot s;

    -- First run: nothing to compare against. Seed silently.
    if prev_day is not null then

      -- order_new: an order with no line in the snapshot, placed late
      -- enough that it WOULD be in the snapshot had it existed last time
      -- (the snapshot kept every line of orders from prev_day -
      -- snapshot_days on). Cancelled-on-arrival orders are not news.
      insert into public.order_change_events
        (customer_key, order_id, kind, after, detected_on)
      select
          o.customer_key,
          o.order_id,
          'order_new',
          jsonb_build_object(
            'order_date',         max(o.order_date),
            'customer_po_number', nullif(string_agg(distinct nullif(o.customer_po_number, ''), ', '), ''),
            'line_count',         count(*),
            'open_line_count',    count(*) filter (where o.is_backlog_line),
            'bookings',           coalesce(sum(o.bookings), 0)
          ),
          today
      from erp.fact_order_line o
      where o.order_date >= prev_day - snapshot_days
        and coalesce(o.order_status, '') <> 'X'
        and not exists (
          select 1 from public.order_line_snapshot p
          where p.order_id = o.order_id
        )
      group by o.customer_key, o.order_id;
      get diagnostics n = row_count;
      n_events := n_events + n;

      -- Shipped lines. Only a line that was still owed last time can ship;
      -- total_shipped_qty_to_date is cumulative, so a rise is a shipment.
      -- Tracking: shipment lines for that order line shipped since the
      -- snapshot (text only — no shipment measure is read here).
      insert into public.order_change_events
        (customer_key, order_id, line_no, part_key, kind, before, after, detected_on)
      select
          o.customer_key,
          o.order_id,
          o.line_num,
          o.part_key,
          case
            -- Late against what we promised, or what they asked for...
            when (p.promise_date is not null and p.promise_date < p.snapped_on)
              or (p.desired_ship_date is not null and p.desired_ship_date < p.snapped_on)
            then 'backorder_shipped'
            -- ...or, with no date to judge by, simply waiting a while. A
            -- line with a date still ahead of it is a scheduled order going
            -- out on time, however long ago it was placed.
            when p.promise_date is null and p.desired_ship_date is null
              and p.order_date is not null
              and p.order_date <= p.snapped_on - backorder_days
            then 'backorder_shipped'
            else 'line_shipped'
          end,
          jsonb_build_object(
            'shipped_qty',       p.shipped_qty,
            'backlog_qty',       p.backlog_qty,
            'promise_date',      p.promise_date,
            'desired_ship_date', p.desired_ship_date,
            'order_date',        p.order_date
          ),
          jsonb_build_object(
            'shipped_qty',       o.total_shipped_qty_to_date,
            'shipped_now',       coalesce(o.total_shipped_qty_to_date, 0) - coalesce(p.shipped_qty, 0),
            'backlog_qty',       o.backlog_qty,
            'last_shipped_date', o.last_shipped_date,
            'tracking_numbers', (
              select nullif(string_agg(distinct t.tracking_no, ', ' order by t.tracking_no), '')
              from (
                select coalesce(nullif(s.tracking_number, ''), nullif(s.waybill_number, '')) as tracking_no
                from erp.fact_shipment_line s
                where s.order_id      = o.order_id
                  and s.order_line_no = o.line_num
                  and s.ship_date    >= prev_day
              ) t
              where t.tracking_no is not null
            )
          ),
          today
      from public.order_line_snapshot p
      join erp.fact_order_line o
        on o.order_id = p.order_id
       and o.line_num = p.line_num
      where p.is_backlog_line
        and coalesce(o.total_shipped_qty_to_date, 0) > coalesce(p.shipped_qty, 0);
      get diagnostics n = row_count;
      n_events := n_events + n;

      -- promise_slipped: still open, and promised later than last time. A
      -- date appearing or being cleared is not a slip.
      insert into public.order_change_events
        (customer_key, order_id, line_no, part_key, kind, before, after, detected_on)
      select
          o.customer_key,
          o.order_id,
          o.line_num,
          o.part_key,
          'promise_slipped',
          jsonb_build_object('promise_date', p.promise_date),
          jsonb_build_object(
            'promise_date', o.promise_date,
            'days_later',   o.promise_date - p.promise_date,
            'backlog_qty',  o.backlog_qty
          ),
          today
      from public.order_line_snapshot p
      join erp.fact_order_line o
        on o.order_id = p.order_id
       and o.line_num = p.line_num
      where p.is_backlog_line
        and o.is_backlog_line
        and p.promise_date is not null
        and o.promise_date > p.promise_date;
      get diagnostics n = row_count;
      n_events := n_events + n;

      -- order_cancelled: the order's status became X. One row per order.
      insert into public.order_change_events
        (customer_key, order_id, kind, before, after, detected_on)
      select
          o.customer_key,
          o.order_id,
          'order_cancelled',
          jsonb_build_object(
            'order_status',    max(p.order_status),
            'open_line_count', count(*) filter (where p.is_backlog_line),
            'backlog_qty',     coalesce(sum(p.backlog_qty) filter (where p.is_backlog_line), 0)
          ),
          jsonb_build_object('order_status', 'X', 'bookings', coalesce(sum(o.bookings), 0)),
          today
      from public.order_line_snapshot p
      join erp.fact_order_line o
        on o.order_id = p.order_id
       and o.line_num = p.line_num
      where coalesce(p.order_status, '') <> 'X'
        and o.order_status = 'X'
      group by o.customer_key, o.order_id;
      get diagnostics n = row_count;
      n_events := n_events + n;
    end if;

    -- Replace the snapshot. TRUNCATE is fine here: no reader but this
    -- function, and it is part of the same rollback-able unit.
    truncate public.order_line_snapshot;

    insert into public.order_line_snapshot
      (order_id, line_num, customer_key, part_key, order_date, order_status,
       line_status, promise_date, desired_ship_date, is_backlog_line,
       backlog_qty, shipped_qty, snapped_on)
    select
        o.order_id, o.line_num, o.customer_key, o.part_key, o.order_date,
        o.order_status, o.line_status, o.promise_date, o.desired_ship_date,
        o.is_backlog_line, o.backlog_qty, o.total_shipped_qty_to_date, today
    from erp.fact_order_line o
    where o.is_backlog_line
       or o.order_date >= today - snapshot_days;
    get diagnostics n_rows = row_count;

    delete from public.order_change_events e
    where e.detected_on < today - keep_days;

  exception when others or query_canceled then
    -- Everything above rolled back as a unit: the snapshot is still last
    -- good night's, so tomorrow's diff covers both days.
    get stacked diagnostics err_state = returned_sqlstate,
                            err_message = message_text;
    begin
      perform public.log_job_run('etl:order_changes', 'error', null::bigint,
                                 err_state || ': ' || err_message, started);
    exception when others then
      raise warning 'capture_order_changes: could not log its own failure (%): %',
        sqlerrm, err_message;
    end;
    raise warning 'capture_order_changes failed and was skipped: % %', err_state, err_message;
    outcome := 'error';
    events := 0;
    snapshot_rows := 0;
    return next;
    return;
  end;

  begin
    perform public.log_job_run('etl:order_changes', 'success', n_events, null, started);
  exception when others then
    raise warning 'capture_order_changes: could not log its run: %', sqlerrm;
  end;

  outcome := case when prev_day is null then 'seeded' else 'captured' end;
  events := n_events;
  snapshot_rows := n_rows;
  return next;
end;
$$;

comment on function public.capture_order_changes() is
  'Nightly: diff erp.fact_order_line against public.order_line_snapshot, '
  'write public.order_change_events, replace the snapshot, keep 60 days. '
  'First run only seeds. Never raises — a failure is logged to job_runs as '
  'etl:order_changes and the function returns (''error'', 0, 0). One run '
  'at a time (it locks the snapshot first). An optional post_load_sql step '
  'in etl/views.yml. Job-only (20261013150003).';

-- Mountain time, like refresh_territory_rollups() (20260901190000): the
-- detected_on dates and the windows must not shift with the session.
alter function public.capture_order_changes() set timezone to 'America/Denver';

-- Job-only, per 017: a SECURITY DEFINER function no app role can reach.
revoke execute on function public.capture_order_changes()
  from public, anon, authenticated;

--------------------------------------------------------------------------
-- 4. View-as is read-only here too (same sweep as 20260901190200). The
--    snapshot is written only by the ETL (auth.uid() is null there, so
--    the trigger passes), but the sweep test requires the trigger on every
--    RLS-enabled public table, and a uniform rule beats an exception list.
--------------------------------------------------------------------------
do $$
declare
  t record;
begin
  for t in
    select tablename
    from pg_tables
    where schemaname = 'public'
      and rowsecurity
      and tablename not in ('impersonation', 'impersonation_events',
                            'login_events', 'job_runs')
    order by tablename
  loop
    execute format(
      'drop trigger if exists trg_%1$s_no_write_while_viewing_as on public.%1$I',
      t.tablename);
    execute format(
      'create trigger trg_%1$s_no_write_while_viewing_as '
      'before insert or update or delete on public.%1$I '
      'for each row execute function public.block_writes_while_impersonating()',
      t.tablename);
  end loop;
end;
$$;
