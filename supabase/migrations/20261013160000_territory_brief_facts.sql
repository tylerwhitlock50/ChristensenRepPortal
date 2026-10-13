/*============================================================================
  20261013160000_territory_brief_facts.sql — what the Overview's AI sales
  brief was missing.

  The territory brief (supabase/functions/ai-brief) was writing from an
  incomplete picture, and saying so confidently:

  - It had no idea how old its figures were. Every total, top account,
    mover and gone-quiet account comes from erp.agg_account_rollup, rebuilt
    by the ETL's post-load refresh — but the only date it was given was
    v_data_freshness.data_through, the newest invoice in the FACT table.
    On 2026-10-13 the facts ran through Oct 9 while the rollups were last
    rebuilt Oct 3 (a failing table stops every post-load step), so the
    brief described Oct 2 numbers as "through Oct 9", and Lipsey's — which
    invoiced every day that week — read as "last invoice Oct 1".
  - "Recent orders" was the 15 newest order headers with no count and no
    total; on any real book that is a fraction of a fortnight, and the
    model read it as all of it.
  - Products were this year so far beside ALL of last year, so the brief
    could not honestly say what is growing.
  - No bookings (orders placed) and no new-account count, only revenue.

  Two security-invoker functions fill those gaps. Both read RLS-scoped
  tables only, so the caller's book is the scope (view-as aware through
  my_customer_keys()) and the edge function needs no access logic of its
  own. Both are additive; nothing deployed reads them, and the brief falls
  back to its old inputs on a database without them.
============================================================================*/

--------------------------------------------------------------------------
-- 1. One row of whole-book facts the totals RPC does not carry.
--------------------------------------------------------------------------
create or replace function public.report_territory_brief_facts()
returns table (
    figures_refreshed_at timestamptz,
    bookings_ytd         numeric,
    bookings_prior_ytd   numeric,
    new_accounts_ytd     bigint,
    orders_14d_count     bigint,
    orders_14d_amount    numeric,
    orders_14d_since     date
)
language sql
stable
security invoker
set search_path = ''
as $$
    with book as (
        -- The territory definition every v_territory_* view uses (025/029):
        -- active, external accounts.
        select a.bookings_ytd, a.bookings_prior_ytd, a.first_invoice_date
        from erp.agg_account_rollup a
        join erp.dim_customer c on c.customer_key = a.customer_key
        where c.active_flag = 'Y'
          and coalesce(c.internal_customer_flag, 'N') <> 'Y'
    ),
    recent as (
        select count(*)                          as n,
               coalesce(sum(r.order_amount), 0)  as amount
        from public.v_territory_recent_orders r
    )
    select
        -- Every row of a refresh is inserted in one statement, so they all
        -- carry that statement's now(); max() is the last rebuild the
        -- caller can see. Over the whole table, not just active accounts,
        -- so a book of only inactive accounts still has a date.
        (select max(a.refreshed_at) from erp.agg_account_rollup a),
        coalesce((select sum(b.bookings_ytd) from book b), 0),
        coalesce((select sum(b.bookings_prior_ytd) from book b), 0),
        (select count(*) from book b
          where b.first_invoice_date >= date_trunc('year', current_date)::date),
        recent.n,
        recent.amount,
        -- v_territory_recent_orders' own window (029), stated so the brief
        -- can say "since Sep 29" instead of guessing.
        current_date - 14
    from recent;
$$;

comment on function public.report_territory_brief_facts() is
  'Whole-book facts for the AI territory brief, over the caller''s RLS '
  '(security invoker): when the rollups were last rebuilt '
  '(figures_refreshed_at — the date every rollup-based figure is as of), '
  'bookings this year vs the same window last year (cancelled orders '
  'excluded, from agg_account_rollup), accounts whose first invoice ever '
  'is this year, and the count and value of ALL orders in the last 14 '
  'days (v_territory_recent_orders). One row.';

revoke execute on function public.report_territory_brief_facts() from public, anon;
grant execute on function public.report_territory_brief_facts() to authenticated;

