/*============================================================================
  023_account_goals.sql
  Purpose: A revenue goal the REP sets for an account, and the read path that
           reports against it.

           erp.dim_customer.yearly_sales_goal already ships a goal, and the
           account header has been showing it. It is an ERP field: nobody in
           the field can change it, it carries no note explaining what it
           assumes, and it is empty — measured on dev while writing this,
           2026-08-03: 0 of 41,556 customers have a value, in the parsed
           column OR in yearly_sales_goal_raw. So the header's "Goal" tile has
           been rendering a dash for every account in the book. This migration
           adds the goal the rep actually commits to, without touching the ERP.

           (Both columns being empty means the source view isn't carrying the
           field, not that the ETL's numeric parse is dropping it. Worth a look
           on the SQL Server side if the ERP goal is supposed to be populated.)

  ── One row per (account, year). Not per rep ───────────────────────────────
  The goal belongs to the ACCOUNT, not to whoever typed it. A principal and
  their rep both work the same dealer and must see the same number, and the
  admin has to be able to roll goals up without deciding whose copy counts.
  `unique (customer_key, period_year)` is what makes "the goal" a well-defined
  thing to report against; created_by/updated_by record who touched it.

  ── Nothing here writes to the ERP ─────────────────────────────────────────
  Same hard rule as everywhere else (README): erp.* is ETL-owned and the app
  has SELECT only. This is a public.* table keyed by customer_key with no FK
  across schemas, because the erp side is truncate-and-loaded. If these goals
  are ever pushed INTO Visual, that is an outbound job reading this table —
  (customer_key, period_year, target_amount) maps straight onto the ERP's own
  yearly goal field — and not a write from this app.

  ── Pace is seasonal, not straight-line ────────────────────────────────────
  v_account_goal_progress reports "ahead/behind pace", and on a straight line
  that verb is wrong for this business. A dealer that books most of its year
  in the order season is not behind in June, and telling a rep it is trains
  them to ignore the number. So the expected fraction of the goal by today is
  taken from the ACCOUNT'S OWN prior-year shape — what share of last year's
  revenue had landed by this day of the year — and only falls back to
  days-elapsed/days-in-year when there is no prior year to learn from. The
  view says which basis it used in `pace_basis` so the UI can too.

  ── The revenue side reuses the certified measure ──────────────────────────
  Progress is erp.fact_invoice_line.revenue with `is_memo is not true` — the
  same REVENUE headline v_account_summary reports YTD (011), spelled the same
  NULL-safe way for the same reason. A goal card that disagreed with the
  Performance card two inches above it would be worse than no goal card.

  ── security_invoker, as always ────────────────────────────────────────────
  Every view here reads erp fact/dim tables. Without
  `with (security_invoker = true)` they would execute as their owner — the
  migration role, which owns those tables and is exempt from their policies —
  and hand every dealer's revenue to every rep. Write that line before you
  write the select (011 header, TECH_STACK §1).
============================================================================*/

--------------------------------------------------------------------------
-- account_goals
--
-- target_amount is `> 0`: a zero goal and no goal are the same statement,
-- and allowing zero would put a divide-by-zero in every attainment
-- calculation downstream. Removing a goal is a DELETE.
--
-- period_year is a plain int, not a date range. The whole product reports on
-- calendar years (revenue_ytd, revenue_prior_ytd), the ERP's own goal field
-- is annual, and a range would let two overlapping goals exist for one
-- account with no way to say which one "the goal" is.
--------------------------------------------------------------------------
create table if not exists public.account_goals (
    id            bigint generated always as identity primary key,
    customer_key  text not null,
    period_year   int  not null check (period_year between 2000 and 2100),
    target_amount numeric(18,2) not null check (target_amount > 0),
    note          text,                  -- why this number: "adding the ATV line in Q2"
    created_by    uuid not null default auth.uid() references public.profiles (user_id),
    updated_by    uuid references public.profiles (user_id),
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    constraint uq_account_goal_year unique (customer_key, period_year)
);
alter table public.account_goals enable row level security;

comment on table public.account_goals is
  'Rep-entered annual revenue goal per account. One row per '
  '(customer_key, period_year) — the goal belongs to the account, not to the '
  'user who typed it. Reported against by public.v_account_goal_progress. '
  'Never written to the ERP by this app; an outbound job may read it.';

--------------------------------------------------------------------------
-- RLS. Same shape as contacts/notes (010): account-scoped, and written in
-- the `(select public.is_admin()) or customer_key in (select
-- public.my_customer_keys())` form so the helpers are evaluated once per
-- query rather than once per row.
--
-- Reps CAN delete here, unlike notes/contacts/photos. Those are a log — an
-- account's history, where deletion destroys the record of what happened.
-- A goal is a single mutable number, and UPDATE on it is already
-- unrestricted: a rep who can silently change 85,000 to 5,000 gains nothing
-- from also being able to remove the row. Making them phone sales ops to
-- clear a goal typed against the wrong account would just leave wrong goals
-- in place.
--------------------------------------------------------------------------
drop policy if exists "read account goals" on public.account_goals;
create policy "read account goals" on public.account_goals
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "write account goals" on public.account_goals;
create policy "write account goals" on public.account_goals
  for insert to authenticated
  with check (
    ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
    and created_by = (select auth.uid())
  );

