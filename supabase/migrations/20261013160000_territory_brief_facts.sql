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
    rebuilt Oct 3 (a failing table stopped every post-load step), so the
    brief described Oct 2 numbers as "through Oct 9", and Lipsey's — which
    invoiced every day that week — read as "last invoice Oct 1".
  - "Recent orders" was the 15 newest order headers with no count and no
    total, cancelled orders included; on any real book that is a fraction
    of a fortnight, and the model read it as all of it.
  - Products were this year so far beside ALL of last year, so the brief
    could not honestly say what is growing.
  - No bookings (orders placed), no new-account count, and no channel: the
    prompt called every account a dealer while the biggest are
    distributors and conservation-group programs.

  What this adds, all additive (append-only view columns; new functions):

    v_territory_account_yoy.channel   the ERP's customer_reporting_group
    v_data_freshness.facts_loaded_at  the last successful fact-table load —
                                      the brief compares it with the
                                      rollup rebuild to know the figures
                                      are behind, from the load ledger
                                      rather than from invoice dates
    report_territory_brief_facts()    rebuild time, bookings, accounts that
                                      bought last year, new accounts and
                                      their revenue, and every (uncancelled)
                                      order of the last 14 days
    report_territory_product_mix()    families and real products over the
                                      same whole months of two years

  The functions are security invoker over RLS-scoped tables, so the
  caller's book is the scope (view-as aware through my_customer_keys()).
  Nothing deployed reads any of this; the brief falls back to its old
  inputs on a database without it.
============================================================================*/

--------------------------------------------------------------------------
-- 1. v_territory_account_yoy gains `channel` (appended — create-or-replace
--    keeps every existing column's name, type and position). Body restated
--    verbatim from 20260817170000_first_invoice_date.sql.
--------------------------------------------------------------------------
create or replace view public.v_territory_account_yoy
with (security_invoker = true)
as
select
    c.customer_key,
    c.customer_name,
    c.sold_to_city,
    c.sold_to_state,
    c.yearly_sales_goal,
    coalesce(a.revenue_ytd, 0)::numeric          as revenue_ytd,
    coalesce(a.revenue_prior_ytd, 0)::numeric    as revenue_prior_ytd,
    coalesce(a.revenue_trailing_12m, 0)::numeric as revenue_trailing_12m,
    a.last_invoice_date,
    coalesce(a.open_order_value, 0)::numeric     as open_order_value,
    coalesce(a.backlog_qty, 0)::numeric          as backlog_qty,
    coalesce(a.backlog_amount, 0)::numeric       as backlog_amount,
    (coalesce(a.revenue_ytd, 0) - coalesce(a.revenue_prior_ytd, 0))::numeric
                                                 as yoy_change_amount,
    case
        when coalesce(a.revenue_prior_ytd, 0) > 0 then
            round(
                (coalesce(a.revenue_ytd, 0) - a.revenue_prior_ytd)
                    / a.revenue_prior_ytd * 1000
            ) / 10
        else null
    end                                          as yoy_change_pct,
    a.first_invoice_date,
    -- The ERP's channel (bi.vw_DimCustomer CustomerReportingGroup, landed
    -- by 032): Dealer, Buy Group, Direct to Consumer, Special Programs, …
    -- Null on rows landed before 032 — the Reports tab calls that
    -- Unclassified; the brief simply omits it.
    nullif(btrim(c.customer_reporting_group), '') as channel
from erp.dim_customer c
left join erp.agg_account_rollup a on a.customer_key = c.customer_key
where c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y';

comment on view public.v_territory_account_yoy is
  'One row per account in the caller''s book, read from erp.agg_account_rollup '
  '(refreshed nightly by the ETL — see 030). security_invoker: RLS is the '
  'territory filter. yoy_change_amount/_pct are SQL columns for server-side '
  'ORDER BY (20260817120000); first_invoice_date is the new-account signal '
  '(20260817170000, null = never invoiced); channel is the ERP reporting '
  'group (20261013160000).';

revoke all on public.v_territory_account_yoy from anon, public;
grant select on public.v_territory_account_yoy to authenticated;

