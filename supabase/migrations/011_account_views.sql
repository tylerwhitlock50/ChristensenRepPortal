/*============================================================================
  011_account_views.sql
  Purpose: The read path behind the account mini-dashboard (PRD §7, "Account
           page — the 80% screen"): current vs prior year revenue, 12-month
           order history, open orders, recent shipments.

           Four public.v_account_* views that aggregate the erp fact tables
           in SQL, so the phone never does.

  ── Why every view here is `with (security_invoker = true)` ────────────────
  By default a Postgres view executes with the privileges of its OWNER, and
  RLS is evaluated against that owner. These views are created by the
  migration role, which owns the erp tables and is therefore exempt from
  their policies. Without `security_invoker = true`, every view below would
  hand every dealer's revenue to every rep — and to every non-employee rep
  group — while looking completely correct in code review. That is PRD
  acceptance criterion #1 failing silently and totally (TECH_STACK §1
  constraint 2, §3.5).

  With `security_invoker = true` the policies in 010_access_performance.sql
  (`customer_key in (select public.my_customer_keys())`) run as if the rep
  had typed the query themselves: their own book, their group's book, plus
  grants, minus revokes. Admins still see everything via is_admin().

  If you add a view to this file, write that line before you write the
  select. It is the single most important line here.

  ── These views are the ONLY sanctioned way for the UI to see aggregated
     ERP facts ─────────────────────────────────────────────────────────────
  erp.fact_invoice_line is ~529k rows and erp.fact_order_line ~501k. Pulling
  those to a browser to sum them is not a performance nit, it is a different
  product (TECH_STACK §3.3). Any new rollup the UI wants is a new view in
  this family, not a client-side reduce. If one of these gets slow, promote
  it to a materialized view refreshed as the last step of the ETL run — the
  data is only daily-fresh, so there is no staleness cost.

  ── The caller MUST filter by customer_key ─────────────────────────────────
  Every view exposes customer_key, and every one is shaped so that a
  `where customer_key = $1` predicate reaches the indexed fact scan:
    - v_account_revenue_monthly  customer_key is a GROUP BY column
    - v_account_summary          the fact scans are correlated LATERALs
    - v_account_recent_*         customer_key is the window PARTITION BY
                                 column, which the planner may push below
                                 the window (quals on partitioning columns
                                 are pushdown-safe)
  Selecting from these unfiltered scans the caller's whole book — for an
  admin, every account in the ERP. An unfiltered fact scan costs ~756ms
  because the RLS predicate defeats the customer_key index. The client
  composables (frontend/src/composables/useAccountMetrics.ts) therefore
  always send .eq('customer_key', …), and there is no code path that does
  not.

  ── Measures ───────────────────────────────────────────────────────────────
  Only the certified measures from 002_erp_read_tables.sql are used:
    revenue          erp.fact_invoice_line.revenue     (REVENUE headline)
    bookings         erp.fact_order_line.bookings      (ORDER headline)
    backlog_amount   erp.fact_order_line.backlog_amount (open/backlog value)
    shipped_revenue  erp.fact_shipment_line.shipped_revenue (SHIPPED headline)
  Nothing here invents a measure or re-derives one from unit_price.

  Dates use the generated `*_date` date columns, never the yyyymmdd int keys.

  Memos: `is_memo` is nullable, and `not is_memo` evaluates to NULL — not
  TRUE — for a NULL, which would silently drop those lines from revenue.
  Every revenue filter below is written `is_memo is not true` for that
  reason. It looks like a redundant spelling of `not is_memo`; it is not.
============================================================================*/

