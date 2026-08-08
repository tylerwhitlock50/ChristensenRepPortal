/*============================================================================
  20260803223924_account_goals.sql  —  RECONSTRUCTED, already applied to prod

  Prod has migration version 20260803223924 "023_account_goals" (applied
  2026-08-03 between 022 and 024) but the file was never merged to main —
  the repo jumped from 022 to 023_account_deactivations. This file is that
  migration recovered verbatim from the live database (information_schema,
  pg_policies, pg_get_functiondef, pg_views on 2026-08-07) so a fresh
  environment builds the same objects. It carries the REAL remote version
  as its filename so `supabase db push` sees it as already applied instead
  of replaying or rejecting it.

  Everything here is idempotent; running it against prod is a no-op.

  Feature: per-account yearly sales goals. Two sources deliberately coexist:
    - erp.dim_customer.yearly_sales_goal — the ERP's USER_3 goal, read-only
      here, surfaced as erp_yearly_sales_goal for comparison.
    - public.account_goals — CRM-entered targets, one per account per year.
  Progress views pace attainment seasonally when a prior full year of
  invoice revenue exists, else straight-line by calendar day.
============================================================================*/

create table if not exists public.account_goals (
    id            bigint generated always as identity primary key,
    customer_key  text not null,
    period_year   int  not null check (period_year >= 2000 and period_year <= 2100),
    target_amount numeric not null check (target_amount > 0),
    note          text,
    created_by    uuid not null default auth.uid() references public.profiles (user_id),
    updated_by    uuid references public.profiles (user_id),
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    constraint uq_account_goal_year unique (customer_key, period_year)
);
alter table public.account_goals enable row level security;

create or replace function public.touch_account_goal()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$function$;

drop trigger if exists trg_account_goals_touch on public.account_goals;
create trigger trg_account_goals_touch
  before update on public.account_goals
  for each row execute function public.touch_account_goal();

-- Book policy, same shape as the erp reads in 010: admins see all, reps see
-- (and manage) goals for accounts in their book.
drop policy if exists "read account goals" on public.account_goals;
create policy "read account goals" on public.account_goals
  for select to authenticated
  using ((select public.is_admin())
         or customer_key in (select public.my_customer_keys()));

drop policy if exists "write account goals" on public.account_goals;
create policy "write account goals" on public.account_goals
  for insert to authenticated
  with check (((select public.is_admin())
               or customer_key in (select public.my_customer_keys()))
              and created_by = (select auth.uid()));

drop policy if exists "update account goals" on public.account_goals;
create policy "update account goals" on public.account_goals
  for update to authenticated
  using ((select public.is_admin())
         or customer_key in (select public.my_customer_keys()))
  with check ((select public.is_admin())
              or customer_key in (select public.my_customer_keys()));

drop policy if exists "delete account goals" on public.account_goals;
create policy "delete account goals" on public.account_goals
  for delete to authenticated
  using ((select public.is_admin())
         or customer_key in (select public.my_customer_keys()));

revoke all on public.account_goals from anon, public;
grant select, insert, update, delete on public.account_goals to authenticated;

--------------------------------------------------------------------------
-- v_account_goal_progress — one row per goal with pace math.
--------------------------------------------------------------------------
create or replace view public.v_account_goal_progress
with (security_invoker = true)
as
select
    goal_id, customer_key, customer_name, sold_to_city, sold_to_state,
    active_flag, period_year, target_amount, note, created_by, updated_by,
    updated_at, erp_yearly_sales_goal, period_start, period_end, as_of,
    days_elapsed, days_total,
    greatest(days_total - days_elapsed, 0)                     as days_remaining,
    revenue_to_date, pace_basis,
    round(100::numeric * revenue_to_date / target_amount, 1)   as attainment_pct,
    round(100::numeric * expected_frac, 1)                     as expected_pct,
    round(target_amount * expected_frac, 2)                    as expected_amount,
    round(revenue_to_date - target_amount * expected_frac, 2)  as gap_to_pace,
    round(greatest(target_amount - revenue_to_date, 0::numeric), 2) as gap_to_goal,
    case when expected_frac > 0::numeric
         then round(revenue_to_date / expected_frac, 2) end    as projected_amount,
    case when days_elapsed = 0 then null::boolean
         else revenue_to_date >= target_amount * expected_frac end as on_track
