/*============================================================================
  035_order_lookup.sql
  Purpose: Let a rep answer "where's my order?" — the most common call they
           take — without phoning inside sales.

  Three changes:

  1. customer_po_number reaches the UI.
     It has been landed on erp.fact_order_line since 002 and shown nowhere.
     The dealer says "PO 44182"; until now the rep had no way to look that
     up, because the portal only ever knew orders by OUR order number.

  2. The 20-row cap moves out of the order/shipment header views.
     018 wrote `where r.rn <= 20` into the view, so an account's 21st-most-
     recent order was unreachable by any query — no paging, no search, no
     way through. The cap belongs in the caller (v_account_list is paged
     exactly this way), so the views become uncapped and the client sends
     .range(). `rn` stays in the output and is now useful: it is the
     recency rank the client pages on.

     No column is added, removed, reordered or retyped, so create-or-replace
     is legal and existing callers keep compiling. They DO need to start
     sending a range — an unbounded select now returns every order rather
     than 20 — and useAccountMetrics.ts does so in the same commit.

  3. public.lookup_orders(text) — cross-account lookup by order number,
     dealer PO number, or tracking number.

  ── Why lookup_orders is a FUNCTION and not a view ─────────────────────────
  The obvious shape is a view that rolls orders to header grain and exposes
  po/tracking columns to filter on. It performs terribly: the search columns
  only exist AFTER aggregation, so no predicate can be pushed into the
  GROUP BY and every lookup aggregates the caller's entire order history —
  for an admin, all ~501k order lines and ~529k shipment lines.

  A function takes the term as an argument, so the filter is applied to the
  base tables FIRST and only matching orders are ever rolled up. Same rows,
  bounded work.

  It is SECURITY INVOKER, not DEFINER: RLS on erp.fact_order_line /
  fact_shipment_line / dim_customer is the territory filter, exactly as in
  011/018/025. A DEFINER function here would be a second, hand-maintained
  copy of the access rules — the thing 010's rewrite exists to avoid.
  report_global_product_sales is DEFINER only because it deliberately serves
  company-wide aggregates that no rep's RLS would allow; this serves the
  caller's own book and must not bypass anything.

  ── The fact-to-fact join, and why it is not one ───────────────────────────
  Tracking numbers live on the shipment fact and order/PO numbers on the
  order fact. The sales semantic model's golden rule #2 forbids joining one
  fact to another — because measures fan out and double-count.

  Nothing here crosses that line: the shipment side is aggregated to order
  grain in its own subquery and contributes ONLY text (tracking numbers) and
  a max(ship_date). No measure — not bookings, not backlog, not revenue —
  is read through the join, so there is no grain to smear. Do not add one:
  if this view ever needs shipped dollars, they must come from a separate
  aggregate keyed the same way, never from widening this join.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Supporting indexes for the lookup's filters.
--    Partial: the vast majority of rows have no PO / no tracking number,
--    and there is no reason to index the NULLs.
--------------------------------------------------------------------------
create index if not exists idx_fol_po_number
  on erp.fact_order_line (customer_po_number)
  where customer_po_number is not null;

create index if not exists idx_fsl_tracking
  on erp.fact_shipment_line (tracking_number)
  where tracking_number is not null;

create index if not exists idx_fsl_order
  on erp.fact_shipment_line (order_id)
  where order_id is not null;

--------------------------------------------------------------------------
-- 2. Order headers — uncapped, plus the dealer's PO number.
--
--    An order can carry different PO numbers on different lines (a dealer
--    consolidating two POs onto one order), so this is a distinct string_agg
--    rather than a max(): showing one of two PO numbers is how a rep tells a
--    dealer their PO never arrived when it did.
--------------------------------------------------------------------------
--    Column ORDER matters here and is easy to get wrong. 018 wrote the outer
--    layer as `select h.*, row_number() … as rn`, which puts rn LAST. Adding
--    the two new columns to the inner subquery would therefore slot them in
--    BEFORE rn and rename that position — create-or-replace rejects it
--    ("cannot change name of view column rn to customer_po_number").
--    So the outer layer now lists its columns explicitly: the original
--    twelve, then rn in its existing thirteenth position, then the new two.
create or replace view public.v_account_recent_order_headers
with (security_invoker = true)
as
select
    h.customer_key,
    h.order_id,
    h.order_date,
    h.order_state,
    h.order_status_desc,
    h.line_count,
    h.order_qty,
    h.bookings,
    h.open_line_count,
    h.backlog_qty,
    h.backlog_amount,
    h.next_promise_date,
    row_number() over (
        partition by h.customer_key
        order by h.order_date desc nulls last, h.order_id desc
    ) as rn,
    h.customer_po_number,
    h.next_desired_ship_date
from (
        select
            o.customer_key,
            o.order_id,
            max(o.order_date)                                   as order_date,
            max(o.order_state)                                  as order_state,
            max(o.order_status_desc)                            as order_status_desc,
            count(*)::int                                       as line_count,
            coalesce(sum(o.order_qty), 0)::numeric              as order_qty,
            coalesce(sum(o.bookings), 0)::numeric               as bookings,
            count(*) filter (where o.is_backlog_line)::int      as open_line_count,
            coalesce(sum(o.backlog_qty)    filter (where o.is_backlog_line), 0)::numeric as backlog_qty,
            coalesce(sum(o.backlog_amount) filter (where o.is_backlog_line), 0)::numeric as backlog_amount,
            -- Next date the account is owed something — the rep's "when".
            min(o.promise_date) filter (where o.is_backlog_line) as next_promise_date,
            -- NEW, appended: the dealer's own paperwork number, and the
            -- production date the backlog page already shows reps.
            nullif(string_agg(distinct nullif(o.customer_po_number, ''), ', '), '')
                                                                as customer_po_number,
            min(o.desired_ship_date) filter (where o.is_backlog_line)
                                                                as next_desired_ship_date
        from erp.fact_order_line o
        group by o.customer_key, o.order_id
) h;

comment on view public.v_account_recent_order_headers is
  'Every order for an account at header grain (lines rolled up), newest '
  'first — `rn` is the recency rank. UNCAPPED as of 035: the caller pages '
  'with .range(), so older orders are reachable. security_invoker. Always '
  'query with .eq(customer_key) — it is the GROUP BY and PARTITION BY '
  'column, so the predicate reaches the index. Lines for one order come '
  'from v_account_order_lines.';

--------------------------------------------------------------------------
-- 3. Shipment headers — uncapped, same reasoning. Body otherwise identical
--    to 032's (tracking_number prefers the line value over the header
--    waybill); only the trailing `where r.rn <= 20` is gone.
--------------------------------------------------------------------------
create or replace view public.v_account_recent_shipment_headers
with (security_invoker = true)
as
select *
from (
    select
        h.*,
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
            coalesce(sum(s.shipped_revenue), 0)::numeric        as shipped_revenue
        from erp.fact_shipment_line s
        group by s.customer_key, s.packlist_id
    ) h
) r;

comment on view public.v_account_recent_shipment_headers is
  'Every packlist for an account at header grain, newest first — `rn` is '
  'the recency rank. UNCAPPED as of 035; the caller pages with .range(). '
  'tracking_number prefers the line-level value and falls back to the '
  'packlist waybill. security_invoker. Always query with .eq(customer_key).';

--------------------------------------------------------------------------
-- 4. Order lines — the drill-in modal gains the PO number and the ERP's
--    desired ship date ("est. production", the label BacklogIntel already
--    uses for min(desired_ship_date)).
--
--    Appended last: create-or-replace fixes the position of every column
--    above.
--------------------------------------------------------------------------
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
    o.total_shipped_qty_to_date
from erp.fact_order_line o
left join erp.dim_part p on p.part_key = o.part_key;

comment on view public.v_account_order_lines is
  'All lines of one order for the account drill-in modal. security_invoker. '
  'Always query with .eq(customer_key) AND .eq(order_id) — order_id leads '
  'the fact table''s primary key. total_shipped_qty_to_date is SEMI-ADDITIVE '
  '(cumulative on the line): display it, never sum it across lines.';

--------------------------------------------------------------------------
-- 5. public.lookup_orders(text) — the cross-account lookup.
--------------------------------------------------------------------------
create or replace function public.lookup_orders(p_term text, p_limit int default 25)
returns table (
    customer_key           text,
    customer_id            text,
    customer_name          text,
    order_id               text,
    order_date             date,
    order_state            text,
    order_status_desc      text,
    customer_po_number     text,
    line_count             int,
    bookings               numeric,
    open_line_count        int,
    backlog_amount         numeric,
    next_promise_date      date,
    next_desired_ship_date date,
    tracking_numbers       text,
    last_ship_date         date,
    /* Which field the term hit, so the UI can say WHY a row matched rather
       than leaving the rep to guess. */
    matched_on             text
)
language sql
stable
security invoker
-- Hardening per 017: search_path pinned to '', body fully schema-qualified.
set search_path = ''
as $$
    with term as (
        select nullif(btrim(p_term), '') as t
    ),
    -- Filter the BASE tables, before any aggregation. This is the whole
    -- reason this is a function; see the header.
    hit_orders as (
        select distinct o.customer_key, o.order_id,
               case
                   when o.order_id ilike '%' || (select t from term) || '%'
                       then 'order'
                   else 'po'
               end as matched_on
        from erp.fact_order_line o, term
        where term.t is not null
          and (o.order_id ilike '%' || term.t || '%'
               or o.customer_po_number ilike '%' || term.t || '%')
    ),
    hit_shipments as (
        select distinct s.customer_key, s.order_id, 'tracking'::text as matched_on
        from erp.fact_shipment_line s, term
        where term.t is not null
          and s.order_id is not null
          and coalesce(s.tracking_number, s.waybill_number) ilike '%' || term.t || '%'
    ),
    hits as (
        -- An order matched from both sides keeps one row. min() over the
        -- labels is arbitrary but stable; 'order' sorts before 'po' before
        -- 'tracking', which is also the order of specificity a rep expects.
        select h.customer_key, h.order_id, min(h.matched_on) as matched_on
        from (
            select * from hit_orders
            union all
            select * from hit_shipments
        ) h
        group by h.customer_key, h.order_id
    ),
    rolled as (
        select
            o.customer_key,
            o.order_id,
            max(o.order_date)                                    as order_date,
            max(o.order_state)                                   as order_state,
            max(o.order_status_desc)                             as order_status_desc,
            nullif(string_agg(distinct nullif(o.customer_po_number, ''), ', '), '')
                                                                 as customer_po_number,
            count(*)::int                                        as line_count,
            coalesce(sum(o.bookings), 0)::numeric                as bookings,
            count(*) filter (where o.is_backlog_line)::int       as open_line_count,
            coalesce(sum(o.backlog_amount) filter (where o.is_backlog_line), 0)::numeric
                                                                 as backlog_amount,
            min(o.promise_date)       filter (where o.is_backlog_line) as next_promise_date,
            min(o.desired_ship_date)  filter (where o.is_backlog_line) as next_desired_ship_date
        from erp.fact_order_line o
        join hits h
          on h.customer_key = o.customer_key
         and h.order_id     = o.order_id
        group by o.customer_key, o.order_id
    ),
    -- Shipment side aggregated to order grain BEFORE the join, and carrying
    -- no measure. See the header on why this is not a fact-to-fact join.
    tracking as (
        select
            s.order_id,
            nullif(
                string_agg(
                    distinct coalesce(nullif(s.tracking_number, ''),
                                      nullif(s.waybill_number, '')),
                    ', '),
                '') as tracking_numbers,
            max(s.ship_date) as last_ship_date
        from erp.fact_shipment_line s
        where s.order_id in (select order_id from hits)
        group by s.order_id
    )
    select
        r.customer_key,
        c.customer_id,
        c.customer_name,
        r.order_id,
        r.order_date,
        r.order_state,
        r.order_status_desc,
        r.customer_po_number,
        r.line_count,
        r.bookings,
        r.open_line_count,
        r.backlog_amount,
        r.next_promise_date,
        r.next_desired_ship_date,
        t.tracking_numbers,
        t.last_ship_date,
        h.matched_on
    from rolled r
    join hits h
      on h.customer_key = r.customer_key
     and h.order_id     = r.order_id
    left join tracking t on t.order_id = r.order_id
    left join erp.dim_customer c on c.customer_key = r.customer_key
    order by r.order_date desc nulls last, r.order_id desc
    limit greatest(1, least(coalesce(p_limit, 25), 100));
