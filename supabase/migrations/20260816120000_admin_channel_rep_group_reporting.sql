/*============================================================================
  20260816120000_admin_channel_rep_group_reporting.sql — two admin rollups:
  how each CHANNEL is doing, and how each REP GROUP is doing.

  The ask: the admin section reports per rep (v_rep_goal_dashboard) and per
  account (v_territory_account_yoy), but nothing answers "which channels are
  carrying the year" or "how is each agency doing overall". Both dimensions
  already exist and neither was ever aggregated:

    channel    erp.dim_customer.customer_reporting_group /
               customer_reporting_sub_group — the governed reporting
               hierarchy landed by 032 (Big Box, Distribution, Buy Group,
               Dealer, Direct to Consumer, Special Programs, International,
               Internal, Other). Descriptive only; owned upstream by
               bi.vw_DimCustomer, never re-derived here.
    rep group  erp.dim_sales_rep.vendor_id — the agency a rep bills through.
               This is the SAME key profiles.rep_group_vendor_id points at
               (003 / 010: a principal's book is every account whose assigned
               rep shares their vendor), so a group's number here is exactly
               the book its principal signs in and sees.

  Both views are grouped rollups over erp.agg_account_rollup (~41k rows,
  rebuilt nightly by refresh_territory_rollups) — never the 500k-row fact
  tables. That is the whole point of 030 and these views keep it: a group-by
  over 41k indexed rows, not a re-aggregation per page load.

  Measures are RAW SUMS ONLY. Every ratio the screens show (YoY %, share of
  book, goal attainment) is computed in the UI from these sums, so rolling
  sub-channels up into a channel — which the Reports tab does client-side —
  can never produce an average-of-averages.

  Account scope is the territory definition every other rollup surface uses
  (029/030/20260808): active, external accounts. Deliberately NOT excluding
  public.account_deactivations — a deactivation is a CRM working-list
  decision, and revenue that shipped is still revenue on the channel's year.

  security_invoker like every other reporting view: an admin resolves the
  whole company, a rep would resolve their own book aggregated the same way
  (harmless, and the /admin route is admin-only regardless).
============================================================================*/

--------------------------------------------------------------------------
-- 1. Channel performance — grain: (channel, sub_channel).
--
--    Emitted at SUB-channel grain on purpose: it is one round trip, and the
--    Reports tab sums these rows for the channel-level table and shows the
--    same rows as the drill-in. A channel-grain view would have been a
--    second query returning numbers the client can add up itself.
--------------------------------------------------------------------------
create or replace view public.v_channel_performance
with (security_invoker = true)
as
with book as (
    select
        -- The hierarchy is nullable on any customer landed before 032's
        -- columns started flowing; those rows are a real bucket, not a gap
        -- to hide, so they surface as Unclassified rather than disappearing.
        coalesce(nullif(btrim(c.customer_reporting_group), ''), 'Unclassified')
                                                     as channel,
        coalesce(nullif(btrim(c.customer_reporting_sub_group), ''), 'Unclassified')
                                                     as sub_channel,
        c.customer_key,
        c.account_open_date,
        coalesce(a.revenue_ytd, 0)::numeric          as revenue_ytd,
        coalesce(a.revenue_prior_ytd, 0)::numeric    as revenue_prior_ytd,
        coalesce(a.revenue_trailing_12m, 0)::numeric as revenue_trailing_12m,
        coalesce(a.bookings_ytd, 0)::numeric         as bookings_ytd,
        coalesce(a.open_order_value, 0)::numeric     as open_order_value,
        coalesce(a.backlog_amount, 0)::numeric       as backlog_amount,
        a.last_invoice_date,
        -- Same precedence as v_rep_goal_dashboard: a CRM goal for this year
        -- beats the ERP yearly goal on that account; either alone counts.
        coalesce(g.target_amount, c.yearly_sales_goal) as goal_amount
    from erp.dim_customer c
    left join erp.agg_account_rollup a
           on a.customer_key = c.customer_key
    left join public.account_goals g
           on g.customer_key = c.customer_key
          and g.period_year = extract(year from current_date)::integer
    where c.active_flag = 'Y'
      and coalesce(c.internal_customer_flag, 'N') <> 'Y'
)
select
    channel,
    sub_channel,
    count(*)::integer                                          as accounts,
    count(*) filter (where revenue_ytd > 0)::integer           as buying_accounts,
    -- Bought last year through today, nothing this year: the churn signal
    -- that a channel total alone hides.
    count(*) filter (
        where revenue_ytd <= 0 and revenue_prior_ytd > 0
    )::integer                                                 as lapsed_accounts,
    count(*) filter (
        where account_open_date >= date_trunc('year', current_date)::date
    )::integer                                                 as new_accounts,
    count(*) filter (where goal_amount is not null)::integer   as accounts_with_goal,
    coalesce(sum(revenue_ytd), 0)::numeric                     as revenue_ytd,
    coalesce(sum(revenue_prior_ytd), 0)::numeric               as revenue_prior_ytd,
    coalesce(sum(revenue_trailing_12m), 0)::numeric            as revenue_trailing_12m,
    coalesce(sum(bookings_ytd), 0)::numeric                    as bookings_ytd,
    coalesce(sum(open_order_value), 0)::numeric                as open_order_value,
    coalesce(sum(backlog_amount), 0)::numeric                  as backlog_amount,
    coalesce(sum(goal_amount), 0)::numeric                     as goal_total,
    max(last_invoice_date)                                     as last_invoice_date
