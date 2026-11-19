/*============================================================================
  20261119130000_open_order_lines_chambering.sql — chambering on the open
  order lines, so one read feeds both cuts of the Open orders tab.

  Why
  ---
  Sales Intel had two tabs over the same rows (erp.fact_order_line where
  is_backlog_line): "Open orders" (v_open_order_lines, one row per line) and
  "Backlog" (v_backlog_by_sku, those lines summed by account and SKU). They
  treated RMA/warranty lines differently by default, so their quantities
  disagreed and each page carried a paragraph explaining the other.

  The two are now one tab with a By order / By SKU switch. The by-SKU cut is
  added up in the browser from the same filtered lines (lib/bookLists.ts,
  rollupOpenOrdersBySku), so the two cuts cannot disagree. The one thing the
  Backlog grid showed that a line did not carry is the part's chambering.

  What
  ----
  v_open_order_lines restated from LIVE (pg_get_viewdef on 2026-11-19 =
  20261027090600_book_lists.sql, 30 columns) with dim_part.chambering
  appended last. No join, filter or grain change: still one row per open
  line. chambering is outside dim_part's revoked cost columns
  (20260901190300); v_backlog_by_sku has exposed it since 025.

  v_backlog_by_sku is untouched: the account page's card, the MCP
  list_backlog tool and the AI account context still read it.

  Replay-safe (create or replace; privileges and security_invoker carry
  over, and are restated below anyway).
============================================================================*/

create or replace view public.v_open_order_lines
with (security_invoker = true)
as
select
    o.customer_key,
    c.customer_id,
    c.customer_name,
    c.customer_reporting_name,
    c.assigned_sales_rep_id,
    c.assigned_sales_rep_name,
    o.order_id,
    o.line_num,
    o.order_date,
    nullif(o.customer_po_number, '')                          as customer_po_number,
    o.order_status,
    o.order_status_desc,
    o.desired_ship_date,
    o.promise_date,
    o.part_key,
    p.part_id,
    p.part_description,
    p.product_code,
    p.product_family,
    p.upc,
    nullif(o.product_code, '')                                as program_code,
    o.unit_price,
    o.trade_discount_pct,
    o.backlog_qty,
    o.backlog_amount,
    c.credit_status,
    coalesce(o.customer_po_number ilike '%rma%', false)
      or coalesce(o.product_code = 'WARRANTY', false)         as is_rma,
    coalesce(o.part_key = '(Unknown)', false)
      or coalesce(p.is_unknown_part, false)                   as is_non_part,
    coalesce(o.desired_ship_date < current_date, false)       as is_past_want,
    coalesce(o.promise_date < current_date, false)            as is_past_promise,
    p.chambering
from erp.fact_order_line o
-- Left joins: an open line is never dropped for a missing dimension row
-- (RLS on the customer is the same book as on the line, so a rep never
-- sees a line without its account).
left join erp.dim_customer c on c.customer_key = o.customer_key
left join erp.dim_part     p on p.part_key     = o.part_key
where o.is_backlog_line;

comment on view public.v_open_order_lines is
  'Every open order line (fact_order_line.is_backlog_line: Released, '
  'Firmed, Hold; never cancelled) in the caller''s book, one row per line, '
  'for the Sales Intel "Open orders" tab (20261027090600), which shows them '
  'by order or added up by SKU (20261119130000). product_code = the part''s '
  'ERP product line; program_code = the order line''s own code (MDF, SUNSET, '
  'WARRANTY …). is_rma: PO mentions RMA or a WARRANTY line. is_non_part: the '
  '(Unknown) non-stock part (discounts, credits, charges). is_past_want / '
  'is_past_promise: desired ship / promise date before today (null date = '
  'false). backlog_amount is net of trade discount (the ERP''s open line '
  'value). chambering = the part''s (20261119130000). security_invoker — '
  'query unfiltered, RLS is the territory filter.';

revoke all on public.v_open_order_lines from anon, public;
grant select on public.v_open_order_lines to authenticated;