from (
    select
        g.id as goal_id,
        g.customer_key,
        c.customer_name,
        c.sold_to_city,
        c.sold_to_state,
        c.active_flag,
        c.yearly_sales_goal as erp_yearly_sales_goal,
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
        coalesce(rev.revenue_to_date, 0::numeric) as revenue_to_date,
        case
            when e.days_elapsed = 0 then 'not_started'
            when coalesce(rev.prior_full, 0::numeric) > 0::numeric then 'seasonal'
            else 'straight_line'
        end as pace_basis,
        case
            when e.days_elapsed = 0 then 0::numeric
            when coalesce(rev.prior_full, 0::numeric) > 0::numeric
                then least(greatest(coalesce(rev.prior_to_date, 0::numeric)
                                    / rev.prior_full, 0::numeric), 1::numeric)
            else e.days_elapsed::numeric / w.days_total::numeric
        end as expected_frac
    from public.account_goals g
    left join erp.dim_customer c on c.customer_key = g.customer_key
    cross join lateral (
        select make_date(g.period_year, 1, 1)      as period_start,
               make_date(g.period_year, 12, 31)    as period_end,
               make_date(g.period_year - 1, 1, 1)  as prior_start,
               make_date(g.period_year - 1, 12, 31) as prior_end
    ) d
    cross join lateral (
        select least(current_date, d.period_end)      as as_of,
               (d.period_end - d.period_start) + 1    as days_total,
               (d.prior_end - d.prior_start) + 1      as prior_days
    ) w
    cross join lateral (
        select greatest((w.as_of - d.period_start) + 1, 0) as days_elapsed
    ) e
    cross join lateral (
        select (d.prior_start
                + round(e.days_elapsed::numeric / w.days_total::numeric
                        * w.prior_days::numeric)::integer) - 1 as prior_as_of
    ) x
    left join lateral (
        select
            sum(f.revenue) filter (where f.invoice_date >= d.period_start
                                     and f.invoice_date <= w.as_of)      as revenue_to_date,
            sum(f.revenue) filter (where f.invoice_date >= d.prior_start
                                     and f.invoice_date <= x.prior_as_of) as prior_to_date,
            sum(f.revenue) filter (where f.invoice_date >= d.prior_start
                                     and f.invoice_date <= d.prior_end)   as prior_full
        from erp.fact_invoice_line f
        where f.customer_key = g.customer_key
          and f.is_memo is not true
          and f.invoice_date is not null
          and f.invoice_date >= d.prior_start
          and f.invoice_date <= greatest(w.as_of, d.prior_end)
    ) rev on true
) r;

--------------------------------------------------------------------------
-- v_my_goal_rollup — the caller's book, one row per goal year.
--------------------------------------------------------------------------
create or replace view public.v_my_goal_rollup
with (security_invoker = true)
as
select
    period_year, accounts_with_goal, accounts_behind,
    target_total, revenue_total, expected_total,
    case when target_total > 0::numeric
         then round(100::numeric * revenue_total / target_total, 1) end as attainment_pct,
    case when target_total > 0::numeric
         then round(100::numeric * expected_total / target_total, 1) end as expected_pct
from (
    select
        gp.period_year,
        count(*)::integer                                        as accounts_with_goal,
        (count(*) filter (where gp.on_track is false))::integer  as accounts_behind,
        coalesce(sum(gp.target_amount), 0::numeric)              as target_total,
        coalesce(sum(gp.revenue_to_date), 0::numeric)            as revenue_total,
        coalesce(sum(gp.expected_amount), 0::numeric)            as expected_total
    from public.v_account_goal_progress gp
    group by gp.period_year
) a;

--------------------------------------------------------------------------
-- v_rep_goal_attainment — admin roster: current-year attainment per rep.
--------------------------------------------------------------------------
create or replace view public.v_rep_goal_attainment
with (security_invoker = true)
as
select
    p.user_id, p.full_name, p.active,
    extract(year from current_date)::integer as period_year,
    (select count(*)::integer from public.v_user_accounts ua
      where ua.user_id = p.user_id)          as assigned_accounts,
    g.accounts_with_goal, g.accounts_behind, g.target_total, g.revenue_total,
    case when g.target_total > 0::numeric
         then round(100::numeric * g.revenue_total / g.target_total, 1) end as attainment_pct,
    case when g.target_total > 0::numeric
         then round(100::numeric * g.expected_total / g.target_total, 1) end as expected_pct
from public.profiles p
left join lateral (
    select
        count(*)::integer                                        as accounts_with_goal,
        (count(*) filter (where gp.on_track is false))::integer  as accounts_behind,
        coalesce(sum(gp.target_amount), 0::numeric)              as target_total,
        coalesce(sum(gp.revenue_to_date), 0::numeric)            as revenue_total,
        coalesce(sum(gp.expected_amount), 0::numeric)            as expected_total
    from public.v_account_goal_progress gp
    join public.v_user_accounts ua
      on ua.customer_key = gp.customer_key and ua.user_id = p.user_id
    where gp.period_year = extract(year from current_date)::integer
) g on true
where p.role = 'rep';

revoke all on public.v_account_goal_progress from anon, public;
revoke all on public.v_my_goal_rollup        from anon, public;
revoke all on public.v_rep_goal_attainment   from anon, public;
grant select on public.v_account_goal_progress to authenticated;
grant select on public.v_my_goal_rollup        to authenticated;
grant select on public.v_rep_goal_attainment   to authenticated;
