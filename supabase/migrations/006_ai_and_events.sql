/*============================================================================
  006_ai_and_events.sql
  Purpose: Cached AI account summaries, login events, the resolved
           ownership view, and the admin execution/coverage views.
============================================================================*/

--------------------------------------------------------------------------
-- ai_summaries — one cached summary per account. context_hash lets the
-- Edge Function return the cached copy for free when nothing about the
-- account changed; prompt_version ties each summary to the prompt file
-- that produced it (TECH_STACK.md §5).
--------------------------------------------------------------------------
create table if not exists public.ai_summaries (
    customer_key   text primary key,
    content        text not null,
    model          text,
    context_hash   text,
    prompt_version text,
    generated_at   timestamptz not null default now(),
    generated_by   uuid references public.profiles (user_id)
);
alter table public.ai_summaries enable row level security;

--------------------------------------------------------------------------
-- login_events — written ONLY via the log_login() RPC (no client insert
-- policy exists), so the client can't spoof rows or timestamps.
-- Feeds "last login" / "days since activity" execution metrics.
--------------------------------------------------------------------------
create table if not exists public.login_events (
    id         bigint generated always as identity primary key,
    user_id    uuid not null references public.profiles (user_id) on delete cascade,
    logged_at  timestamptz not null default now()
);
alter table public.login_events enable row level security;
create index if not exists idx_login_events_user on public.login_events (user_id, logged_at desc);

create or replace function public.log_login()
returns void
language sql security definer set search_path = public
as $$
  insert into public.login_events (user_id) select auth.uid()
  where auth.uid() is not null;
$$;

--------------------------------------------------------------------------
-- v_user_accounts — the resolved book per user: ERP-derived ownership
-- (own book ∪ group book) plus grants, minus revokes. Single source for
-- coverage math and the admin dashboards, mirroring has_account_access().
-- security_invoker: reps resolve only what their erp RLS lets them see;
-- admins see everything.
--------------------------------------------------------------------------
create or replace view public.v_user_accounts
with (security_invoker = true)
as
with derived as (
    -- own book
    select p.user_id, c.customer_key
    from public.profiles p
    join erp.dim_customer c on c.assigned_sales_rep_id = p.sales_rep_key
    where p.active
      and p.sales_rep_key is not null
      and p.sales_rep_key <> '(Unknown)'
    union
    -- group book (principal over their agency's reps)
    select p.user_id, c.customer_key
    from public.profiles p
    join erp.dim_sales_rep sr on sr.vendor_id = p.rep_group_vendor_id
    join erp.dim_customer c on c.assigned_sales_rep_id = sr.sales_rep_key
    where p.active
      and p.rep_group_vendor_id is not null
      and sr.vendor_id is not null
      and sr.sales_rep_key <> '(Unknown)'
    union
    -- explicit grants
    select aa.user_id, aa.customer_key
    from public.account_assignments aa
    where aa.access = 'grant'
)
select d.user_id, d.customer_key
from derived d
where not exists (
    select 1 from public.account_assignments r
    where r.user_id = d.user_id
      and r.customer_key = d.customer_key
      and r.access = 'revoke'
);

--------------------------------------------------------------------------
-- rep_execution_summary — admin dashboard rollup
--------------------------------------------------------------------------
create or replace view public.rep_execution_summary
with (security_invoker = true)
as
select
    p.user_id,
    p.full_name,
    p.rep_group_vendor_id,
    p.active,
    (select max(logged_at) from public.login_events le where le.user_id = p.user_id)         as last_login_at,
    (select count(*) from public.v_user_accounts ua where ua.user_id = p.user_id)            as assigned_accounts,
    (select count(*) from public.recommendations r
       join public.v_user_accounts ua on ua.customer_key = r.customer_key
      where ua.user_id = p.user_id and r.status = 'open')                                    as open_recommendations,
    (select count(*) from public.recommendations r
       join public.v_user_accounts ua on ua.customer_key = r.customer_key
      where ua.user_id = p.user_id and r.status = 'open' and r.due_date < current_date)      as overdue_recommendations,
    (select count(*) from public.actions a
      where a.user_id = p.user_id and a.action_date >= current_date - 30)                    as actions_last_30d,
    (select max(a.action_date) from public.actions a where a.user_id = p.user_id)            as last_action_date
from public.profiles p
where p.role = 'rep';

--------------------------------------------------------------------------
-- account_coverage — per (account, owner): contacted in window or not.
-- The order-season "did every account get touched" answer. Denominator is
-- v_user_accounts, so no account with a real owner can hide from coverage.
--------------------------------------------------------------------------
create or replace view public.account_coverage
with (security_invoker = true)
as
select
    ua.customer_key,
    ua.user_id,
    p.full_name                                   as rep_name,
    max(a.action_date)                            as last_contact_date,
    (max(a.action_date) >= current_date - 30)     as contacted_last_30d,
    (max(a.action_date) >= current_date - 90)     as contacted_last_90d
from public.v_user_accounts ua
join public.profiles p on p.user_id = ua.user_id
left join public.actions a
       on a.customer_key = ua.customer_key and a.user_id = ua.user_id
group by ua.customer_key, ua.user_id, p.full_name;
