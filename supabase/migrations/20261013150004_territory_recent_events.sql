/*============================================================================
  20261013150004_territory_recent_events.sql — the Overview's "Recent
  activity" says what shipped and what slipped, not only what was ordered.

  Why
  ---
  The card read v_territory_recent_orders (029): new orders, 14 days, and
  nothing else. The PRD's activity feed is new orders AND shipments, and
  the two things a rep most wants to hear before the dealer does — a
  backorder went out, a promise date moved — now exist as rows in
  order_change_events (20261013150003).

  What
  ----
  public.v_territory_recent_events, security_invoker: one row per event in
  the last 14 days across the caller's book, newest first by the client's
  .order(). RLS on each underlying table is the territory filter, exactly
  as for v_territory_recent_orders — the client never filters by owner.

    kind               source                                    grain
    order_new          erp.fact_order_line, order_date in window  order
    shipped            erp.fact_shipment_line, ship_date          packlist × order
    backorder_shipped  order_change_events                        order line
    promise_slipped    order_change_events                        order line

  Same territory definition as 029/025: active external accounts only.
  Each branch reads its own fact and nothing is joined fact-to-fact, so no
  measure can fan out: amount is bookings for an order, shipped revenue for
  a shipment, null for an event.

  Columns (one shape for every kind; null where a kind has nothing):
    customer_key, customer_name, kind, occurred_on, order_id,
    customer_po_number, packlist_id, line_no, part_id, part_description,
    amount, qty, line_count, tracking_numbers, ship_via,
    promise_before, promise_after, has_backlog, event_id

  The frontend falls back to v_territory_recent_orders when this view (or
  order_change_events) is missing, so it ships safely ahead of the
  migration. Backward compatible: a new view; nothing existing changes.
============================================================================*/

create or replace view public.v_territory_recent_events
with (security_invoker = true)
as
-- New orders, one row per order (the 029 shape, plus the PO).
select
    o.customer_key,
    c.customer_name,
    'order_new'::text                                       as kind,
    max(o.order_date)                                       as occurred_on,
    o.order_id,
    nullif(string_agg(distinct nullif(o.customer_po_number, ''), ', '), '')
                                                            as customer_po_number,
    null::text                                              as packlist_id,
    null::int                                               as line_no,
    null::text                                              as part_id,
    null::text                                              as part_description,
    coalesce(sum(o.bookings), 0)::numeric                   as amount,
    coalesce(sum(o.order_qty), 0)::numeric                  as qty,
    count(*)::int                                           as line_count,
    null::text                                              as tracking_numbers,
    null::text                                              as ship_via,
    null::date                                              as promise_before,
    null::date                                              as promise_after,
    bool_or(o.is_backlog_line)                              as has_backlog,
    null::bigint                                            as event_id
from erp.fact_order_line o
join erp.dim_customer c on c.customer_key = o.customer_key
where o.order_date >= current_date - 14
  and coalesce(o.order_status, '') <> 'X'
  and c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y'
group by o.customer_key, c.customer_name, o.order_id

union all

-- Shipments, one row per packlist and order (a packlist rarely carries two
-- orders; when it does, each order gets its own row and its own link).
-- Tracking prefers the line number over the packlist waybill (032).
select
    s.customer_key,
    c.customer_name,
    'shipped'::text,
    max(s.ship_date),
    s.order_id,
    null::text,
    s.packlist_id,
    null::int,
    null::text,
    null::text,
    coalesce(sum(s.shipped_revenue), 0)::numeric,
    coalesce(sum(s.shipped_qty), 0)::numeric,
    count(*)::int,
    nullif(string_agg(distinct coalesce(nullif(s.tracking_number, ''),
                                        nullif(s.waybill_number, '')), ', '), ''),
    max(s.ship_via),
    null::date,
    null::date,
    null::boolean,
    null::bigint
from erp.fact_shipment_line s
join erp.dim_customer c on c.customer_key = s.customer_key
where s.ship_date >= current_date - 14
  and c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y'
group by s.customer_key, c.customer_name, s.packlist_id, s.order_id

union all

-- What the nightly capture noticed. Only the two kinds the card calls out;
-- plain shipments are covered above with their tracking.
select
    e.customer_key,
    c.customer_name,
    e.kind,
    e.detected_on,
    e.order_id,
    null::text,
    null::text,
    e.line_no,
    p.part_id,
    p.part_description,
    null::numeric,
    case
      when e.kind = 'backorder_shipped' then (e.after ->> 'shipped_now')::numeric
      else (e.after ->> 'backlog_qty')::numeric
    end,
    null::int,
    e.after ->> 'tracking_numbers',
    null::text,
    (e.before ->> 'promise_date')::date,
    (e.after  ->> 'promise_date')::date,
    null::boolean,
    e.id
from public.order_change_events e
join erp.dim_customer c on c.customer_key = e.customer_key
left join erp.dim_part p on p.part_key = e.part_key
where e.detected_on >= current_date - 14
  and e.kind in ('backorder_shipped', 'promise_slipped')
  and c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

comment on view public.v_territory_recent_events is
  'The Overview activity feed: new orders, shipments (with tracking), '
  'backorders shipped and promise dates slipped, last 14 days, active '
  'external accounts in the caller''s book. One row per event; see the '
  'migration header for the columns each kind fills. security_invoker — '
  'query unfiltered, RLS is the territory filter (20261013150004).';

revoke all on public.v_territory_recent_events from anon, public;
grant select on public.v_territory_recent_events to authenticated;
