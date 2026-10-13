/*============================================================================
  20261013150000_order_lines_tracking.sql — each order line says how it
  shipped.

  Why
  ---
  The Lookup page now opens an order's lines in place ("which guns are
  still open?"). A dealer asking about a split order wants the tracking
  number for the part that DID ship, and the order-level list on the result
  card cannot say which parcel carried which line. The shipment fact knows:
  fact_shipment_line carries (order_id, order_line_no) since 002.

  What
  ----
  public.v_account_order_lines gains `tracking_numbers text`, APPENDED LAST
  (column 17). Every existing column keeps its name, type and position, so
  create-or-replace is legal and the deployed callers are untouched: the
  account drill-in and the frontend select '*' and map by name, the MCP
  list_orders tool names its columns explicitly.

  The value is every distinct tracking number on shipment lines for that
  order line, line tracking preferred over the packlist waybill (the 032
  rule), comma-joined in a stable order. NULL when the line has not shipped
  or shipped with no number (will-call).

  ── 035's no-fact-to-fact-measure rule ─────────────────────────────────────
  The shipment side is a correlated scalar subquery that returns TEXT and
  nothing else. No shipment measure (qty, revenue) is read through it, so no
  order-line measure can fan out or double count. Keep it that way: shipped
  quantities on this view come from fact_order_line.total_shipped_qty_to_date
  (already column 16), never from summing shipment lines here.

  Cost: the view is always read with .eq(customer_key).eq(order_id) — a
  handful of lines — and each subquery is an index probe on idx_fsl_order
  (035). A caller that does not select tracking_numbers (MCP list_orders)
  does not evaluate it: the view is flattened into the outer query and an
  unreferenced output column is dropped. security_invoker as before, so the
  shipment fact's RLS applies inside the subquery too.
============================================================================*/

create or replace view public.v_account_order_lines
with (security_invoker = true)
as
select
    o.customer_key,
    o.order_id,
    o.line_num,
    o.order_date,
    o.promise_date,
    o.line_status_desc,
    o.part_key,
    p.part_id,
    p.part_description,
    o.order_qty,
    o.bookings,
    o.backlog_qty,
    o.is_backlog_line,
    nullif(o.customer_po_number, '')                            as customer_po_number,
    o.desired_ship_date,
    -- Semi-additive on the line (cumulative to date), so it is exposed as a
    -- per-line value for display and must never be summed across lines.
    o.total_shipped_qty_to_date,
    -- NEW, appended: text only — see the header on the fact-to-fact rule.
    (
        select nullif(string_agg(distinct t.n, ', ' order by t.n), '')
        from (
            select coalesce(nullif(s.tracking_number, ''),
                            nullif(s.waybill_number, '')) as n
            from erp.fact_shipment_line s
            where s.order_id      = o.order_id
              and s.order_line_no = o.line_num
        ) t
        where t.n is not null
    )                                                           as tracking_numbers
from erp.fact_order_line o
left join erp.dim_part p on p.part_key = o.part_key;

comment on view public.v_account_order_lines is
  'All lines of one order for the account drill-in modal and the Lookup '
  'line list. security_invoker. Always query with .eq(customer_key) AND '
  '.eq(order_id) — order_id leads the fact table''s primary key. '
  'total_shipped_qty_to_date is SEMI-ADDITIVE (cumulative on the line): '
  'display it, never sum it across lines. tracking_numbers (20261013150000, '
  'last column) is text from the shipment lines of that order line — never '
  'add a shipment measure beside it.';

-- create or replace keeps grants; restated so this file stands alone.
revoke all on public.v_account_order_lines from anon, public;
grant select on public.v_account_order_lines to authenticated;