from book
group by channel, sub_channel;

comment on view public.v_channel_performance is
  'Channel rollup for the admin Reports tab. Grain: (channel, sub_channel) '
  'from erp.dim_customer''s governed reporting hierarchy (customer_reporting_'
  'group / _sub_group), over active external accounts, measured from '
  'erp.agg_account_rollup (nightly). Raw sums only — YoY, share and '
  'attainment are derived in the UI so sub-channels roll up cleanly. '
  'security_invoker.';

revoke all on public.v_channel_performance from anon, public;
grant select on public.v_channel_performance to authenticated;

--------------------------------------------------------------------------
-- 2. Rep group performance — grain: erp.dim_sales_rep.vendor_id.
--
--    An account belongs to the group of the rep it is assigned to. Reps with
--    no vendor (41 of 138 at last count) and accounts whose assigned rep is
--    not in dim_sales_rep at all fall into one honest "(No rep group)"
--    bucket rather than being dropped from the company total.
--------------------------------------------------------------------------
create or replace view public.v_rep_group_performance
with (security_invoker = true)
as
with contact as (
    -- Last touch per account by ANYONE. account_coverage is per (account,
    -- user), which double-counts an account two people in a group both
    -- worked; a group's coverage is "was the account touched", once.
    select a.customer_key, max(a.action_date) as last_contact_date
    from public.actions a
    group by a.customer_key
),
group_users as (
    -- Portal logins attached to a group, by either route the access rules
    -- recognise: the principal's vendor, or an individual rep code that
    -- belongs to a rep in that vendor. UNION (not an OR-join) so a user who
    -- matches both ways is one user, not two.
    select distinct vendor_id, user_id, full_name
    from (
        select sr.vendor_id, p.user_id, p.full_name
        from public.profiles p
        join erp.dim_sales_rep sr on sr.vendor_id = p.rep_group_vendor_id
        where p.active
          and p.rep_group_vendor_id is not null
          and sr.vendor_id is not null
        union
        select sr.vendor_id, p.user_id, p.full_name
        from public.profiles p
        join erp.dim_sales_rep sr on sr.sales_rep_key = p.sales_rep_key
        where p.active
          and p.sales_rep_key is not null
          and not (p.sales_rep_key = any (public.placeholder_rep_keys()))
    ) u
),
users_by_group as (
    select
        coalesce(nullif(btrim(vendor_id), ''), '(No rep group)') as rep_group_id,
        count(distinct user_id)::integer                         as portal_users,
        string_agg(distinct full_name, ', ' order by full_name)  as portal_user_names
    from group_users
    group by 1
),
book as (
    select
        coalesce(nullif(btrim(sr.vendor_id), ''), '(No rep group)') as rep_group_id,
        c.customer_key,
        c.assigned_sales_rep_id,
        -- An account can carry a rep code that is not in dim_sales_rep (a
        -- retired code, an unsynced one). It still counts toward rep_count,
        -- so show the bare code rather than counting a rep with no name.
        coalesce(sr.sales_rep_name, c.assigned_sales_rep_id) as sales_rep_name,
        coalesce(a.revenue_ytd, 0)::numeric          as revenue_ytd,
        coalesce(a.revenue_prior_ytd, 0)::numeric    as revenue_prior_ytd,
        coalesce(a.revenue_trailing_12m, 0)::numeric as revenue_trailing_12m,
        coalesce(a.bookings_ytd, 0)::numeric         as bookings_ytd,
        coalesce(a.open_order_value, 0)::numeric     as open_order_value,
        coalesce(a.backlog_amount, 0)::numeric       as backlog_amount,
        a.last_invoice_date,
        coalesce(g.target_amount, c.yearly_sales_goal) as goal_amount,
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
),
rollup as (
    select
        rep_group_id,
        count(distinct assigned_sales_rep_id)::integer             as rep_count,
        string_agg(distinct sales_rep_name, ', ' order by sales_rep_name)
                                                                   as rep_names,
        count(*)::integer                                          as accounts,
        count(*) filter (where revenue_ytd > 0)::integer           as buying_accounts,
        count(*) filter (
            where revenue_ytd <= 0 and revenue_prior_ytd > 0
        )::integer                                                 as lapsed_accounts,
        count(*) filter (where goal_amount is not null)::integer   as accounts_with_goal,
        count(*) filter (
            where last_contact_date >= current_date - 30
        )::integer                                                 as contacted_30d,
        count(*) filter (
            where last_contact_date >= current_date - 90
        )::integer                                                 as contacted_90d,
        coalesce(sum(revenue_ytd), 0)::numeric                     as revenue_ytd,
        coalesce(sum(revenue_prior_ytd), 0)::numeric               as revenue_prior_ytd,
        coalesce(sum(revenue_trailing_12m), 0)::numeric            as revenue_trailing_12m,
        coalesce(sum(bookings_ytd), 0)::numeric                    as bookings_ytd,
        coalesce(sum(open_order_value), 0)::numeric                as open_order_value,
        coalesce(sum(backlog_amount), 0)::numeric                  as backlog_amount,
        coalesce(sum(goal_amount), 0)::numeric                     as goal_total,
        max(last_invoice_date)                                     as last_invoice_date
    from book
    group by rep_group_id
)
select
    r.rep_group_id,
    coalesce(u.portal_users, 0)                                    as portal_users,
    u.portal_user_names,
    r.rep_count,
    r.rep_names,
    r.accounts,
    r.buying_accounts,
    r.lapsed_accounts,
    r.accounts_with_goal,
    r.contacted_30d,
    r.contacted_90d,
    r.revenue_ytd,
    r.revenue_prior_ytd,
    r.revenue_trailing_12m,
    r.bookings_ytd,
    r.open_order_value,
    r.backlog_amount,
    r.goal_total,
    r.last_invoice_date