--------------------------------------------------------------------------
-- 2. Product mix over the SAME months of two years.
--------------------------------------------------------------------------
-- The account brief's report_account_family_mix (20261013140002) does this
-- for one account; this is the book-wide version, by family and by SKU.
-- Window: Jan .. p_through_month (default: last complete month) against
-- Jan .. that month a year earlier, so "Mesa up 20%" compares like with
-- like. The brief passes the month before its figures were rebuilt, so a
-- stale rollup never contributes a half-counted month.
create or replace function public.report_territory_product_mix(
    p_through_month date default null,
    p_sku_limit     int  default 8
)
returns table (
    grain            text,     -- 'family' | 'sku'
    product_family   text,
    part_id          text,
    part_description text,
    chambering       text,
    revenue          numeric,
    qty              numeric,
    prior_revenue    numeric,
    prior_qty        numeric,
    period_start     date,
    period_end       date,
    prior_start      date,
    prior_end        date
)
language sql
stable
security invoker
set search_path = ''
as $$
    with bounds as (
        select date_trunc('month', coalesce(
                   p_through_month,
                   (date_trunc('month', current_date) - interval '1 month')::date
               ))::date as through_m,
               greatest(1, least(coalesce(p_sku_limit, 8), 25)) as sku_limit
    ),
    w as (
        select
            date_trunc('year', b.through_m)::date                       as period_start,
            b.through_m                                                 as period_end,
            (date_trunc('year', b.through_m) - interval '1 year')::date as prior_start,
            (b.through_m - interval '1 year')::date                     as prior_end,
            b.sku_limit
        from bounds b
    ),
    per_part as (
        -- RLS on agg_sku_month is the scope; the dim_customer join is the
        -- territory definition (active, external), same as the views.
        -- sales_month is the first of the month, so month bounds compare
        -- directly, and only the two windows are read.
        select
            m.part_key,
            coalesce(sum(m.revenue) filter (where m.sales_month between w.period_start and w.period_end), 0) as revenue,
            coalesce(sum(m.qty)     filter (where m.sales_month between w.period_start and w.period_end), 0) as qty,
            coalesce(sum(m.revenue) filter (where m.sales_month between w.prior_start and w.prior_end), 0)   as prior_revenue,
            coalesce(sum(m.qty)     filter (where m.sales_month between w.prior_start and w.prior_end), 0)   as prior_qty
        from erp.agg_sku_month m
        join erp.dim_customer c on c.customer_key = m.customer_key
        cross join w
        where (m.sales_month between w.period_start and w.period_end
               or m.sales_month between w.prior_start and w.prior_end)
          and c.active_flag = 'Y'
          and coalesce(c.internal_customer_flag, 'N') <> 'Y'
        group by m.part_key
    ),
    parts as (
        select
            pp.*,
            -- Named columns only: dim_part's cost columns are revoked
            -- (20260901190300).
            p.part_id,
            p.part_description,
            p.chambering,
            nullif(btrim(p.product_family), '') as family
        from per_part pp
        left join erp.dim_part p on p.part_key = pp.part_key
    ),
    families as (
        select
            p.family,
            sum(p.revenue)       as revenue,
            sum(p.qty)           as qty,
            sum(p.prior_revenue) as prior_revenue,
            sum(p.prior_qty)     as prior_qty
        from parts p
        where coalesce(p.family, 'N/A') <> 'N/A'
        group by p.family
    ),
    skus as (
        -- The leaders of EITHER window, so a SKU that led last year and
        -- fell away is in the list, not just this year's winners.
        select
            p.*,
            row_number() over (order by p.revenue desc, p.part_key)       as rn_now,
            row_number() over (order by p.prior_revenue desc, p.part_key) as rn_prior
        from parts p
    )
    select 'family'::text, f.family, null::text, null::text, null::text,
           f.revenue, f.qty, f.prior_revenue, f.prior_qty,
           w.period_start, w.period_end, w.prior_start, w.prior_end
    from families f
    cross join w
    where f.revenue <> 0 or f.prior_revenue <> 0
    union all
    select 'sku'::text, s.family, s.part_id, s.part_description, s.chambering,
           s.revenue, s.qty, s.prior_revenue, s.prior_qty,
           w.period_start, w.period_end, w.prior_start, w.prior_end
    from skus s
    cross join w
    where (s.rn_now <= w.sku_limit and s.revenue > 0)
       or (s.rn_prior <= w.sku_limit and s.prior_revenue > 0)
    order by 1, 6 desc, 7 desc, 3;
$$;

comment on function public.report_territory_product_mix(date, int) is
  'Invoiced revenue and units across the caller''s book (RLS via security '
  'invoker; active external accounts) over the SAME months of two years: '
  'Jan..p_through_month (default: last complete month) and Jan..that month '
  'a year earlier. grain=family: every product family with revenue in '
  'either window (blank/N/A families left out). grain=sku: the top '
  'p_sku_limit SKUs (1..25) of EITHER window. Feeds the AI territory '
  'brief''s product mix.';

revoke execute on function public.report_territory_product_mix(date, int) from public, anon;
grant execute on function public.report_territory_product_mix(date, int) to authenticated;