--------------------------------------------------------------------------
-- Supporting indexes. The single-column customer_key indexes from 002
-- already make these views correct-and-tolerable; these composite ones let
-- the monthly rollup and the two "most recent 20" views resolve without a
-- sort. TRUNCATE (the ETL's load pattern) preserves indexes, so these
-- survive every load.
--------------------------------------------------------------------------
create index if not exists idx_fil_customer_invoice_date
  on erp.fact_invoice_line (customer_key, invoice_date);

create index if not exists idx_fol_customer_order_date
  on erp.fact_order_line (customer_key, order_date desc);

create index if not exists idx_fsl_customer_ship_date
  on erp.fact_shipment_line (customer_key, ship_date desc);

--------------------------------------------------------------------------
-- v_account_revenue_monthly
--   Grain: one row per (customer_key, month), trailing 24 calendar months
--          including the current (partial) month.
--
--   24 months rather than 12 so the account chart can draw this year and
--   last year from ONE round trip: months 13–24 are the prior-year series
--   for months 1–12. A phone on LTE should not make two requests to draw
--   two lines.
--
--   Months with no invoices are simply absent — the client fills the gap.
--   Emitting zero rows for silent months would mean a generate_series
--   cross join per account for a value the UI can infer.
--------------------------------------------------------------------------
create or replace view public.v_account_revenue_monthly
with (security_invoker = true)
as
select
    f.customer_key,
    date_trunc('month', f.invoice_date)::date        as month,
    coalesce(sum(f.revenue), 0)::numeric             as revenue,
    count(distinct f.invoice_id)::int                as invoice_count
from erp.fact_invoice_line f
where f.is_memo is not true            -- NULL-safe; see header
  and f.invoice_date is not null
  and f.invoice_date >= (date_trunc('month', current_date) - interval '23 months')::date
group by f.customer_key, date_trunc('month', f.invoice_date)::date;

comment on view public.v_account_revenue_monthly is
  'Trailing 24 months of invoiced revenue per account, one row per month. '
  'security_invoker: the caller''s RLS on erp.fact_invoice_line applies. '
  'Always query with a customer_key filter — it is a GROUP BY column, so '
  'the predicate reaches the index.';

--------------------------------------------------------------------------
-- v_account_summary
--   Grain: one row per account (driven off erp.dim_customer, which is the
--          RLS-scoped list of accounts the caller can see at all).
--
--   The fact aggregates are correlated LATERALs rather than grouped
--   subqueries joined on customer_key: a `where customer_key = $1` on the
--   view filters dim_customer by primary key first, and each LATERAL then
--   runs for exactly one customer against idx_fil_customer /
--   idx_fol_customer. A FULL OUTER JOIN of two pre-grouped subqueries would
--   read the caller's entire book instead — quals cannot be pushed through
--   a full join.
--
--   Windows:
--     revenue_ytd          Jan 1 → today
--     revenue_prior_ytd    Jan 1 last year → the same calendar day last year
--                          (day-aligned, so the comparison is like-for-like
--                          in March as well as December)
--     revenue_trailing_12m rolling 12 months to today
--------------------------------------------------------------------------
create or replace view public.v_account_summary
with (security_invoker = true)
as
select
    c.customer_key,
    coalesce(inv.revenue_ytd, 0)::numeric            as revenue_ytd,
    coalesce(inv.revenue_prior_ytd, 0)::numeric      as revenue_prior_ytd,
    coalesce(inv.revenue_trailing_12m, 0)::numeric   as revenue_trailing_12m,
    ord.last_order_date,
    inv.last_invoice_date,
    coalesce(ord.open_order_count, 0)::int           as open_order_count,
    coalesce(ord.open_order_value, 0)::numeric       as open_order_value,
    coalesce(ord.backlog_qty, 0)::numeric            as backlog_qty
from erp.dim_customer c
left join lateral (
    select
        sum(f.revenue) filter (
            where f.invoice_date >= date_trunc('year', current_date)::date
        )                                                        as revenue_ytd,
        sum(f.revenue) filter (
            where f.invoice_date >= (date_trunc('year', current_date) - interval '1 year')::date
              and f.invoice_date <= (current_date - interval '1 year')::date
        )                                                        as revenue_prior_ytd,
        sum(f.revenue) filter (
            where f.invoice_date > (current_date - interval '12 months')::date
        )                                                        as revenue_trailing_12m,
        max(f.invoice_date)                                      as last_invoice_date
    from erp.fact_invoice_line f
    where f.customer_key = c.customer_key
      and f.is_memo is not true        -- NULL-safe; see header
      and f.invoice_date is not null
) inv on true
left join lateral (
    select
        max(o.order_date)                                        as last_order_date,
        -- "Open" = the ERP's own backlog flag: a line with quantity still
        -- owed. Counting distinct order_id answers the rep's question
        -- ("how many orders are open?"), not "how many lines".
        count(distinct o.order_id) filter (where o.is_backlog_line) as open_order_count,
        sum(o.backlog_amount)      filter (where o.is_backlog_line) as open_order_value,
        sum(o.backlog_qty)         filter (where o.is_backlog_line) as backlog_qty
    from erp.fact_order_line o
    where o.customer_key = c.customer_key
) ord on true;

comment on view public.v_account_summary is
  'One row per account: YTD vs prior-YTD vs trailing-12m revenue, last '
  'order/invoice dates, and open-order count/value/qty. security_invoker: '
  'driven off erp.dim_customer so the caller sees only their book. Always '
  'query with .eq(customer_key) — unfiltered it aggregates every account '
  'the caller can see.';

--------------------------------------------------------------------------
-- v_account_recent_orders
--   Grain: order line. The 20 most recent lines per account, part
--          description joined from erp.dim_part.
--
--   The row_number() partitions by customer_key so a caller-supplied
--   `customer_key = $1` is safe to push below the window (quals referencing
--   only partitioning columns are pushdown-safe) and the window then ranks
--   one account's lines instead of the whole book.
--------------------------------------------------------------------------
create or replace view public.v_account_recent_orders
with (security_invoker = true)
as
select
    r.customer_key,
    r.order_id,
    r.line_num,
    r.order_date,
    r.promise_date,
    r.order_state,
    r.order_status_desc,
    r.line_status_desc,
    r.part_key,
    p.part_id,
    p.part_description,
    r.order_qty,
    r.bookings,
    r.backlog_qty,
    r.is_backlog_line
from (
    select
        o.*,
        row_number() over (
            partition by o.customer_key
            order by o.order_date desc nulls last, o.order_id desc, o.line_num
        ) as rn
    from erp.fact_order_line o
) r
left join erp.dim_part p on p.part_key = r.part_key
where r.rn <= 20;

comment on view public.v_account_recent_orders is
  'Most recent 20 order lines per account with the part description. '
  'security_invoker. Always query with .eq(customer_key) — it is the '
  'PARTITION BY column, so the predicate reaches the index.';

--------------------------------------------------------------------------
-- v_account_recent_shipments
--   Grain: packlist line. Same shape and same pushdown rules as above.
--------------------------------------------------------------------------
create or replace view public.v_account_recent_shipments
with (security_invoker = true)
as
select
    r.customer_key,
    r.packlist_id,
    r.line_num,
    r.order_id,
    r.invoice_id,
    r.ship_date,
    r.promise_date,
    r.actual_delivery_date,
    r.shipment_state,
    r.shipper_status_desc,
    r.part_key,
    p.part_id,
    p.part_description,
    r.shipped_qty,
    r.shipped_revenue
from (
    select
        s.*,
        row_number() over (
            partition by s.customer_key
            order by s.ship_date desc nulls last, s.packlist_id desc, s.line_num
        ) as rn
    from erp.fact_shipment_line s
) r
left join erp.dim_part p on p.part_key = r.part_key
where r.rn <= 20;

comment on view public.v_account_recent_shipments is
  'Most recent 20 shipment lines per account with the part description. '
  'security_invoker. Always query with .eq(customer_key) — it is the '
  'PARTITION BY column, so the predicate reaches the index.';

--------------------------------------------------------------------------
-- Grants. Supabase's default privileges hand `anon` a SELECT on new objects
-- in public; these views serve dealer revenue, so take it back explicitly.
-- RLS would already return anon zero rows (every erp policy is `to
-- authenticated`), but a signed-out caller has no business reaching the
-- relation at all. service_role keeps its default grant for the ETL and the
-- Edge Functions.
--------------------------------------------------------------------------
revoke all on public.v_account_revenue_monthly   from anon, public;
revoke all on public.v_account_summary           from anon, public;
revoke all on public.v_account_recent_orders     from anon, public;
revoke all on public.v_account_recent_shipments  from anon, public;

grant select on public.v_account_revenue_monthly   to authenticated;
grant select on public.v_account_summary           to authenticated;
grant select on public.v_account_recent_orders     to authenticated;
grant select on public.v_account_recent_shipments  to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Add these four relations to the RLS test suite (§3.5): rep A must get
     zero rows for rep B's customer_key from EVERY one of them. New views are
     the likeliest place for a leak, and a missing security_invoker is
     invisible until someone runs that test.
  2. Regenerate frontend/src/types/database.types.ts — until then
     useAccountMetrics.ts reads them through a deliberately untyped client
     handle and says so in a comment.
  3. If v_account_summary shows up in slow-query logs, materialize it and
     refresh at the end of the ETL run; the client contract does not change.
----------------------------------------------------------------------------*/