drop policy if exists "update account goals" on public.account_goals;
create policy "update account goals" on public.account_goals
  for update to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
  with check ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "delete account goals" on public.account_goals;
create policy "delete account goals" on public.account_goals
  for delete to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

--------------------------------------------------------------------------
-- Audit stamp. touch_updated_at() (004) only maintains updated_at; a goal
-- also has to record WHO moved the number, since anyone on the account can.
-- search_path is pinned to '' per 017 — the body is fully qualified — and
-- EXECUTE is revoked for the same reason the other trigger functions have
-- it revoked: nothing should be able to reach it as an RPC.
--------------------------------------------------------------------------
create or replace function public.touch_account_goal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

revoke execute on function public.touch_account_goal() from public, anon, authenticated;

drop trigger if exists trg_account_goals_touch on public.account_goals;
create trigger trg_account_goals_touch before update on public.account_goals
  for each row execute function public.touch_account_goal();

--------------------------------------------------------------------------
-- Grants. Supabase's default privileges hand `anon` full DML on new tables
-- in public. RLS already returns anon nothing (every policy above is `to
-- authenticated`), but a signed-out caller has no business reaching the
-- relation at all — same defence in depth as the view grants in 011.
--------------------------------------------------------------------------
revoke all on public.account_goals from anon, public;
grant select, insert, update, delete on public.account_goals to authenticated;

--------------------------------------------------------------------------
-- v_account_goal_progress
--   Grain: one row per goal (account × year), with the revenue earned
--          against it and where that stands versus pace.
--
--   Driven off public.account_goals, which is the small table: only accounts
--   somebody actually set a goal on appear. That is what makes it safe to
--   select this view for a whole book — the fact scan runs once per GOAL,
--   not once per account in the ERP.
--
--   The date arithmetic is done in cross-join LATERALs rather than repeated
--   inline: each one names a value the next one uses, and `make_date` spelled
--   out five times in a select list is where an off-by-one hides. They are
--   plain subqueries in the FROM list, not CTEs, so the planner pulls them up
--   and a caller's `where customer_key = $1` still reaches the unique index
--   on account_goals.
--
--   A goal for a FUTURE year is legal (a rep planning next season). It
--   reports days_elapsed 0, revenue 0, pace_basis 'not_started', and a NULL
--   on_track — "no opinion yet" rather than a triumphant 0% behind.
--------------------------------------------------------------------------
create or replace view public.v_account_goal_progress
with (security_invoker = true)
as
select
    r.goal_id,
    r.customer_key,
    r.customer_name,
    r.sold_to_city,
    r.sold_to_state,
    r.active_flag,
    r.period_year,
    r.target_amount,
    r.note,
    r.created_by,
    r.updated_by,
    r.updated_at,
    r.erp_yearly_sales_goal,
    r.period_start,
    r.period_end,
    r.as_of,
    r.days_elapsed,
    r.days_total,
    greatest(r.days_total - r.days_elapsed, 0)                       as days_remaining,
    r.revenue_to_date,
    r.pace_basis,
    -- Attainment: the headline number. target_amount > 0 by CHECK.
    round(100 * r.revenue_to_date / r.target_amount, 1)              as attainment_pct,
    -- Where the account "should" be today, on its own seasonal shape.
    round(100 * r.expected_frac, 1)                                  as expected_pct,
    round(r.target_amount * r.expected_frac, 2)                      as expected_amount,
    round(r.revenue_to_date - r.target_amount * r.expected_frac, 2)  as gap_to_pace,
    round(greatest(r.target_amount - r.revenue_to_date, 0), 2)       as gap_to_goal,
    -- Straight extrapolation of today's run rate onto the full year.
    case when r.expected_frac > 0
         then round(r.revenue_to_date / r.expected_frac, 2)
    end                                                              as projected_amount,
    -- NULL while the period has not started: no basis to judge, never false.
    case when r.days_elapsed = 0 then null
         else r.revenue_to_date >= r.target_amount * r.expected_frac
    end                                                              as on_track
