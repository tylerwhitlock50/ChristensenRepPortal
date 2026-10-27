/*============================================================================
  20261027090600_book_lists.sql — the two Tableau lists reps actually use,
  over the whole book (G03 + G04).

  Why
  ---
  Tableau's usage log (2026-10-26): outside reps open "My Open Orders"
  (3,316 opens) and "Shipment Details" (1,880) far more than anything else.
  The portal answers both questions only one account at a time. These two
  objects back the Sales Intel tabs /intel/open-orders and /intel/shipments.

  1. public.v_open_order_lines — every open order line in the caller's
     book, one row per line, with what the list filters and groups on.

       product_code   dim_part.product_code — the ERP product line,
                      Tableau's "Family" (UI: "Product line")
       program_code   fact_order_line.product_code — the ORDER line's code,
                      which carries programs as well as product lines:
                      MDF, SUNSET, DEALER EVENT, WARRANTY, ADVERTISING …
       is_rma         the dealer's PO says RMA, or the line is a WARRANTY
                      program line: returns and repairs, not sales. The UI
                      hides these by default. A substring match: of the 225
                      open lines it caught on 2026-10-26, one was a PO that
                      merely contains the letters (…CARMA…).
       is_non_part    the '(Unknown)' part (dim_part.is_unknown_part —
                      the one row the ERP uses for non-stock lines:
                      discounts, credits, charges)
       is_past_want   desired_ship_date (the ERP's "want date") is past
       is_past_promise promise_date is past (null promise = false)

     Open = fact_order_line.is_backlog_line, the one definition the
     rollups, v_backlog_by_sku and the account page already share (it
     reconciled to Tableau's open lines 2,493 of 2,493 on 2026-10-26).
     Released, Firmed and Hold lines; never a cancelled order.

  2. public.report_book_shipments(p_from, p_to, p_customer_key) — every
     shipment line in a date window, with the dealer's PO, the invoice
     and its status, tracking and the ship-to. shipped_value is the
     packlist value (20261027090300) — never revenue.

  Performance is the requirement
  ------------------------------
  The obvious query — shipment lines joined to their order lines for the
  PO, under RLS — timed out (8 s, the authenticated statement_timeout) for
  the PMI principal over "this year": the planner hash-joined the window's
  shipments to a sequential scan of all ~508k order lines, each one
  checked against the RLS predicate on the way. RLS is
  `is_admin() OR customer_key IN (my_customer_keys())` — an OR, so it never
  drives an index (see 030).

  So the function reads the window first and looks everything else up
  second, touching as few pages as it can (Micro compute's disk budget is
  what a cold call spends):
    - the window comes from fact_shipment_line through an index, in one of
      three UNION ALL arms, each gated on a constant test so only one runs:
        admin           by ship_date (idx_fsl_ship_date; the heap is ~0.98
                        correlated with ship_date, so a short sequential
                        read — ~25k lines for the whole company this year)
        rep / principal by (customer_key, ship_date) for each account of
                        my_customer_keys() (idx_fsl_customer_ship_date) —
                        only the book's own lines, the same rows RLS admits
        p_customer_key  the same index, one account
      RLS still applies on top of every arm;
    - the PO, the invoice status and the three dimensions are probed once
      per DISTINCT key in the window (orders, invoices, customers, parts,
      ship-tos), by primary key or index, never by joining whole tables.
  fact_invoice_line had no index usable for the invoice probe — its primary
  key LEADS with invoice_entity_id (a single value, 'TDJ', on 2026-10-26),
  and Postgres 17 has no skip scan — so this file adds idx_fil_invoice_id
  (invoice_id) INCLUDE (invoice_status_desc, customer_key): index-only for
  the probe and its RLS check. ~25 MB, maintained by the loader's writes
  like the fact's five other indexes.

  Measured with EXPLAIN ANALYZE as authenticated (statement_timeout 8 s,
  in rolled-back transactions) on 2026-10-26, steady state: the PMI
  principal (273 accounts) 65-72 ms for this year, last 365 days and 2025;
  the largest single-rep books 30-40 ms; an admin (the whole company,
  26k-38k lines) 0.4-0.6 s; v_open_order_lines unfiltered 18-52 ms — all
  under the 3 s target. A cold first call (right after the in-transaction
  index build, little cached) ran up to ~2 s for the principal and up to
  3.6 s for an admin's whole-company year: inside the 8 s timeout, but
  over the target until the pages are warm. Full table in the build report.

  The function is PL/pgSQL rather than SQL so it can refuse a missing or
  over-long window with a real error (an SQL function cannot RAISE), and so
  each call is planned with its actual dates. 400 days is a year plus a
  month of slack — "last 365 days" and "last year" both fit — and caps a
  single admin response at about 40k rows.

  Both are SECURITY INVOKER: RLS on every table read is the book, view-as
  aware through my_customer_keys(), exactly like the other v_* views.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Open order lines.
--------------------------------------------------------------------------
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
    coalesce(o.promise_date < current_date, false)            as is_past_promise
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
  'for the Sales Intel "Open orders" list (20261027090600). product_code = '
  'the part''s ERP product line; program_code = the order line''s own code '
  '(MDF, SUNSET, WARRANTY …). is_rma: PO mentions RMA or a WARRANTY line. '
  'is_non_part: the (Unknown) non-stock part (discounts, credits, '
  'charges). is_past_want / is_past_promise: desired ship / promise date '
  'before today (null date = false). backlog_amount is net of trade '
  'discount (the ERP''s open line value). security_invoker — query '
  'unfiltered, RLS is the territory filter.';

revoke all on public.v_open_order_lines from anon, public;
grant select on public.v_open_order_lines to authenticated;

--------------------------------------------------------------------------
-- 2. The index the invoice-status probe needs.
--------------------------------------------------------------------------
-- Covering: invoice_status_desc is what the probe returns and customer_key
-- is what the RLS policy tests, so the probe can be index-only. invoice_id
-- is (nearly) sequential, so this window's invoices sit together at the
-- end of the index — a few hot pages rather than one random heap page per
-- invoice across a 416 MB table whose physical order is unrelated
-- (pg_stats correlation of invoice_id: -0.004).
create index if not exists idx_fil_invoice_id
  on erp.fact_invoice_line (invoice_id)
  include (invoice_status_desc, customer_key);

--------------------------------------------------------------------------
-- 3. Shipment lines in a window.
--------------------------------------------------------------------------
-- New function; the drop lets a re-run replace an earlier draft whose OUT
-- columns differ (create or replace cannot change them).
drop function if exists public.report_book_shipments(date, date, text);

create or replace function public.report_book_shipments(
    p_from         date,
    p_to           date,
    p_customer_key text default null
)
returns table (
    packlist_id             text,
    line_num                int,
    ship_date               date,
    customer_key            text,
    customer_name           text,
    assigned_sales_rep_name text,
    order_id                text,
    order_line_no           int,
    customer_po_number      text,
    part_id                 text,
    part_description        text,
    product_code            text,
    shipped_qty             numeric,
    unit_price              numeric,
    trade_discount_pct      numeric,
    shipped_value           numeric,
    invoice_id              text,
    invoice_status          text,
    ship_via                text,
    tracking_number         text,
    ship_to_name            text,
    ship_to_city            text,
    ship_to_state           text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
begin
    if p_from is null or p_to is null then
        raise exception 'report_book_shipments: p_from and p_to are both required'
            using errcode = '22004';                       -- null_value_not_allowed
    end if;
    if p_to < p_from then
        raise exception 'report_book_shipments: p_to (%) is before p_from (%)', p_to, p_from
            using errcode = '22023';                       -- invalid_parameter_value
    end if;
    if p_to - p_from > 400 then
        raise exception 'report_book_shipments: % days is more than the 400-day limit',
                        p_to - p_from
            using errcode = '22023',
                  hint = 'Ask for a year at a time.';
    end if;

    return query
    with win as materialized (
        -- 1. An admin's book is the company: the window by ship date (the
        --    heap is ~0.98 correlated with ship_date, so this is a short,
        --    mostly sequential read).
        select s.packlist_id, s.line_num, s.ship_date, s.customer_key, s.order_id,
               s.order_line_no, s.part_key, s.ship_to_key, s.shipped_qty, s.shipped_qty_selling_um, s.unit_price,
               s.trade_discount_pct, s.invoice_id, s.ship_via,
               coalesce(s.tracking_number, s.waybill_number) as tracking_number
        from erp.fact_shipment_line s
        where p_customer_key is null
          and (select public.is_admin()) is true
          and s.ship_date between p_from and p_to
        union all
        -- 2. A rep's or principal's book: one (customer_key, ship_date)
        --    range of idx_fsl_customer_ship_date per account, so only the
        --    book's own lines are read, not the company's window. These are
        --    exactly the rows RLS admits for a non-admin
        --    (my_customer_keys(), view-as aware), and RLS still applies on
        --    top. A caller with no JWT at all (SQL editor) gets nothing here;
        --    pass p_customer_key, or ask as an admin.
        select s.packlist_id, s.line_num, s.ship_date, s.customer_key, s.order_id,
               s.order_line_no, s.part_key, s.ship_to_key, s.shipped_qty, s.shipped_qty_selling_um, s.unit_price,
               s.trade_discount_pct, s.invoice_id, s.ship_via,
               coalesce(s.tracking_number, s.waybill_number)
        from erp.fact_shipment_line s
        where p_customer_key is null
          and (select public.is_admin()) is not true
          and s.customer_key = any (array(select public.my_customer_keys()))
          and s.ship_date between p_from and p_to
        union all
        -- 3. One account: the same index, one range.
        select s.packlist_id, s.line_num, s.ship_date, s.customer_key, s.order_id,
               s.order_line_no, s.part_key, s.ship_to_key, s.shipped_qty, s.shipped_qty_selling_um, s.unit_price,
               s.trade_discount_pct, s.invoice_id, s.ship_via,
               coalesce(s.tracking_number, s.waybill_number)
        from erp.fact_shipment_line s
        where p_customer_key is not null
          and s.customer_key = p_customer_key
          and s.ship_date between p_from and p_to
        -- The arms are exclusive; each is gated on a constant test (a
        -- one-time filter), so only one ever reads the fact.
    ),
    po as (
        -- The dealer's PO: one primary-key probe per ORDER in the window,
        -- not per line (25.7k lines but 9.5k orders company-wide this
        -- year). The shipment fact has no PO column, and the PO is a
        -- header value — the same on every line of an order (0 exceptions
        -- on 2026-10-26) — so any line of the order answers.
        select d.order_id,
               (select nullif(o.customer_po_number, '')
                  from erp.fact_order_line o
                 where o.order_id = d.order_id
                 limit 1) as customer_po_number
        from (select distinct w.order_id from win w) d
    ),
    inv as (
        -- Open / Closed / Void, once per invoice, from the covering index
        -- below (index-only: the probe never touches the fact's heap, which
        -- is in no useful order by invoice). The same on every line of an
        -- invoice (0 exceptions on 2026-10-26).
        select d.invoice_id,
               (select f.invoice_status_desc
                  from erp.fact_invoice_line f
                 where f.invoice_id = d.invoice_id
                 limit 1) as invoice_status
        from (select distinct w.invoice_id from win w where w.invoice_id is not null) d
    ),
    -- The dimensions, one key probe per distinct key in the window. A plain
    -- join would let the planner hash-join whole dimension tables (~8k
    -- pages for dim_customer + dim_part + dim_ship_to) for a book of a few
    -- hundred accounts; on Micro compute's disk budget that read is most of
    -- a cold call. `limit 1` keeps each probe a parameterised index lookup.
    cust as (
        select d.customer_key, x.customer_name, x.assigned_sales_rep_name
        from (select distinct w.customer_key from win w) d
        left join lateral (
            select c.customer_name, c.assigned_sales_rep_name
            from erp.dim_customer c
            where c.customer_key = d.customer_key
            limit 1
        ) x on true
    ),
    part as (
        select d.part_key, x.part_id, x.part_description, x.product_code
        from (select distinct w.part_key from win w where w.part_key is not null) d
        left join lateral (
            select p.part_id, p.part_description, p.product_code
            from erp.dim_part p
            where p.part_key = d.part_key
            limit 1
        ) x on true
    ),
    shipto as (
        select d.ship_to_key, x.ship_to_name, x.city, x.state
        from (select distinct w.ship_to_key from win w where w.ship_to_key is not null) d
        left join lateral (
            select st.ship_to_name, st.city, st.state
            from erp.dim_ship_to st
            where st.ship_to_key = d.ship_to_key
            limit 1
        ) x on true
    )
    select
        w.packlist_id,
        w.line_num,
        w.ship_date,
        w.customer_key,
        cust.customer_name,
        cust.assigned_sales_rep_name,
        w.order_id,
        w.order_line_no,
        po.customer_po_number,
        part.part_id,
        part.part_description,
        part.product_code,
        w.shipped_qty,
        w.unit_price,
        w.trade_discount_pct,
        -- Packlist value, the v_account_shipment_lines expression
        -- (20261027090300). Never revenue: revenue is invoiced.
        (coalesce(w.shipped_qty_selling_um, w.shipped_qty) * w.unit_price
            * (100 - coalesce(w.trade_discount_pct, 0)) / 100)::numeric,
        w.invoice_id,
        inv.invoice_status,
        w.ship_via,
        w.tracking_number,
        shipto.ship_to_name,
        shipto.city,
        shipto.state
    from win w
    left join po     on po.order_id       = w.order_id
    left join inv    on inv.invoice_id    = w.invoice_id
    left join cust   on cust.customer_key = w.customer_key
    left join part   on part.part_key     = w.part_key
    left join shipto on shipto.ship_to_key = w.ship_to_key
    order by w.ship_date desc, w.packlist_id desc, w.line_num;
end;
$$;

comment on function public.report_book_shipments(date, date, text) is
  'Every shipment line shipped p_from..p_to (inclusive; both required; at '
  'most 400 days apart) in the caller''s book, or in one account with '
  'p_customer_key, newest first, for the Sales Intel "Shipments" list '
  '(20261027090600). Carries the dealer''s PO (from the order line), the '
  'part''s product line (product_code), shipped_value (qty × price net of '
  'trade discount — the packlist value, never revenue), the invoice and '
  'its status (Open / Closed / Void), tracking (line value, waybill '
  'fallback) and the ship-to. SECURITY INVOKER: RLS is the book.';

revoke execute on function public.report_book_shipments(date, date, text) from public, anon;
grant execute on function public.report_book_shipments(date, date, text) to authenticated;