--------------------------------------------------------------------------
-- 2. v_data_freshness gains `facts_loaded_at` (appended). Body restated
--    verbatim from 20260901190400_etl_run_ledger.sql.
--------------------------------------------------------------------------
create or replace view public.v_data_freshness as
select
    coalesce(
      (select max(j.finished_at)
         from public.job_runs j
        where j.status = 'success'
          and j.job_name = 'etl:run'),
      -- Before the first run that logs 'etl:run' (loader < 2026-09-01).
      (select max(j.finished_at)
         from public.job_runs j
        where j.status = 'success'
          and j.job_name like 'etl:erp.%')
    )                                                as data_loaded_at,
    (select max(f.invoice_date)
       from erp.fact_invoice_line f
      where f.is_memo is not true
        and f.invoice_date <= current_date)          as data_through,
    (select max(o.order_date)
       from erp.fact_order_line o
      where o.order_date <= current_date)            as orders_through,
    -- The last time the facts the rollups are built from landed, whatever
    -- else that night did. Newer than the rollups' refreshed_at (by more
    -- than a load's own duration) means the post-load rebuild has not run
    -- over them: the brief's figures are behind.
    (select max(j.finished_at)
       from public.job_runs j
      where j.status = 'success'
        and j.job_name in ('etl:erp.fact_invoice_line',
                           'etl:erp.fact_order_line'))
                                                     as facts_loaded_at;

revoke all on public.v_data_freshness from anon, public;
grant select on public.v_data_freshness to authenticated;

comment on view public.v_data_freshness is
  'One row: finish time of the last fully successful ETL run (etl:run — '
  'every table loaded and every post-load step ran), newest non-memo '
  'invoice date (data_through — the revenue horizon), newest order entry '
  'date (orders_through), and the last successful load of the invoice or '
  'order facts (facts_loaded_at, 20261013160000). Future-dated ERP rows are '
  'ignored for the two horizons. OWNER-rights on purpose (documented '
  'exception): output is four timestamps and nothing else. Powers the '
  'freshness stamp and the AI brief''s figures-behind check.';

--------------------------------------------------------------------------
-- 3. One row of whole-book facts the totals RPC does not carry.
--------------------------------------------------------------------------
-- No deployed caller; the drop lets a re-run replace an earlier draft
-- whose OUT columns differ (create or replace cannot change them).
drop function if exists public.report_territory_brief_facts();