from (
    select
        g.id                                          as goal_id,
        g.customer_key,
        c.customer_name,
        c.sold_to_city,
        c.sold_to_state,
        c.active_flag,
        c.yearly_sales_goal                           as erp_yearly_sales_goal,
        g.period_year,
        g.target_amount,
        g.note,
        g.created_by,
        g.updated_by,
        g.updated_at,
        d.period_start,
        d.period_end,
        w.as_of,
        w.days_total,
        e.days_elapsed,
        coalesce(rev.revenue_to_date, 0)::numeric     as revenue_to_date,
        case
            when e.days_elapsed = 0                   then 'not_started'
            when coalesce(rev.prior_full, 0) > 0      then 'seasonal'
            else 'straight_line'
        end                                           as pace_basis,
        -- The share of the year's goal that "should" be in by as_of.
        -- Seasonal: the share of last year's revenue that had landed by the
        -- same day. Clamped to 0..1 — a prior year with credits could put
        -- the raw ratio outside it, and a pace over 100% is meaningless.
        case
            when e.days_elapsed = 0 then 0::numeric
            when coalesce(rev.prior_full, 0) > 0
                then least(greatest(coalesce(rev.prior_to_date, 0) / rev.prior_full, 0), 1)
            else e.days_elapsed::numeric / w.days_total
        end                                           as expected_frac
    from public.account_goals g
    left join erp.dim_customer c on c.customer_key = g.customer_key
    -- the goal period, and the same period a year earlier
    cross join lateral (
        select
            make_date(g.period_year, 1, 1)      as period_start,
            make_date(g.period_year, 12, 31)    as period_end,
            make_date(g.period_year - 1, 1, 1)  as prior_start,
            make_date(g.period_year - 1, 12, 31) as prior_end
    ) d
    -- how far into it we are (never past its end)
    cross join lateral (
        select
            least(current_date, d.period_end)     as as_of,
            (d.period_end - d.period_start + 1)   as days_total,
            (d.prior_end - d.prior_start + 1)     as prior_days
    ) w
    cross join lateral (
        select greatest(w.as_of - d.period_start + 1, 0) as days_elapsed
    ) e
    -- The same point of the prior year, mapped by PROPORTION of the year
    -- rather than by adding the same number of days. Adding days breaks on
    -- leap years: 364 days into a 365-day year is December 31, but
    -- prior_start + 364 in a 366-day year is December 30, so a completed
    -- year compared itself against 364/365ths of its predecessor and
    -- reported 97.5% expected where it had to be 100%. Verified against
    -- 2025-vs-2024 on dev, which is exactly the leap pair.
    --
    -- days_elapsed = 0 (period not started) lands prior_as_of a day BEFORE
    -- prior_start, so the prior-to-date filter matches nothing rather than
    -- the whole prior year.
    cross join lateral (
        select d.prior_start
             + (round(e.days_elapsed::numeric / w.days_total * w.prior_days))::int
             - 1                                            as prior_as_of
    ) x
    -- One index range over (customer_key, invoice_date) covering both years;
    -- the three measures are FILTER clauses over that single scan.
    left join lateral (
        select
            sum(f.revenue) filter (
                where f.invoice_date >= d.period_start and f.invoice_date <= w.as_of
            )                                                  as revenue_to_date,
            sum(f.revenue) filter (
                where f.invoice_date >= d.prior_start and f.invoice_date <= x.prior_as_of
            )                                                  as prior_to_date,
            sum(f.revenue) filter (
                where f.invoice_date >= d.prior_start and f.invoice_date <= d.prior_end
            )                                                  as prior_full
        from erp.fact_invoice_line f
        where f.customer_key = g.customer_key
          and f.is_memo is not true      -- NULL-safe; see the 011 header
          and f.invoice_date is not null
          and f.invoice_date >= d.prior_start
          and f.invoice_date <= greatest(w.as_of, d.prior_end)
    ) rev on true
) r;

comment on view public.v_account_goal_progress is
  'One row per rep-entered goal: target, revenue earned against it, and pace. '
  'expected_pct is the share of the goal that should be in by today on the '
  'account''s OWN prior-year seasonal shape (pace_basis = seasonal), falling '
  'back to days-elapsed (straight_line) when there is no prior year. '
  'on_track is NULL before the period starts. security_invoker — driven off '
  'account_goals and erp.dim_customer, so the caller sees only their book.';

--------------------------------------------------------------------------
-- v_my_goal_rollup
--   Grain: one row per year, aggregated over whatever the CALLER can see —
--          a rep's book, or for an admin the whole company. The Today-page
--          "how is the book tracking" line.
--
--   The aggregation is here rather than in the client for the usual reason:
--   summing it in the browser means shipping every goal row to a phone to
--   produce four numbers.
--------------------------------------------------------------------------
create or replace view public.v_my_goal_rollup
with (security_invoker = true)
as
select
    a.period_year,
    a.accounts_with_goal,
    a.accounts_behind,
    a.target_total,
    a.revenue_total,
    a.expected_total,
    case when a.target_total > 0
         then round(100 * a.revenue_total / a.target_total, 1)
    end                                                     as attainment_pct,
    case when a.target_total > 0
         then round(100 * a.expected_total / a.target_total, 1)
    end                                                     as expected_pct
