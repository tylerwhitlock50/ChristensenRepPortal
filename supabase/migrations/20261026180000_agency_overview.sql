/*============================================================================
  20261026180000_agency_overview.sql — what a rep-group principal needs to
  run their agency from the portal.

  Why
  ---
  A principal's book already holds their agency (003/010: every account
  whose assigned rep bills through profiles.rep_group_vendor_id, less any
  revoked from them — plus their own rep code's accounts and any explicit
  grants), but every screen they could open reads that book as ONE
  territory. Nothing said
  which rep an account, an order or a backlog line belongs to, how each rep
  is tracking against goal, or whether the reps are using the portal at all.
  The admin has all of that (Execution, Goals, Reports, Activity); the
  person who actually manages the reps had none of it.

  What
  ----
  1. v_agency_rep_performance   the book at (rep, channel) grain: accounts,
                                revenue YTD / prior YTD / trailing 12m,
                                bookings, open orders, past promise, goal
                                with its seasonal pace, contact coverage.
                                security_invoker — RLS is the scope, exactly
                                like the Reports views.
  2. agency_rep_activity()      who in the agency signs in and logs work.
                                SECURITY DEFINER: login_events and other
                                reps' profiles are not readable by a rep, and
                                this is the one place a principal is allowed
                                to see them — for their own agency's reps and
                                nobody else. Logged actions are account data,
                                so those counts stay inside the caller's book
                                exactly as the actions policy would keep them.
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
  6. admin_unmapped_reps()      gains active_customer_count (appended): the
                                Users page offers "Make principal of <vendor>"
                                when a rep code carries no ACTIVE accounts,
                                which is what leaves a principal's book empty.

  Scope, and the direction it fails
  ---------------------------------
  1, 3 and 4 are security invoker over tables whose RLS is
  my_customer_keys(), so they are the caller's book and nothing else: a
  principal sees their agency, a rep sees their own accounts cut by rep (one
  row, harmless), an empty book sees nothing. view-as follows for free.
  `p_vendor_id` / `.eq('vendor_id', …)` only NARROW that, and the narrowing
  is load-bearing: the Agency page always passes one — an admin's pick out
  of the company, or the principal's own vendor, because a principal's book
  also holds their own rep code's accounts and any explicit grants, which
  are not the agency's. A vendor can never widen past the book: a principal
  naming another agency gets only what of it they already hold by grant
  (usually nothing).

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

  Territory definition everywhere: active, external accounts (029/030), so
  the revenue, bookings and backlog figures reconcile with
  v_territory_account_yoy. Goal attainment uses v_account_goal_progress's
  rules — this year's CRM goal, else an ERP goal above zero, revenue counted
  on those accounts only, seasonal pace — over the same active external
  accounts. The Overview's Goal tile applies the same rules to the whole
  book, so it also counts goals on closed or internal accounts and on a
  principal's own or granted accounts outside the agency: the two are
  close, not identical.

  Additive only: new objects, one view and one function with appended
  columns.
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
--
--    Goal columns use v_account_goal_progress's rules over these active
--    external accounts: goal_total over goal accounts, goal_revenue_ytd =
--    revenue on those same accounts, goal_expected = what should be in by
--    today at each account's own seasonal pace. (The Overview's tile counts
--    the whole book — closed and internal goal accounts too — so it can
--    differ by those.) Coverage (contacted_30d / workable_accounts) leaves
--    out accounts a rep has deactivated, like every coverage surface (023);
--    revenue keeps them — what shipped is still the agency's year.
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
        -- v_account_goal_progress's rule: this year's CRM goal, else the
        -- ERP yearly goal when it is above zero.
        coalesce(g.target_amount,
                 case when c.yearly_sales_goal > 0 then c.yearly_sales_goal end)
                                                              as goal_amount,
        -- Seasonal pace, as v_account_goal_progress computes it for the
        -- current year: the share of last year's revenue that was in by
        -- this date, or the share of the year gone without a last year.
        case
            when coalesce(a.revenue_prior_full, 0) > 0 then
                least(greatest(coalesce(a.revenue_prior_ytd, 0)
                               / a.revenue_prior_full, 0), 1)
            else
                (current_date - date_trunc('year', current_date)::date + 1)::numeric
                / (make_date(extract(year from current_date)::int, 12, 31)
                   - date_trunc('year', current_date)::date + 1)
        end                                                   as expected_frac,
        -- The year this account's YTD was built in (the brief's rule,
        -- 20261013160000): a December rollup read in January is last year's.
        date_trunc('year', coalesce((a.refreshed_at at time zone 'America/Denver')::date,
                                    current_date))::date      as rollup_year_start,
        exists (
            select 1 from public.account_deactivations d
            where d.customer_key = c.customer_key
              and d.reactivated_at is null
        )                                                     as deactivated,
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
    -- First invoice ever is in the rollup's year.
    count(*) filter (
        where first_invoice_date >= rollup_year_start
    )::integer                                                 as new_accounts,
    count(*) filter (where goal_amount is not null)::integer   as accounts_with_goal,
    -- Touched in 30 days, among the accounts still being worked.
    count(*) filter (
        where not deactivated and last_contact_date >= current_date - 30
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
    max(last_invoice_date)                                     as last_invoice_date,
    coalesce(sum(revenue_ytd) filter (where goal_amount is not null), 0)::numeric
                                                               as goal_revenue_ytd,
    coalesce(sum(goal_amount * expected_frac)
               filter (where goal_amount is not null), 0)::numeric
                                                               as goal_expected,
    -- The coverage denominator: active accounts nobody has deactivated.
    count(*) filter (where not deactivated)::integer           as workable_accounts
from book
group by sales_rep_key, vendor_id, channel;

comment on view public.v_agency_rep_performance is
  'The caller''s book (security_invoker — RLS is the scope) at (assigned '
  'rep, channel) grain over active external accounts: account counts, '
  'revenue YTD / prior YTD / trailing 12m / prior full year, bookings, open '
  'and past-promise order value; goal_total, goal_revenue_ytd and '
  'goal_expected on v_account_goal_progress''s rules (CRM goal, else an ERP '
  'goal > 0; seasonal pace) over these active external accounts; '
  'contacted_30d over workable_accounts '
  '(deactivated accounts left out). Raw sums only; the Agency page rolls rows '
  'up per rep and per channel. vendor_id is the rep''s agency, the Agency '
  'page''s narrowing filter. (20261026180000)';

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
               end as vendor_id,
               public.is_admin() as by_admin
    ),
    -- What the caller may read of public.actions under its own policy
    -- (is_admin() or customer_key in my_customer_keys()). Definer rights are
    -- for logins and profiles only; a member's work on an account outside
    -- this book — revoked from the principal, a house grant, another
    -- agency's — is not the principal's to count. Materialized once; the
    -- per-member lookups below probe it.
    book as materialized (
        select k as customer_key from public.my_customer_keys() k
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
              -- An admin's pick comes from v_rep_group_performance, which
              -- trims; a principal's own match stays raw, like their book.
              and case when s.by_admin
                       then btrim(p.rep_group_vendor_id) = s.vendor_id
                       else p.rep_group_vendor_id = s.vendor_id
                  end
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
              and case when s.by_admin
                       then btrim(sr.vendor_id) = s.vendor_id
                       else sr.vendor_id = s.vendor_id
                  end
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
        -- Per member, through idx_actions_user (user_id, action_date desc):
        -- bounded range scans and a first row, never the whole company's
        -- actions. Each keeps only what the caller's book may read.
        (select count(*) from public.actions a
          where a.user_id = p.user_id
            and a.action_date >= current_date - 30
            and ((select s.by_admin from scope s)
                 or a.customer_key in (select b.customer_key from book b))),
        (select count(*) from public.actions a
          where a.user_id = p.user_id
            and a.action_date >= current_date - 30
            and a.action_type = 'visit'
            and ((select s.by_admin from scope s)
                 or a.customer_key in (select b.customer_key from book b))),
        (select a.action_date from public.actions a
          where a.user_id = p.user_id
            and ((select s.by_admin from scope s)
                 or a.customer_key in (select b.customer_key from book b))
          order by a.action_date desc
          limit 1)
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
  'and other reps'' profiles are not readable by a rep; logged actions are '
  'counted only on accounts the caller could read under the actions policy. '
  'No emails. (20261026180000)';

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

--------------------------------------------------------------------------
-- 6. admin_unmapped_reps() gains active_customer_count (appended).
--
--    customer_count counts every dim_customer row on the code, closed and
--    internal accounts included, but a book only ever shows active external
--    ones (029). A principal whose own code still carries one closed dealer
--    signed in to an empty book all the same, and the Users page's
--    "Make principal of <vendor>" hint never offered itself for them.
--    Body restated verbatim from 20261026120000_unmapped_rep_ignores.sql;
--    the return type changes, hence drop + create.
--------------------------------------------------------------------------
drop function if exists public.admin_unmapped_reps();

create function public.admin_unmapped_reps()
returns table (
  sales_rep_key          text,
  sales_rep_name         text,
  sales_rep_email        text,
  vendor_id              text,
  sales_rep_type         text,
  customer_count         bigint,
  is_placeholder         boolean,
  email_profile_user_id  uuid,
  email_profile_name     text,
  ignored                boolean,
  ignore_note            text,
  active_customer_count  bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.sales_rep_key,
    r.sales_rep_name,
    nullif(lower(trim(r.sales_rep_email)), '')                as sales_rep_email,
    r.vendor_id,
    r.sales_rep_type,
    (select count(*)
       from erp.dim_customer c
      where c.assigned_sales_rep_id = r.sales_rep_key)         as customer_count,
    (coalesce(r.is_placeholder_rep, false)
      or coalesce(r.is_unknown_sales_rep, false)
      or r.sales_rep_key = any (public.placeholder_rep_keys())) as is_placeholder,
    p.user_id                                                   as email_profile_user_id,
    p.full_name                                                 as email_profile_name,
    (i.sales_rep_key is not null)                               as ignored,
    i.note                                                      as ignore_note,
    -- The territory definition (029): what this code alone would put in a
    -- book.
    (select count(*)
       from erp.dim_customer c
      where c.assigned_sales_rep_id = r.sales_rep_key
        and c.active_flag = 'Y'
        and coalesce(c.internal_customer_flag, 'N') <> 'Y')    as active_customer_count
  from erp.dim_sales_rep r
  left join lateral (
    select p.user_id, p.full_name
      from public.profiles p
     where nullif(lower(trim(r.sales_rep_email)), '') is not null
       and lower(p.email) = lower(trim(r.sales_rep_email))
     order by p.created_at, p.user_id
     limit 1
  ) p on true
  left join public.unmapped_rep_ignores i
    on i.sales_rep_key = r.sales_rep_key
  where public.is_real_admin()
    and not exists (
      select 1 from public.profiles m
       where m.sales_rep_key = r.sales_rep_key
    )
  order by customer_count desc, r.sales_rep_name, r.sales_rep_key;
$$;

comment on function public.admin_unmapped_reps() is
  'ERP reps with no profile carrying their sales_rep_key, with the ERP email '
  'so an admin can create the account from the row, `ignored` when the '
  'admin has parked the rep in unmapped_rep_ignores, and '
  'active_customer_count — the active external accounts the code carries, '
  'what a book would show (20261026180000). Returns nothing unless the '
  'credential-holder is an active admin (is_real_admin — view-as does not '
  'matter here). Security definer because sales_rep_email is column-revoked '
  'from authenticated (20260901190300).';

revoke execute on function public.admin_unmapped_reps() from public, anon;
grant  execute on function public.admin_unmapped_reps() to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Pure reads over objects that already exist — no ETL change, no
     refresh_territory_rollups() change, nothing to backfill, no new table
     (so nothing for the view-as trigger sweep).
  2. Run supabase/tests/20261026_agency_overview.sql and
     supabase/tests/20261026_unmapped_rep_ignores.sql against dev.
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