create or replace function public.report_territory_brief_facts()
returns table (
    figures_refreshed_at            timestamptz,
    bookings_ytd                    numeric,
    bookings_prior_ytd              numeric,
    accounts_with_revenue_prior_ytd bigint,
    new_accounts_ytd                bigint,
    new_accounts_revenue_ytd        numeric,
    orders_14d_count                bigint,
    orders_14d_amount               numeric,
    orders_14d_since                date,
    largest_orders                  jsonb
)
language sql
stable
security invoker
set search_path = ''
as $$
    with refresh as (
        -- Every row of a refresh is inserted in one statement, so they all
        -- carry that statement's now(); max() is the last rebuild the
        -- caller can see. Over the whole table, not just active accounts,
        -- so a book of only inactive accounts still has a date.
        select max(a.refreshed_at) as at from erp.agg_account_rollup a
    ),
    book as (
        -- The territory definition every v_territory_* view uses (025/029):
        -- active, external accounts.
        select a.bookings_ytd, a.bookings_prior_ytd, a.revenue_ytd,
               a.revenue_prior_ytd, a.first_invoice_date
        from erp.agg_account_rollup a
        join erp.dim_customer c on c.customer_key = a.customer_key
        where c.active_flag = 'Y'
          and coalesce(c.internal_customer_flag, 'N') <> 'Y'
    ),
    -- "New this year" is the rollup's year — the year its revenue_ytd was
    -- computed in (the refresh's business date), not the wall clock, so a
    -- December rebuild read in January stays consistent with its own YTD.
    year_start as (
        select date_trunc('year', coalesce(
                   (r.at at time zone 'America/Denver')::date,
                   current_date))::date as d
        from refresh r
    ),
    recent as (
        -- Order headers of the last 14 days, read from the facts (current
        -- even when the rollups are not). Cancelled orders (status X) are
        -- left out, the same rule as bookings (20260901190100) and the
        -- Overview's activity feed (20261013150004).
        select o.customer_key, c.customer_name, o.order_id,
               max(o.order_date)               as order_date,
               coalesce(sum(o.bookings), 0)    as amount,
               bool_or(o.is_backlog_line)      as has_open_lines
        from erp.fact_order_line o
        join erp.dim_customer c on c.customer_key = o.customer_key
        where o.order_date >= current_date - 14
          and coalesce(o.order_status, '') <> 'X'
          and c.active_flag = 'Y'
          and coalesce(c.internal_customer_flag, 'N') <> 'Y'
        group by o.customer_key, c.customer_name, o.order_id
    ),
    largest as (
        select r.* from recent r
        order by r.amount desc, r.order_id
        limit 8
    )
    select
        (select r.at from refresh r),
        coalesce((select sum(b.bookings_ytd) from book b), 0),
        coalesce((select sum(b.bookings_prior_ytd) from book b), 0),
        (select count(*) from book b where b.revenue_prior_ytd > 0),
        (select count(*) from book b, year_start y where b.first_invoice_date >= y.d),
        coalesce((select sum(b.revenue_ytd) from book b, year_start y
                   where b.first_invoice_date >= y.d), 0),
        (select count(*) from recent),
        coalesce((select sum(r.amount) from recent r), 0),
        -- The window's start, stated so the brief can say "since Sep 29".
        current_date - 14,
        coalesce(
          (select jsonb_agg(jsonb_build_object(
                     'customer_key',   l.customer_key,
                     'customer_name',  l.customer_name,
                     'order_id',       l.order_id,
                     'order_date',     l.order_date,
                     'amount',         l.amount,
                     'has_open_lines', coalesce(l.has_open_lines, false))
                   order by l.amount desc, l.order_id)
             from largest l),
          '[]'::jsonb);
$$;

comment on function public.report_territory_brief_facts() is
  'Whole-book facts for the AI territory brief, over the caller''s RLS '
  '(security invoker): when the rollups were last rebuilt '
  '(figures_refreshed_at — the date every rollup-based figure is as of), '
  'bookings this year vs the same window last year (cancelled orders '
  'excluded), how many accounts invoiced in last year''s window, accounts '
  'whose first invoice ever is in the rollup''s year and their revenue, '
  'and the count, value and largest 8 of every uncancelled order of the '
  'last 14 days. One row.';

revoke execute on function public.report_territory_brief_facts() from public, anon;
grant execute on function public.report_territory_brief_facts() to authenticated;

--------------------------------------------------------------------------
-- 4. Product mix over the SAME months of two years.
--------------------------------------------------------------------------
-- The account brief's report_account_family_mix (20261013140002) does this
-- for one account; this is the book-wide version, by family and by real
-- product. Window: Jan .. p_through_month (default: last complete month)
-- against Jan .. that month a year earlier. The brief picks the through
-- month (a full prior year in January and February, so it never compares
-- one month with one month).
drop function if exists public.report_territory_product_mix(date, int);

create or replace function public.report_territory_product_mix(
    p_through_month date default null,
    p_sku_limit     int  default 8
)
returns table (
    grain                text,     -- 'family' | 'sku'
    product_family       text,
    part_id              text,
    part_description     text,
    chambering           text,
    revenue              numeric,
    qty                  numeric,
    prior_revenue        numeric,
    prior_qty            numeric,
    -- Invoiced after period_end (the months since, current partial one
    -- included). Never compared; it stops a product that sold this month
    -- from reading as "stopped" (same idea as the account mix).
    revenue_after_period numeric,
    period_start         date,
    period_end           date,
    prior_start          date,
    prior_end            date
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
        -- directly, and only the two windows and the months since are read.
        select
            m.part_key,
            coalesce(sum(m.revenue) filter (where m.sales_month between w.period_start and w.period_end), 0) as revenue,
            coalesce(sum(m.qty)     filter (where m.sales_month between w.period_start and w.period_end), 0) as qty,
            coalesce(sum(m.revenue) filter (where m.sales_month between w.prior_start and w.prior_end), 0)   as prior_revenue,
            coalesce(sum(m.qty)     filter (where m.sales_month between w.prior_start and w.prior_end), 0)   as prior_qty,
            coalesce(sum(m.revenue) filter (where m.sales_month > w.period_end), 0)                          as revenue_after_period
        from erp.agg_sku_month m
        join erp.dim_customer c on c.customer_key = m.customer_key
        cross join w
        where (m.sales_month between w.prior_start and w.prior_end
               or m.sales_month >= w.period_start)
          and c.active_flag = 'Y'
          and coalesce(c.internal_customer_flag, 'N') <> 'Y'
        group by m.part_key
    ),
    parts as (
        -- Real products only: a part with a product family. Non-stock
        -- '(Unknown)' lines, repairs, reward points and OEM components carry
        -- no family (or N/A) and must never be named as a leading product.
        -- Named columns only: dim_part's cost columns are revoked
        -- (20260901190300).
        select
            pp.*,
            p.part_id,
            p.part_description,
            p.chambering,
            nullif(btrim(p.product_family), '') as family
        from per_part pp
        join erp.dim_part p on p.part_key = pp.part_key
        where coalesce(nullif(btrim(p.product_family), ''), 'N/A') <> 'N/A'
          and p.part_id is not null
    ),
    families as (
        select
            p.family,
            sum(p.revenue)              as revenue,
            sum(p.qty)                  as qty,
            sum(p.prior_revenue)        as prior_revenue,
            sum(p.prior_qty)            as prior_qty,
            sum(p.revenue_after_period) as revenue_after_period
        from parts p
        group by p.family
    ),
    skus as (
        -- The leaders of EITHER window, so a product that led last year and
        -- fell away is in the list, not just this year's winners.
        select
            p.*,
            row_number() over (order by p.revenue desc, p.part_key)       as rn_now,
            row_number() over (order by p.prior_revenue desc, p.part_key) as rn_prior
        from parts p
    ),
    out as (
        select 'family'::text as grain, f.family, null::text as part_id,
               null::text as part_description, null::text as chambering,
               f.revenue, f.qty, f.prior_revenue, f.prior_qty, f.revenue_after_period
        from families f
        where f.revenue <> 0 or f.prior_revenue <> 0
        union all
        select 'sku'::text, s.family, s.part_id, s.part_description, s.chambering,
               s.revenue, s.qty, s.prior_revenue, s.prior_qty, s.revenue_after_period
        from skus s, w
        where (s.rn_now <= w.sku_limit and s.revenue > 0)
           or (s.rn_prior <= w.sku_limit and s.prior_revenue > 0)
    )
    select o.grain, o.family, o.part_id, o.part_description, o.chambering,
           o.revenue, o.qty, o.prior_revenue, o.prior_qty, o.revenue_after_period,
           w.period_start, w.period_end, w.prior_start, w.prior_end
    from out o
    cross join w
    -- Biggest of either window first, so a family that sold last year and
    -- nothing this year is not the first one a top-N cut drops — it is the
    -- "fading" the brief is asked to notice.
    order by o.grain, greatest(o.revenue, o.prior_revenue) desc, o.part_id nulls first, o.family;
$$;

comment on function public.report_territory_product_mix(date, int) is
  'Invoiced revenue and units across the caller''s book (RLS via security '
  'invoker; active external accounts; real products — parts with a '
  'product family) over the SAME months of two years: Jan..p_through_month '
  '(default: last complete month) and Jan..that month a year earlier, plus '
  'revenue_after_period (since p_through_month, never compared). '
  'grain=family: every family with revenue in either window. grain=sku: '
  'the top p_sku_limit products (1..25) of EITHER window. Rows ordered by '
  'the larger of the two windows. Feeds the AI territory brief.';

revoke execute on function public.report_territory_product_mix(date, int) from public, anon;
grant execute on function public.report_territory_product_mix(date, int) to authenticated;
