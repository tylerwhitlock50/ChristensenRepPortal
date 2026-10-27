/*============================================================================
  20261027120000_agency_review_fixes.sql — the Agency page's review fixes,
  as a forward migration over 20261026180000_agency_overview.sql (live
  since 2026-10-27 10:21; that file stays exactly as applied).

  Why
  ---
  A multi-agent review of the Agency page found, among smaller things:
    - agency_rep_activity() counted a member's logged actions on accounts
      outside the caller's book (revoked, house grants, other agencies)
      under definer rights. Logged actions are account data; they must stay
      inside my_customer_keys() exactly as the actions policy would keep
      them. Definer rights remain for logins and profiles only.
    - v_agency_rep_performance's goal disagreed with the Overview's Goal
      tile: it took the ERP goal even when zero and compared it against all
      revenue, at a straight-line pace.
    - admin_unmapped_reps() counted closed and internal accounts, so the
      Users page never offered "Make principal of <vendor>" to a code whose
      only accounts were closed — the shape that leaves a principal's book
      empty.

  What
  ----
  1. v_agency_rep_performance   restated from 20261026180000. Goal follows
                                v_account_goal_progress (this year's CRM
                                goal, else an ERP goal above zero); appended
                                goal_revenue_ytd, goal_expected (seasonal
                                pace) and workable_accounts (coverage leaves
                                out deactivated accounts). new_accounts
                                counts the rollup's year, not the wall
                                clock's.
  2. agency_rep_activity()      restated from 20261026180000. Action counts
                                limited to the caller's book; per-member
                                index range scans; an admin's vendor pick is
                                trimmed like v_rep_group_performance's.
  6. admin_unmapped_reps()      restated from LIVE = 20261026120000_unmapped_
                                rep_ignores.sql (body verbatim), gains
                                active_customer_count (appended). The return
                                type changes, hence drop + create.

  Section numbers follow 20261026180000 so the two read side by side.
  report_agency_sales_by_month(), report_agency_large_orders() and
  v_backlog_by_sku are untouched (v_backlog_by_sku was since restated by
  20261027090500_product_line_columns.sql and must not be clobbered).

  Additive only: one view and one function with appended columns, one
  function body tightened.
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
  'page''s narrowing filter. (20261026180000, 20261027120000)';

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
  'No emails. (20261026180000, 20261027120000)';

revoke execute on function public.agency_rep_activity(text) from public, anon;
grant execute on function public.agency_rep_activity(text) to authenticated;


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
  'what a book would show (20261027120000). Returns nothing unless the '
  'credential-holder is an active admin (is_real_admin — view-as does not '
  'matter here). Security definer because sales_rep_email is column-revoked '
  'from authenticated (20260901190300).';

revoke execute on function public.admin_unmapped_reps() from public, anon;
grant  execute on function public.admin_unmapped_reps() to authenticated;


/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Pure reads over objects that already exist — no ETL change, no
     refresh_territory_rollups() change, nothing to backfill, no new table.
  2. Run supabase/tests/20261026_agency_overview.sql and
     supabase/tests/20261026_unmapped_rep_ignores.sql against dev.
  3. Sanity check as an admin, for one agency:
       select sum(revenue_ytd) from public.v_agency_rep_performance
        where vendor_id = '<VENDOR>';
       select revenue_ytd from public.v_rep_group_performance
        where rep_group_id = '<VENDOR>';
     The two must match.
----------------------------------------------------------------------------*/
