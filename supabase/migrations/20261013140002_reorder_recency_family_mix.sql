/*============================================================================
  20261013140002_reorder_recency_family_mix.sql
  Purpose: Three reads behind "what to sell, and to whom".

  1. report_reorder_candidates(): "due" needs to be recent
  --------------------------------------------------------
  20261013100000 marked a part due once last_bought_month + the median gap
  had arrived — with no upper bound. A part bought every month in 2024 and
  never since was still "due", and with many buy months it ranked at the
  top of the account card. That is a win-back conversation at best, and on
  a card labelled "Due" it reads as a fresh reorder.

  Now a part is due only when
    - the expected month has arrived, AND
    - it was last bought within 24 months, AND
    - it is no more than max(2 x the median gap, 3) months past the expected
      month (a monthly buyer three months quiet has lapsed; a twice-a-year
      buyer has until a year past).
  Parts that fail the recency tests ("lapsed") rank after every current
  one. Same name, arguments and OUT columns (create-or-replace rules), so
  every caller — the account card, the ATS page, the AI context — keeps
  working; only the meaning of is_due and the order change.

  2. report_account_family_mix(p_customer_key, p_through_month)
  -------------------------------------------------------------
  The AI account brief compared this year's product mix (year to date) with
  ALL of last year, and the prompt asked the model for "a family they
  stopped buying" — so every October a family bought in November last year
  read as dropped. This sums one account's invoiced revenue and units by
  product family over the SAME months of both years: January through
  p_through_month, and January through the same month a year earlier. The
  caller passes the last COMPLETE month, so no partial month is compared
  with a whole one. revenue_after_period is what the family invoiced AFTER
  p_through_month (normally the current, partial month): never compared,
  only there so a family bought last week is not called "stopped" because
  the window ends at the last complete month.

  3. An index for "who bought this SKU"
  -------------------------------------
  The ATS page's "Who should I call?" sheet and the MCP find_dealers_for_sku
  tool read v_sku_sales_by_account by part_key across the caller's book.
  agg_sku_year's primary key starts at customer_key, so add one that starts
  at part_key. Rebuilt with the table nightly; the refresh truncates and
  reinserts (20260901190100), which keeps it compact.

  Both functions are SECURITY INVOKER over RLS-scoped rollups
  (erp.agg_sku_month: is_admin() or my_customer_keys(), view-as aware) and
  dim_part columns every rep holds (20260901190300). The nightly AI batch
  calls them as service_role, which bypasses RLS and therefore reads the
  SAME rows for an account as its rep does — the parity the shared context
  hash depends on (_shared/accountContext.ts). A DEFINER function gated on
  has_account_access() would return nothing to service_role and break it.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Reorder candidates with a recency cutoff.
--------------------------------------------------------------------------
create or replace function public.report_reorder_candidates(
    p_customer_key  text,
    p_limit         int default 10
)
returns table (
    part_key                    text,
    part_id                     text,
    part_description            text,
    product_code                text,
    product_family              text,
    chambering                  text,
    barrel_length               text,
    upc                         text,
    ats_qty                     numeric,
    last_bought_month           date,
    last_qty                    numeric,
    total_qty                   numeric,
    months_with_buys            int,
    median_months_between_buys  numeric,
    expected_next_month         date,
    is_due                      boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
    with this_month as (
        select date_trunc('month', current_date)::date as m
    ),
    buys as (
        -- RLS on agg_sku_month is the scope (see 20261013100000). Months
        -- with a net return (qty <= 0) are not buys.
        select
            m.part_key,
            m.sales_month,
            m.qty,
            extract(year from m.sales_month)::int * 12
              + extract(month from m.sales_month)::int as month_no
        from erp.agg_sku_month m
        where m.customer_key = p_customer_key
          and m.qty > 0
    ),
    gaps as (
        select
            b.*,
            b.month_no - lag(b.month_no) over (
                partition by b.part_key order by b.sales_month
            ) as gap_months
        from buys b
    ),
    rhythm as (
        select
            g.part_key,
            max(g.sales_month)                                   as last_bought_month,
            (array_agg(g.qty order by g.sales_month desc))[1]    as last_qty,
            sum(g.qty)                                           as total_qty,
            count(*)::int                                        as months_with_buys,
            round(percentile_cont(0.5) within group (order by g.gap_months)::numeric, 1)
                                                                 as median_gap
        from gaps g
        group by g.part_key
    ),
    ats as (
        select a.part_key, sum(a.available_to_sell_qty) as ats_qty
        from erp.fact_available_to_sell a
        where a.part_key in (select r.part_key from rhythm r)
        group by a.part_key
        having sum(a.available_to_sell_qty) >= 1          -- sellable today; see 027
    ),
    scored as (
        select
            r.*,
            s.ats_qty,
            case when r.median_gap is not null
                 then (r.last_bought_month
                       + make_interval(months => round(r.median_gap)::int))::date
            end as expected_next_month
        from rhythm r
        join ats s on s.part_key = r.part_key
    ),
    judged as (
        select
            sc.*,
            -- Bought within the last 24 months (month-aligned).
            sc.last_bought_month >= (t.m - interval '24 months')::date as recent,
            -- Whole months from the expected month to this one; negative =
            -- not expected yet.
            (extract(year from t.m)::int * 12 + extract(month from t.m)::int)
              - (extract(year from sc.expected_next_month)::int * 12
                 + extract(month from sc.expected_next_month)::int) as months_overdue,
            t.m as this_month
        from scored sc
        cross join this_month t
    ),
    flagged as (
        select
            j.*,
            coalesce(
                j.expected_next_month <= j.this_month
                and j.recent
                and j.months_overdue <= greatest(2 * j.median_gap, 3),
                false
            ) as due,
            -- Long past its rhythm, or not bought in two years: a win-back,
            -- not a reorder. Ranked after every current part.
            (not j.recent
             or coalesce(j.expected_next_month <= j.this_month
                         and j.months_overdue > greatest(2 * j.median_gap, 3),
                         false)) as lapsed
        from judged j
    )
    select
        f.part_key,
        p.part_id,
        p.part_description,
        p.product_code,
        p.product_family,
        p.chambering,
        p.barrel_length,
        p.upc,
        f.ats_qty,
        f.last_bought_month,
        f.last_qty,
        f.total_qty,
        f.months_with_buys,
        f.median_gap,
        f.expected_next_month,
        f.due
    from flagged f
    join erp.dim_part p on p.part_key = f.part_key
    -- Finished firearms only. Mirrors report_account_sku_gaps / isGunRow().
    where coalesce(p.product_code, '') !~* 'component'
      and (
            coalesce(nullif(btrim(p.product_family), ''), 'N/A') <> 'N/A'
         or coalesce(nullif(btrim(p.chambering), ''), 'N/A')     <> 'N/A'
      )
    order by
        f.due desc,
        f.lapsed,
        f.months_with_buys desc,
        f.last_bought_month desc,
        f.part_key
    limit greatest(1, least(coalesce(p_limit, 10), 50));
$$;

comment on function public.report_reorder_candidates(text, int) is
  'In-stock parts this account has bought before, with their buying rhythm: '
  'last buy month and qty, total qty and buy months over the agg_sku_month '
  'window (36 whole months + current), median months between buys, the '
  'month the next buy is expected, and is_due once that month arrives — '
  'only while the part was bought in the last 24 months and is no more than '
  'max(2 x median gap, 3) months past it (20261013140002). Finished firearms '
  'with available_to_sell >= 1 only. Due first, then current before lapsed, '
  'then most-repeated, then most recent; p_limit clamped to 1..50. SECURITY '
  'INVOKER — RLS on erp.agg_sku_month (my_customer_keys(), view-as aware) '
  'decides which accounts return anything.';

-- service_role is the nightly AI batch (_shared/accountContext.ts). The
-- platform's default privileges already include it; stated here because the
-- batch fails every account if it is ever missing.
revoke execute on function public.report_reorder_candidates(text, int)
  from public, anon;
grant execute on function public.report_reorder_candidates(text, int)
  to authenticated, service_role;

--------------------------------------------------------------------------
-- 2. Product-family mix over the same months of two years.
--------------------------------------------------------------------------
-- Dropped first: an earlier draft of this file returned one column fewer,
-- and CREATE OR REPLACE cannot change a function's OUT columns.
drop function if exists public.report_account_family_mix(text, date);

create or replace function public.report_account_family_mix(
    p_customer_key   text,
    p_through_month  date default null
)
returns table (
    product_family  text,
    revenue         numeric,
    qty             numeric,
    prior_revenue   numeric,
    prior_qty       numeric,
    period_start    date,
    period_end      date,
    prior_start     date,
    prior_end       date,
    revenue_after_period numeric
)
language sql
stable
security invoker
set search_path = ''
as $$
    with bounds as (
        -- Default: through last month, the last complete one.
        select date_trunc('month', coalesce(
                   p_through_month,
                   (date_trunc('month', current_date) - interval '1 month')::date
               ))::date as through_m
    ),
    w as (
        select
            date_trunc('year', b.through_m)::date                          as period_start,
            b.through_m                                                    as period_end,
            (date_trunc('year', b.through_m) - interval '1 year')::date    as prior_start,
            (b.through_m - interval '1 year')::date                        as prior_end
        from bounds b
    ),
    rows_in as (
        -- RLS on agg_sku_month is the scope. sales_month is the first of
        -- the month, so month bounds compare directly.
        select
            btrim(p.product_family)               as family,
            m.sales_month,
            m.revenue,
            m.qty
        from erp.agg_sku_month m
        join erp.dim_part p on p.part_key = m.part_key
        cross join w
        where m.customer_key = p_customer_key
          and m.sales_month >= w.prior_start
          and coalesce(nullif(btrim(p.product_family), ''), 'N/A') <> 'N/A'
    )
    select
        r.family,
        coalesce(sum(r.revenue) filter (where r.sales_month between w.period_start and w.period_end), 0),
        coalesce(sum(r.qty)     filter (where r.sales_month between w.period_start and w.period_end), 0),
        coalesce(sum(r.revenue) filter (where r.sales_month <= w.prior_end), 0),
        coalesce(sum(r.qty)     filter (where r.sales_month <= w.prior_end), 0),
        w.period_start,
        w.period_end,
        w.prior_start,
        w.prior_end,
        coalesce(sum(r.revenue) filter (where r.sales_month > w.period_end), 0)
    from rows_in r
    cross join w
    group by r.family, w.period_start, w.period_end, w.prior_start, w.prior_end
    having coalesce(sum(r.revenue) filter (where r.sales_month between w.period_start and w.period_end), 0) <> 0
        or coalesce(sum(r.revenue) filter (where r.sales_month <= w.prior_end), 0) <> 0
    order by
        greatest(
            coalesce(sum(r.revenue) filter (where r.sales_month between w.period_start and w.period_end), 0),
            coalesce(sum(r.revenue) filter (where r.sales_month <= w.prior_end), 0)
        ) desc,
        r.family;
$$;

comment on function public.report_account_family_mix(text, date) is
  'One account''s invoiced revenue and units by product family over the SAME '
  'months of two years: Jan..p_through_month (default: last complete month) '
  'and Jan..that month a year earlier, plus revenue_after_period (what the '
  'family invoiced after p_through_month — the current partial month — '
  'never compared, so a recent buy is not read as "stopped"). Families with '
  'no real value (blank, N/A) are left out. Feeds the AI account brief''s product mix. SECURITY '
  'INVOKER over erp.agg_sku_month RLS — service_role (the nightly batch) and '
  'the account''s rep read the same rows.';

revoke execute on function public.report_account_family_mix(text, date)
  from public, anon;
grant execute on function public.report_account_family_mix(text, date)
  to authenticated, service_role;

--------------------------------------------------------------------------
-- 3. "Who bought this SKU" — part-first access path into agg_sku_year.
--------------------------------------------------------------------------
create index if not exists idx_agg_sku_year_part
  on erp.agg_sku_year (part_key, customer_key);