from (
    select
        gp.period_year,
        count(*)::int                                       as accounts_with_goal,
        count(*) filter (where gp.on_track is false)::int    as accounts_behind,
        coalesce(sum(gp.target_amount), 0)::numeric          as target_total,
        coalesce(sum(gp.revenue_to_date), 0)::numeric        as revenue_total,
        coalesce(sum(gp.expected_amount), 0)::numeric        as expected_total
    from public.v_account_goal_progress gp
    group by gp.period_year
) a;

comment on view public.v_my_goal_rollup is
  'Goal totals for the caller''s book, one row per period_year. Rep sees '
  'their own accounts, admin sees every account with a goal. accounts_behind '
  'counts on_track = false only — a goal whose year has not started is '
  'neither ahead nor behind.';

--------------------------------------------------------------------------
-- v_rep_goal_attainment
--   Grain: one row per rep, current year. The admin execution answer to
--          "who set goals, and who is tracking against them".
--
--   Ownership comes from v_user_accounts (006) — the same resolved book
--   (derived ∪ grants − revokes) coverage is measured against, so "12 of 40
--   accounts have goals" counts the same 40 accounts the coverage grid does.
--
--   Cost is per rep × their goals, not per rep × their book, because
--   v_account_goal_progress only has rows where a goal exists. An admin
--   screen can afford that; nothing on a rep's phone reads this.
--------------------------------------------------------------------------
create or replace view public.v_rep_goal_attainment
with (security_invoker = true)
as
select
    p.user_id,
    p.full_name,
    p.active,
    extract(year from current_date)::int                     as period_year,
    (select count(*)::int from public.v_user_accounts ua where ua.user_id = p.user_id)
                                                            as assigned_accounts,
    g.accounts_with_goal,
    g.accounts_behind,
    g.target_total,
    g.revenue_total,
    case when g.target_total > 0
         then round(100 * g.revenue_total / g.target_total, 1)
    end                                                     as attainment_pct,
    case when g.target_total > 0
         then round(100 * g.expected_total / g.target_total, 1)
    end                                                     as expected_pct
from public.profiles p
-- An aggregate with no GROUP BY always returns one row, so a rep who has set
-- no goals gets zeros here rather than dropping out of the grid entirely.
left join lateral (
    select
        count(*)::int                                       as accounts_with_goal,
        count(*) filter (where gp.on_track is false)::int    as accounts_behind,
        coalesce(sum(gp.target_amount), 0)::numeric          as target_total,
        coalesce(sum(gp.revenue_to_date), 0)::numeric        as revenue_total,
        coalesce(sum(gp.expected_amount), 0)::numeric        as expected_total
    from public.v_account_goal_progress gp
    join public.v_user_accounts ua
      on ua.customer_key = gp.customer_key
     and ua.user_id = p.user_id
    where gp.period_year = extract(year from current_date)::int
) g on true
where p.role = 'rep';

comment on view public.v_rep_goal_attainment is
  'Per-rep goal attainment for the current year over the rep''s resolved '
  'book (v_user_accounts). One row per rep with role = rep, zeros when they '
  'have set no goals. security_invoker: an admin sees every rep, a rep sees '
  'only their own row (profiles RLS).';

--------------------------------------------------------------------------
-- View grants. Take back the default anon SELECT — these serve dealer
-- revenue — and keep authenticated. service_role keeps its default for the
-- Edge Functions.
--------------------------------------------------------------------------
revoke all on public.v_account_goal_progress from anon, public;
revoke all on public.v_my_goal_rollup         from anon, public;
revoke all on public.v_rep_goal_attainment    from anon, public;

grant select on public.v_account_goal_progress to authenticated;
grant select on public.v_my_goal_rollup         to authenticated;
grant select on public.v_rep_goal_attainment    to authenticated;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. RLS test suite (§3.5): rep A must get zero rows from account_goals and
     all three views for rep B's customer_key, and must not be able to INSERT
     a goal for one. A new table plus three new views is exactly where a leak
     hides.
  2. Regenerate frontend/src/types/database.types.ts. Until then
     useAccountGoals.ts reads and writes these through the same deliberately
     untyped client handle as useAccountMetrics.ts, and says so.
  3. erp.dim_customer.yearly_sales_goal is NOT deprecated by this. The UI
     shows it beside the rep goal on purpose — the drift between the two is
     the interesting part, and it is what an ERP push-back job would reconcile.
  4. account_signals.yearly_sales_goal (019) still carries the ERP figure and
     is untouched here. Feeding the rep goal into the score is a tuning
     decision with overnight consequences for what gets recommended, so it
     deserves its own migration and its own preview run.
----------------------------------------------------------------------------*/