$$;

comment on function public.lookup_orders(text, int) is
  'Cross-account order lookup by our order number, the dealer''s PO number, '
  'or a tracking number. SECURITY INVOKER — RLS on the erp facts is the '
  'territory filter, so a rep sees only their own book. Returns order-header '
  'grain, newest first, capped at 100.';

revoke all on function public.lookup_orders(text, int) from anon, public;
grant execute on function public.lookup_orders(text, int) to authenticated;

--------------------------------------------------------------------------
-- Grants unchanged from 018, restated because create-or-replace on a view
-- does not disturb them but a fresh create would.
--------------------------------------------------------------------------
revoke all on public.v_account_recent_order_headers    from anon, public;
revoke all on public.v_account_recent_shipment_headers from anon, public;
revoke all on public.v_account_order_lines             from anon, public;

grant select on public.v_account_recent_order_headers    to authenticated;
grant select on public.v_account_recent_shipment_headers to authenticated;
grant select on public.v_account_order_lines             to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. The header views are now UNCAPPED. Any caller that relied on the
     implicit 20 must send .range() — useAccountMetrics.ts does as of this
     commit. Grep before adding a new one.
  2. RLS drill, same as 011/018: rep A gets zero rows from lookup_orders()
     for an order belonging to rep B, searching by order id, PO and tracking.
----------------------------------------------------------------------------*/