from rollup r
left join users_by_group u on u.rep_group_id = r.rep_group_id;

comment on view public.v_rep_group_performance is
  'Rep-group (agency) rollup for the admin Reports tab. Grain: '
  'erp.dim_sales_rep.vendor_id — the same key profiles.rep_group_vendor_id '
  'grants a principal their book through — over active external accounts, '
  'measured from erp.agg_account_rollup (nightly) plus CRM contact recency '
  'from public.actions. Accounts whose assigned rep has no vendor land in '
  '"(No rep group)" so the rows still add to the company total. Raw sums '
  'only; ratios are derived in the UI. security_invoker.';

revoke all on public.v_rep_group_performance from anon, public;
grant select on public.v_rep_group_performance to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Both views are pure reads over objects that already exist — no ETL
     change, no refresh_territory_rollups() change, nothing to backfill.
  2. Regenerate frontend/src/types/database.types.ts. Until then
     useAdminReports.ts reads them through the same untyped-handle +
     isViewMissing convention useAdmin.ts already uses.
  3. Sanity check after applying (as an admin):
       select channel, accounts, revenue_ytd
         from public.v_channel_performance order by revenue_ytd desc;
       select rep_group_id, accounts, revenue_ytd
         from public.v_rep_group_performance order by revenue_ytd desc;
     The two revenue_ytd totals must match each other and
     `select sum(revenue_ytd) from public.v_territory_account_yoy;` — all
     three carry the same active/external scope.
----------------------------------------------------------------------------*/
