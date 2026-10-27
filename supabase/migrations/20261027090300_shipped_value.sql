/*============================================================================
  20261027090300_shipped_value.sql — shipment dollars as the packlist
  values them (G05).

  Why
  ---
  Tyler's rule (2026-10-26): revenue counts only once invoiced; shipping can
  packlist ahead of invoicing; "we don't reward people writing an order".
  So a shipment's dollars are never revenue — they are the value of what
  went out the door, the figure Tableau's Shipment Details shows.

  The portal's shipment views carried only `shipped_revenue`, the ERP's
  revenue recognised against the shipper line (bi.vw_FactShipmentLine).
  It differs from what the packlist was worth: for Midway USA, 2025's 343
  packlist lines are worth $442,975.01 at their order price net of trade
  discount, while shipped_revenue sums to $440,203.05. The rep-facing
  number is the packlist value:

      shipped_value = shipped_qty_selling_um × unit_price × (100 − trade_discount_pct) / 100

  unit_price is per SELLING unit, so the selling-UM quantity is the one
  it multiplies (shipped_qty where that is null). The two differ on 13 of
  ~495k lines. bi.vw_FactShipmentLine restated shipped_revenue to this
  same expression on 2026-10-26 (20261026181500); shipped_value keeps the
  portal's figure defined here rather than by whatever that column means
  next.

  (trade_discount_pct is a percent; null = no discount). unit_price and
  trade_discount_pct are the shipper line's own, landed since 002 and
  outside the fact's revoked cost columns (20260901190300).

  What (all append-only; create-or-replace keeps every existing column's
  name, type and position)
  ----
    v_account_shipment_lines           + shipped_value per line
    v_account_recent_shipment_headers  + shipped_value summed per packlist
    v_territory_recent_events          + shipped_value on 'shipped' rows;
                                         null for order_new, and for the
                                         order_change_events kinds
                                         (backorder_shipped carries a qty
                                         from the capture, not a price —
                                         the same reason its amount is
                                         null)
  shipped_revenue and amount are unchanged: callers that read them keep
  their numbers; the UI switches its label and figure to shipped_value.

  Each body is restated from LIVE (pg_get_viewdef on 2026-10-26), which is
  identical to its latest migration: 032_tracking_ats_contacts_reporting.sql
  (lines), 035_order_lookup.sql (headers, uncapped), and
  20261013150004_territory_recent_events.sql. The headers view is written
  with explicit column lists instead of 035's `select *` / `h.*`, because a
  new inner column would otherwise land in front of `rn`.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Lines.
--------------------------------------------------------------------------
create or replace view public.v_account_shipment_lines
with (security_invoker = true)
as
select
    s.customer_key,
    s.packlist_id,
    s.line_num,
    s.order_id,
    s.invoice_id,
    s.ship_date,
    s.actual_delivery_date,
    s.part_key,
    p.part_id,
    p.part_description,
    s.shipped_qty,
    s.shipped_revenue,
    coalesce(s.tracking_number, s.waybill_number) as tracking_number,
    -- Packlist value, never "revenue". Unrounded per line so a packlist or
    -- a year sums to the cent; the UI rounds for display.
    (coalesce(s.shipped_qty_selling_um, s.shipped_qty) * s.unit_price
        * (100 - coalesce(s.trade_discount_pct, 0)) / 100)::numeric
                                                  as shipped_value
from erp.fact_shipment_line s
left join erp.dim_part p on p.part_key = s.part_key;

comment on view public.v_account_shipment_lines is
  'All lines of one packlist for the account drill-in modal, each with its '
  'own tracking number (waybill fallback). shipped_value = selling-UM qty × '
  'unit_price net of trade discount — the packlist value, which is NOT '
  'revenue (revenue is invoiced; 20261027090300). security_invoker. Always '
  'query with .eq(customer_key) AND .eq(packlist_id) — packlist_id leads the '
  'fact table''s primary key.';

--------------------------------------------------------------------------
-- 2. Packlist headers.
--------------------------------------------------------------------------
create or replace view public.v_account_recent_shipment_headers
with (security_invoker = true)
as
select
    r.customer_key,
    r.packlist_id,
    r.ship_date,
    r.actual_delivery_date,
    r.shipment_state,
    r.shipper_status_desc,
    r.tracking_number,
    r.ship_via,
    r.order_ids,
    r.line_count,
    r.shipped_qty,
    r.shipped_revenue,
    r.rn,
    r.shipped_value
from (
    select
        h.customer_key,
        h.packlist_id,
        h.ship_date,
        h.actual_delivery_date,
        h.shipment_state,
        h.shipper_status_desc,
        h.tracking_number,
        h.ship_via,
        h.order_ids,
        h.line_count,
        h.shipped_qty,
        h.shipped_revenue,
        h.shipped_value,
        row_number() over (
            partition by h.customer_key
            order by h.ship_date desc nulls last, h.packlist_id desc
        ) as rn
    from (
        select
            s.customer_key,
            s.packlist_id,
            max(s.ship_date)                                    as ship_date,
            max(s.actual_delivery_date)                         as actual_delivery_date,
            max(s.shipment_state)                               as shipment_state,
            max(s.shipper_status_desc)                          as shipper_status_desc,
            coalesce(max(s.tracking_number), max(s.waybill_number))
                                                                as tracking_number,
            max(s.ship_via)                                     as ship_via,
            string_agg(distinct s.order_id, ', ')               as order_ids,
            count(*)::int                                       as line_count,
            coalesce(sum(s.shipped_qty), 0)::numeric            as shipped_qty,
            coalesce(sum(s.shipped_revenue), 0)::numeric        as shipped_revenue,
            -- Same per-line expression as v_account_shipment_lines, so a
            -- header always equals the sum of its drill-in.
            coalesce(sum(coalesce(s.shipped_qty_selling_um, s.shipped_qty) * s.unit_price
                         * (100 - coalesce(s.trade_discount_pct, 0)) / 100), 0)::numeric
                                                                as shipped_value
        from erp.fact_shipment_line s
        group by s.customer_key, s.packlist_id
    ) h
) r;

comment on view public.v_account_recent_shipment_headers is
  'Every packlist for an account at header grain, newest first — `rn` is '
  'the recency rank. UNCAPPED as of 035; the caller pages with .range(). '
  'tracking_number prefers the line-level value and falls back to the '
  'packlist waybill. shipped_value is the packlist value (qty × price net '
  'of trade discount, 20261027090300) — not revenue. security_invoker. '
  'Always query with .eq(customer_key).';

--------------------------------------------------------------------------
-- 3. The Overview activity feed.
--------------------------------------------------------------------------
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
    null::bigint                                            as event_id,
    null::numeric                                           as shipped_value
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
    (select nullif(string_agg(distinct nullif(o.customer_po_number, ''), ', '), '')
       from erp.fact_order_line o
      where o.order_id = s.order_id),
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
    null::bigint,
    -- The packlist value of this packlist × order (20261027090300).
    coalesce(sum(coalesce(s.shipped_qty_selling_um, s.shipped_qty) * s.unit_price
                 * (100 - coalesce(s.trade_discount_pct, 0)) / 100), 0)::numeric
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
    (select nullif(string_agg(distinct nullif(o.customer_po_number, ''), ', '), '')
       from erp.fact_order_line o
      where o.order_id = e.order_id),
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
    e.id,
    null::numeric
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
  'migration header for the columns each kind fills. shipped_value (the '
  'packlist value, 20261027090300) is set on kind = shipped only; amount '
  'keeps its meaning. security_invoker — query unfiltered, RLS is the '
  'territory filter (20261013150004).';

revoke all on public.v_account_shipment_lines          from anon, public;
revoke all on public.v_account_recent_shipment_headers from anon, public;
revoke all on public.v_territory_recent_events         from anon, public;
grant select on public.v_account_shipment_lines          to authenticated;
grant select on public.v_account_recent_shipment_headers to authenticated;
grant select on public.v_territory_recent_events         to authenticated;
