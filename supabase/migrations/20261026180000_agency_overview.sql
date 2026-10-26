/*============================================================================
  20261026180000_agency_overview.sql — what a rep-group principal needs to
  run their agency from the portal.

  Why
  ---
  A principal's book is already the whole agency (003/010: every account
  whose assigned rep bills through profiles.rep_group_vendor_id), but every
  screen they could open reads that book as ONE territory. Nothing said
  which rep an account, an order or a backlog line belongs to, how each rep
  is tracking against goal, or whether the reps are using the portal at all.
  The admin has all of that (Execution, Goals, Reports, Activity); the
  person who actually manages the reps had none of it.

  What
  ----
  1. v_agency_rep_performance   the book at (rep, channel) grain: accounts,
                                revenue YTD / prior YTD / trailing 12m,
                                bookings, open orders, past promise, goal,
                                contact coverage. security_invoker — RLS is
                                the scope, exactly like the Reports views.
  2. agency_rep_activity()      who in the agency signs in and logs work.
                                SECURITY DEFINER: login_events and other
                                reps' profiles are not readable by a rep, and
                                this is the one place a principal is allowed
                                to see them — for their own agency's reps and
                                nobody else.
  3. report_agency_sales_by_month()
                                invoiced revenue per (month, rep) over the
                                book, for the month-over-month and
                                year-over-year chart.
  4. report_agency_large_orders()
                                the biggest uncancelled orders of the last N
                                days, each with the rep it belongs to.
  5. v_backlog_by_sku           gains the account's assigned rep (appended),
                                so the Backlog intel page can say whose store
                                is waiting.

  Scope, and the direction it fails
  ---------------------------------
  1, 3 and 4 are security invoker over tables whose RLS is
  my_customer_keys(), so they are the caller's book and nothing else: a
  principal sees their agency, a rep sees their own accounts cut by rep (one
  row, harmless), an empty book sees nothing. view-as follows for free.
  `p_vendor_id` / `.eq('vendor_id', …)` only NARROW that — an admin uses it
  to pick one agency out of the company; a principal passing someone else's
  vendor gets an empty result, because RLS already removed those rows.

  2 is the only new disclosure. It resolves the agency from the EFFECTIVE
  user (view-as aware, like every access rule since 20260816140000):
    - a principal (role rep, active, rep_group_vendor_id set) → their own
      vendor; p_vendor_id is ignored, so it cannot be widened;
    - an admin → p_vendor_id, and nothing at all without one;
    - anyone else → no rows.
  "In the agency" is the same two routes v_rep_group_performance's
  group_users recognises: a profile whose rep code bills through the vendor,
  or a co-principal of the vendor. Placeholder rep codes never count.
  Email addresses are deliberately not returned.

  Territory definition everywhere: active, external accounts (029/030),
  so every figure here reconciles with v_territory_account_yoy and the
  Overview's tiles.

  Additive only: new objects, and one view with appended columns.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The book at (rep, channel) grain.
--
--    Raw sums only, like v_channel_performance / v_rep_group_performance
--    (20260816120000): the Agency page rolls these rows up per rep for the
--    reps table, per channel for the channel table, and shows the grid of
--    both — every ratio is computed from sums, never averaged.
--
--    vendor_id is a GROUP BY key on purpose (it is a function of the rep),
--    so an admin's `.eq('vendor_id', X)` is pushed into the scan instead of
--    filtering a whole-company aggregate after the fact.
--------------------------------------------------------------------------
create or replace view public.v_agency_rep_performance
with (security_invoker = true)
as
with contact as (
    -- Last touch per account by ANYONE, once — same rule as
    -- v_rep_group_performance. RLS on actions keeps it to the book.
    select a.customer_key, max(a.action_date) as last_contact_date
    from public.actions a
    group by a.customer_key
),
book as (
    select
        c.assigned_sales_rep_id                               as sales_rep_key,
        -- dim_customer's name is the same ERP SALES_REP.NAME, carried for
        -- codes that are not in dim_sales_rep (retired, unsynced).
        coalesce(nullif(btrim(sr.sales_rep_name), ''),
                 nullif(btrim(c.assigned_sales_rep_name), ''),
                 c.assigned_sales_rep_id)                     as sales_rep_name,
        nullif(btrim(sr.vendor_id), '')                       as vendor_id,
        coalesce(nullif(btrim(c.customer_reporting_group), ''), 'Unclassified')
                                                              as channel,
        c.customer_key,
        coalesce(a.revenue_ytd, 0)::numeric                   as revenue_ytd,
        coalesce(a.revenue_prior_ytd, 0)::numeric             as revenue_prior_ytd,
        coalesce(a.revenue_trailing_12m, 0)::numeric          as revenue_trailing_12m,
        coalesce(a.revenue_prior_full, 0)::numeric            as revenue_prior_full,
        coalesce(a.bookings_ytd, 0)::numeric                  as bookings_ytd,
        coalesce(a.bookings_prior_ytd, 0)::numeric            as bookings_prior_ytd,
        coalesce(a.open_order_value, 0)::numeric              as open_order_value,
        coalesce(a.backlog_amount, 0)::numeric                as backlog_amount,
        a.first_invoice_date,
        a.last_invoice_date,
        -- Same precedence as v_rep_goal_dashboard: this year's CRM goal
        -- beats the ERP yearly goal on that account; either alone counts.
        coalesce(g.target_amount, c.yearly_sales_goal)        as goal_amount,
        ct.last_contact_date
    from erp.dim_customer c
    left join erp.dim_sales_rep sr
           on sr.sales_rep_key = c.assigned_sales_rep_id
    left join erp.agg_account_rollup a
           on a.customer_key = c.customer_key
    left join public.account_goals g
           on g.customer_key = c.customer_key
          and g.period_year = extract(year from current_date)::integer
    left join contact ct
           on ct.customer_key = c.customer_key
    where c.active_flag = 'Y'
      and coalesce(c.internal_customer_flag, 'N') <> 'Y'
)
select
    sales_rep_key,
    max(sales_rep_name)                                        as sales_rep_name,
    vendor_id,
    channel,
    count(*)::integer                                          as accounts,
    count(*) filter (where revenue_ytd > 0)::integer           as buying_accounts,
    -- Bought in last year's window, nothing this year.
    count(*) filter (
        where revenue_ytd <= 0 and revenue_prior_ytd > 0
    )::integer                                                 as lapsed_accounts,
    -- First invoice ever is this calendar year.
    count(*) filter (
        where first_invoice_date >= date_trunc('year', current_date)::date
    )::integer                                                 as new_accounts,
    count(*) filter (where goal_amount is not null)::integer   as accounts_with_goal,
    count(*) filter (
        where last_contact_date >= current_date - 30
    )::integer                                                 as contacted_30d,
    coalesce(sum(revenue_ytd), 0)::numeric                     as revenue_ytd,
    coalesce(sum(revenue_prior_ytd), 0)::numeric               as revenue_prior_ytd,
    coalesce(sum(revenue_trailing_12m), 0)::numeric            as revenue_trailing_12m,
    coalesce(sum(revenue_prior_full), 0)::numeric              as revenue_prior_full,
    coalesce(sum(bookings_ytd), 0)::numeric                    as bookings_ytd,
    coalesce(sum(bookings_prior_ytd), 0)::numeric              as bookings_prior_ytd,
    coalesce(sum(open_order_value), 0)::numeric                as open_order_value,
    coalesce(sum(backlog_amount), 0)::numeric                  as backlog_amount,
    coalesce(sum(goal_amount), 0)::numeric                     as goal_total,
    max(last_invoice_date)                                     as last_invoice_date
from book
group by sales_rep_key, vendor_id, channel;

comment on view public.v_agency_rep_performance is
  'The caller''s book (security_invoker — RLS is the scope) at (assigned '
  'rep, channel) grain over active external accounts: account counts, '
  'revenue YTD / prior YTD / trailing 12m / prior full year, bookings, open '
  'and past-promise order value, goal (CRM over ERP), and accounts touched '
  'in 30 days. Raw sums only; the Agency page rolls rows up per rep and per '
  'channel. vendor_id is the rep''s agency, for an admin''s filter. '
  '(20261026180000)';

revoke all on public.v_agency_rep_performance from anon, public;
grant select on public.v_agency_rep_performance to authenticated;

--------------------------------------------------------------------------
-- 2. Who in the agency is using the portal.
--------------------------------------------------------------------------
-- No deployed caller; the drop lets a re-run replace an earlier draft
-- whose OUT columns differ (create or replace cannot change them).
drop function if exists public.agency_rep_activity(text);

create or replace function public.agency_rep_activity(p_vendor_id text default null)
returns table (
    user_id          uuid,
    full_name        text,
    sales_rep_key    text,
    vendor_id        text,
    -- Signs in for the whole agency (profiles.rep_group_vendor_id).
    is_principal     boolean,
    active           boolean,
    last_login_at    timestamptz,
    logins_7d        bigint,
    logins_30d       bigint,
    -- Distinct business days with an app open — "is it a habit".
    active_days_30d  bigint,
    actions_30d      bigint,
    visits_30d       bigint,
    last_action_date date
)
language sql
stable
security definer
set search_path = ''
as $$
    with scope as (
        select case
                 when public.is_admin() then nullif(btrim(p_vendor_id), '')
                 else (
                   -- The EFFECTIVE user's own agency, never the argument.
                   -- Raw, like my_customer_keys(): the agency named here
                   -- is exactly the one their book derives from.
                   select p.rep_group_vendor_id
                   from public.profiles p
                   where p.user_id = public.effective_user_id()
                     and p.active
                     and p.role = 'rep'
                 )
               end as vendor_id
    ),
    members as (
        select m.user_id, bool_or(m.is_principal) as is_principal
        from (
            -- Principals of the agency (the caller among them).
            select p.user_id, true as is_principal
            from public.profiles p
            cross join scope s
            where s.vendor_id is not null
              and p.role = 'rep'
              and p.rep_group_vendor_id is not null
              and p.rep_group_vendor_id = s.vendor_id
            union all
            -- Reps whose own code bills through the agency.
            select p.user_id, false
            from public.profiles p
            join erp.dim_sales_rep sr on sr.sales_rep_key = p.sales_rep_key
            cross join scope s
            where s.vendor_id is not null
              and p.role = 'rep'
              and p.sales_rep_key is not null
              and sr.vendor_id is not null
              and sr.vendor_id = s.vendor_id
              and not (p.sales_rep_key = any (public.placeholder_rep_keys()))
        ) m
        group by m.user_id
    )
    select
        p.user_id,
        p.full_name,
        p.sales_rep_key,
        (select s.vendor_id from scope s),
        m.is_principal,
        p.active,
        (select max(le.logged_at) from public.login_events le
          where le.user_id = p.user_id),
        (select count(*) from public.login_events le
          where le.user_id = p.user_id
            and le.logged_at >= now() - interval '7 days'),
        (select count(*) from public.login_events le
          where le.user_id = p.user_id
            and le.logged_at >= now() - interval '30 days'),
        (select count(distinct (le.logged_at at time zone 'America/Denver')::date)
           from public.login_events le
          where le.user_id = p.user_id
            and le.logged_at >= now() - interval '30 days'),
        (select count(*) from public.actions a
          where a.user_id = p.user_id
            and a.action_date >= current_date - 30),
        (select count(*) from public.actions a
          where a.user_id = p.user_id
            and a.action_type = 'visit'
            and a.action_date >= current_date - 30),
        (select max(a.action_date) from public.actions a
          where a.user_id = p.user_id)
    from members m
    join public.profiles p on p.user_id = m.user_id
    order by m.is_principal desc, p.full_name, p.user_id;
$$;

comment on function public.agency_rep_activity(text) is
  'Portal activity (last active, app opens 7/30 days, active days, logged '
  'actions and visits) for every portal user in ONE agency: a principal''s '
  'own (from the effective user''s rep_group_vendor_id — p_vendor_id is '
  'ignored for them), or for an admin the vendor passed in (nothing without '
  'one). Members are co-principals of the vendor and reps whose code bills '
  'through it; placeholders never. SECURITY DEFINER because login_events '
  'and other reps'' profiles are not readable by a rep. No emails. '
  '(20261026180000)';

revoke execute on function public.agency_rep_activity(text) from public, anon;
grant execute on function public.agency_rep_activity(text) to authenticated;

--------------------------------------------------------------------------
-- 3. Invoiced revenue per (month, rep) over the book.
--
--    Same source and window arithmetic as report_sales_by_month
--    (20260817160000), one level finer. 24 months by default — always
--    reaches back to January of last year, which the Jan–Dec this-year-vs-
--    last-year chart needs. The page sums reps for the agency line.
--------------------------------------------------------------------------
drop function if exists public.report_agency_sales_by_month(int, text);

create or replace function public.report_agency_sales_by_month(
    p_months    int  default 24,
    p_vendor_id text default null
)
returns table (
    sales_month   date,
    sales_rep_key text,
    revenue       numeric,
    qty           numeric,
    invoice_count bigint,
    account_count bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
    select
        m.sales_month,
        c.assigned_sales_rep_id,
        coalesce(sum(m.revenue), 0),
        coalesce(sum(m.qty), 0),
        coalesce(sum(m.invoice_count), 0),
        count(distinct m.customer_key)
    from erp.agg_customer_month m
    join erp.dim_customer c on c.customer_key = m.customer_key
    left join erp.dim_sales_rep sr on sr.sales_rep_key = c.assigned_sales_rep_id
    where m.sales_month >= (date_trunc('month', current_date)
                            - make_interval(months => greatest(least(coalesce(p_months, 24), 48), 1) - 1))::date
      -- The territory definition every v_territory_* view uses.
      and c.active_flag = 'Y'
      and coalesce(c.internal_customer_flag, 'N') <> 'Y'
      and (nullif(btrim(p_vendor_id), '') is null
           or btrim(sr.vendor_id) = btrim(p_vendor_id))
    group by m.sales_month, c.assigned_sales_rep_id
    order by m.sales_month, c.assigned_sales_rep_id;
$$;

comment on function public.report_agency_sales_by_month(int, text) is
  'Invoiced revenue, units, invoices and buying accounts per (calendar '
  'month, assigned rep) over the caller''s book (security invoker; active '
  'external accounts), optionally one agency (p_vendor_id — narrows, never '
  'widens). Months clamped to [1, 48]; the newest is partial up to the last '
  'ETL load. The Agency page''s month-over-month / year-over-year chart. '
  '(20261026180000)';

revoke execute on function public.report_agency_sales_by_month(int, text) from public, anon;
grant execute on function public.report_agency_sales_by_month(int, text) to authenticated;

--------------------------------------------------------------------------
-- 4. The biggest orders of the last N days, with their rep.
--
--    Order headers from the facts (current even when the rollups are not),
--    cancelled orders (status X) out — the same rule as bookings and the
--    brief's largest_orders (20261013160000).
--------------------------------------------------------------------------
drop function if exists public.report_agency_large_orders(int, int, text);

create or replace function public.report_agency_large_orders(
    p_days      int  default 30,
    p_limit     int  default 15,
    p_vendor_id text default null
)
returns table (
    customer_key   text,
    customer_id    text,
    customer_name  text,
    order_id       text,
    order_date     date,
    amount         numeric,
    line_count     integer,
    has_open_lines boolean,
    sales_rep_key  text,
    sales_rep_name text
)
language sql
stable
security invoker
set search_path = ''
as $$
    with bounds as (
        select greatest(1, least(coalesce(p_days, 30), 365))  as days,
               greatest(1, least(coalesce(p_limit, 15), 50))  as lim,
               nullif(btrim(p_vendor_id), '')                 as vendor_id
    ),
    recent as (
        select o.customer_key,
               o.order_id,
               max(o.order_date)              as order_date,
               coalesce(sum(o.bookings), 0)   as amount,
               count(*)::integer              as line_count,
               bool_or(o.is_backlog_line)     as has_open_lines
        from erp.fact_order_line o
        join erp.dim_customer c on c.customer_key = o.customer_key
        left join erp.dim_sales_rep sr on sr.sales_rep_key = c.assigned_sales_rep_id
        cross join bounds b
        where o.order_date >= current_date - b.days
          and coalesce(o.order_status, '') <> 'X'
          and c.active_flag = 'Y'
          and coalesce(c.internal_customer_flag, 'N') <> 'Y'
          and (b.vendor_id is null or btrim(sr.vendor_id) = b.vendor_id)
        group by o.customer_key, o.order_id
    )
    select
        r.customer_key,
        c.customer_id,
        c.customer_name,
        r.order_id,
        r.order_date,
        r.amount,
        r.line_count,
        coalesce(r.has_open_lines, false),
        c.assigned_sales_rep_id,
        coalesce(nullif(btrim(sr.sales_rep_name), ''),
                 nullif(btrim(c.assigned_sales_rep_name), ''),
                 c.assigned_sales_rep_id)
    from recent r
    join erp.dim_customer c on c.customer_key = r.customer_key
    left join erp.dim_sales_rep sr on sr.sales_rep_key = c.assigned_sales_rep_id
    order by r.amount desc, r.order_id
    limit (select b.lim from bounds b);
$$;

comment on function public.report_agency_large_orders(int, int, text) is
  'The largest uncancelled orders (by booked value) placed in the last '
  'p_days (1..365) across the caller''s book (security invoker; active '
  'external accounts), top p_limit (1..50), each with the account''s '
  'assigned rep. p_vendor_id narrows to one agency. (20261026180000)';

revoke execute on function public.report_agency_large_orders(int, int, text) from public, anon;
grant execute on function public.report_agency_large_orders(int, int, text) to authenticated;

--------------------------------------------------------------------------
-- 5. v_backlog_by_sku gains the account's assigned rep (appended —
--    create-or-replace keeps every existing column's name, type and
--    position). Body restated verbatim from 031_backlog_ship_date.sql; the
--    two columns are functions of customer_key, so the grain is unchanged.
--------------------------------------------------------------------------
create or replace view public.v_backlog_by_sku
with (security_invoker = true)
as
select
    o.customer_key,
    c.customer_id,
    c.customer_name,
    o.part_key,
    p.part_id,
    p.part_description,
    p.product_family,
    p.chambering,
    coalesce(sum(o.backlog_qty), 0)::numeric       as backlog_qty,
    coalesce(sum(o.backlog_amount), 0)::numeric    as backlog_amount,
    count(*)::int                                  as open_line_count,
    min(o.promise_date)                            as earliest_promise_date,
    min(o.desired_ship_date)                       as earliest_desired_ship_date,
    max(o.order_date)                              as latest_order_date,
    c.assigned_sales_rep_id,
    c.assigned_sales_rep_name
from erp.fact_order_line o
join erp.dim_customer c on c.customer_key = o.customer_key
left join erp.dim_part p on p.part_key = o.part_key
where o.is_backlog_line
group by
    o.customer_key, c.customer_id, c.customer_name, o.part_key,
    p.part_id, p.part_description, p.product_family, p.chambering,
    c.assigned_sales_rep_id, c.assigned_sales_rep_name;

comment on view public.v_backlog_by_sku is
  'Open backlog rolled up to (account, SKU): qty, value, line count, '
  'earliest promise date, earliest desired ship date (surfaced as '
  '"estimated production date"), and the account''s assigned rep '
  '(20261026180000). security_invoker. Unfiltered = the caller''s territory '
  'backlog; .eq(customer_key) = one account''s card.';

revoke all on public.v_backlog_by_sku from anon, public;
grant select on public.v_backlog_by_sku to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Pure reads over objects that already exist — no ETL change, no
     refresh_territory_rollups() change, nothing to backfill, no new table
     (so nothing for the view-as trigger sweep).
  2. Run supabase/tests/20261026_agency_overview.sql against dev.
  3. Regenerate frontend/src/types/database.types.ts. Until then
     useAgency.ts reads these through the untyped-handle + isViewMissing
     convention the other report composables use.
  4. Sanity check as an admin, for one agency:
       select sum(revenue_ytd) from public.v_agency_rep_performance
        where vendor_id = '<VENDOR>';
       select revenue_ytd from public.v_rep_group_performance
        where rep_group_id = '<VENDOR>';
     The two must match.
----------------------------------------------------------------------------*/
