/*============================================================================
  016_missions_admin.sql
  Purpose: Missions (admin-directed work, in bulk) and the admin section's
           data needs.

  A "mission" is not a new object — it is an admin-created recommendation
  (source = 'admin'), extended with:

    - requires_visit : closing requires a submitted structured visit survey
                       (enforced by trigger, not just UI)
    - batch_id       : groups the rows created by one create_mission() call
                       so "every dealer gets a follow-up this month" can be
                       tracked as one unit ("October blitz: 132/300 done")

  Also in this file, because the admin UI needs them:
    - profiles.email (backfilled, trigger-maintained) — the Users grid has
      no other path to an email; auth.users is not client-readable
    - a DB-level placeholder-rep-key guard on profiles — profile edits now
      happen via plain client RLS updates, so the TS-only guard in
      admin-create-user no longer covers every write path
    - v_rep_activity — per-rep activity with the rep group (vendor) derived
      even for ordinary reps (via erp.dim_sales_rep), for the Activity tab
    - two cleanups called out in earlier files:
        * drop the "log own login" insert policy (010) — it contradicted the
          006 design ("written ONLY via log_login()") and let a client spoof
          logged_at values that feed execution metrics
        * re-point v_user_accounts (006) at placeholder_rep_keys() — it had
          drifted from my_customer_keys() (010) and still counted WEB/HOUSE
          books in coverage denominators. Coverage counts will drop slightly
          after this; that is the fix working, not a regression.
============================================================================*/

--------------------------------------------------------------------------
-- profiles.email — display data for the admin Users grid. auth.users is
-- the source of truth; this column is a trigger-maintained mirror.
--------------------------------------------------------------------------
alter table public.profiles add column if not exists email text;

update public.profiles p
   set email = u.email
  from auth.users u
 where u.id = p.user_id
   and p.email is distinct from u.email;

-- handle_new_user now also mirrors the email. Keep `on conflict do update`
-- narrow (email only) so a re-fired trigger can't clobber an admin-set
-- full_name.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (user_id, full_name, email)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.email), new.email)
  on conflict (user_id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep the mirror current if an email is ever changed in Auth.
create or replace function public.sync_profile_email()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update public.profiles
     set email = new.email
   where user_id = new.id
     and email is distinct from new.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_updated on auth.users;
create trigger on_auth_user_email_updated
  after update of email on auth.users
  for each row execute function public.sync_profile_email();

--------------------------------------------------------------------------
-- Placeholder guard on profiles — the admin UI edits sales_rep_key via a
-- plain RLS update, so the "never stamp WEB/HOUSE on a profile" rule (010,
-- admin-create-user) needs to live in the database, not just in TypeScript.
-- Only fires when the key is being set/changed, so unrelated updates to a
-- historically-bad row don't explode.
--------------------------------------------------------------------------
create or replace function public.guard_profile_rep_key()
returns trigger
language plpgsql
as $$
begin
  if new.sales_rep_key is not null
     and (tg_op = 'INSERT' or new.sales_rep_key is distinct from old.sales_rep_key)
     and new.sales_rep_key = any (public.placeholder_rep_keys())
  then
    raise exception 'placeholder_rep_key'
      using hint = 'Placeholder rep codes (WEB, HOUSE, …) must not be stamped on a profile; '
                   'use the real rep code or account_assignments grant rows.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_profiles_placeholder_guard on public.profiles;
create trigger trg_profiles_placeholder_guard
  before insert or update of sales_rep_key on public.profiles
  for each row execute function public.guard_profile_rep_key();

--------------------------------------------------------------------------
-- mission_batches — one row per create_mission() call. Admin-only: reps
-- never read this table (each per-account recommendation carries its own
-- title/reason), so the only policy is the admin one — fail closed.
--------------------------------------------------------------------------
create table if not exists public.mission_batches (
    id             bigint generated always as identity primary key,
    title          text not null,
    description    text,
    scope_type     text not null check (scope_type in ('all','vendor','rep','custom')),
    scope_value    text,                -- vendor_id | sales_rep_key | null
    requires_visit boolean not null default false,
    due_date       date,
    created_by     uuid not null references public.profiles (user_id),
    created_at     timestamptz not null default now()
);
alter table public.mission_batches enable row level security;

drop policy if exists "admin manages mission batches" on public.mission_batches;
create policy "admin manages mission batches" on public.mission_batches
  for all to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

--------------------------------------------------------------------------
-- recommendations — mission columns. Existing RLS already covers them
-- (read/update account-scoped, insert/delete admin-only).
--------------------------------------------------------------------------
alter table public.recommendations
  add column if not exists requires_visit boolean not null default false,
  add column if not exists batch_id bigint references public.mission_batches (id) on delete set null;

create index if not exists idx_recs_batch
  on public.recommendations (batch_id) where batch_id is not null;

--------------------------------------------------------------------------
-- Visit-required close guard. A requires_visit mission can only reach
-- 'closed' once a structured survey exists for it (actions → visits chain;
-- useSubmitVisit writes the action with recommendation_id, then the visit
-- with action_id). 'dismissed' is deliberately NOT blocked — it is the
-- escape hatch for closed dealers ("could_not_contact"), and dismissals
-- are surfaced separately in mission_batch_progress.
--
-- The guard applies to admins too. If an admin must force-close without a
-- survey, flip requires_visit off on the row first — that leaves an
-- auditable trace instead of a silent bypass.
--
-- SECURITY DEFINER so the existence check doesn't depend on the caller's
-- RLS view of actions/visits (matches mark_recommendation_acted in 005).
--------------------------------------------------------------------------
create or replace function public.enforce_mission_visit()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if new.requires_visit
     and new.status = 'closed'
     and old.status is distinct from 'closed'
     and not exists (
       select 1
       from public.actions a
       join public.visits v on v.action_id = a.id
       where a.recommendation_id = new.id
     )
  then
    raise exception 'mission_requires_visit'
      using hint = 'Submit a visit survey for this account before closing this mission.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_mission_requires_visit on public.recommendations;
create trigger trg_mission_requires_visit before update on public.recommendations
  for each row execute function public.enforce_mission_visit();

--------------------------------------------------------------------------
-- create_mission — bulk mission creation with a dry-run preview.
--
-- SECURITY DEFINER + explicit is_admin() gate (same posture as the RPCs in
-- 010/012): the function must expand scopes over all of erp.dim_customer,
-- which a rep's RLS would silently shrink. One resolution path serves both
-- the preview (p_dry_run) and the create, so the count the admin approved
-- is the count that gets created.
--------------------------------------------------------------------------
create or replace function public.create_mission(
    p_title          text,
    p_reason         text default null,
    p_priority       text default 'normal',
    p_due_date       date default null,
    p_requires_visit boolean default false,
    p_scope_type     text default 'custom',
    p_scope_value    text default null,
    p_customer_keys  text[] default null,
    p_active_only    boolean default true,
    p_dry_run        boolean default false
)
returns table (batch_id bigint, created_count integer)
language plpgsql
security definer set search_path = public, erp
as $$
declare
  v_input_keys text[];
  v_keys       text[];
  v_batch      bigint;
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'missing_title';
  end if;
  if p_priority not in ('high','normal','low') then
    raise exception 'invalid_priority';
  end if;
  if p_scope_type not in ('all','vendor','rep','custom') then
    raise exception 'invalid_scope';
  end if;
  if p_scope_type in ('vendor','rep') and nullif(trim(coalesce(p_scope_value,'')), '') is null then
    raise exception 'missing_scope_value';
  end if;
  if p_scope_type = 'rep' and p_scope_value = any (public.placeholder_rep_keys()) then
    -- No person exists to do the work; a WEB/HOUSE mission would sit open forever.
    raise exception 'placeholder_rep_key';
  end if;

  if p_scope_type = 'custom' then
    select array_agg(distinct k) into v_input_keys
    from unnest(coalesce(p_customer_keys, '{}'::text[])) as k;
    if v_input_keys is null then
      raise exception 'empty_custom_scope';
    end if;
    -- Typos are silent no-ops otherwise: validate existence before filtering.
    if exists (
      select 1 from unnest(v_input_keys) k
      where not exists (select 1 from erp.dim_customer c where c.customer_key = k)
    ) then
      raise exception 'unknown_customer_keys';
    end if;
  end if;

  -- One scope resolution for preview and create alike.
  select array_agg(c.customer_key) into v_keys
  from erp.dim_customer c
  where (not p_active_only or c.active_flag = 'Y')
    and case p_scope_type
          when 'all'    then true
          when 'rep'    then c.assigned_sales_rep_id = p_scope_value
          when 'vendor' then exists (
              select 1 from erp.dim_sales_rep sr
              where sr.sales_rep_key = c.assigned_sales_rep_id
                and sr.vendor_id = p_scope_value
                and not (sr.sales_rep_key = any (public.placeholder_rep_keys())))
          when 'custom' then c.customer_key = any (v_input_keys)
        end;

  if p_dry_run then
    return query select null::bigint, coalesce(array_length(v_keys, 1), 0);
    return;
  end if;

  if v_keys is null then
    raise exception 'scope_resolved_empty';
  end if;

  insert into public.mission_batches
      (title, description, scope_type, scope_value, requires_visit, due_date, created_by)
  values
      (trim(p_title), nullif(trim(coalesce(p_reason,'')), ''), p_scope_type,
       nullif(trim(coalesce(p_scope_value,'')), ''), p_requires_visit, p_due_date, auth.uid())
  returning id into v_batch;

  insert into public.recommendations
      (customer_key, source, title, reason, priority, due_date,
       requires_visit, batch_id, created_by)
  select k, 'admin', trim(p_title), nullif(trim(coalesce(p_reason,'')), ''),
         p_priority, p_due_date, p_requires_visit, v_batch, auth.uid()
  from unnest(v_keys) as k;

  return query select v_batch, array_length(v_keys, 1);
end;
$$;

revoke execute on function
  public.create_mission(text,text,text,date,boolean,text,text,text[],boolean,boolean)
  from public, anon;
grant execute on function
  public.create_mission(text,text,text,date,boolean,text,text,text[],boolean,boolean)
  to authenticated;

--------------------------------------------------------------------------
-- v_user_accounts — same body as 006 but placeholder-aware, matching
-- my_customer_keys() (010). Column list unchanged, so the dependent views
-- (rep_execution_summary, account_coverage) are untouched.
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
      and not (p.sales_rep_key = any (public.placeholder_rep_keys()))
    union
    -- group book (principal over their agency's reps)
    select p.user_id, c.customer_key
    from public.profiles p
    join erp.dim_sales_rep sr on sr.vendor_id = p.rep_group_vendor_id
    join erp.dim_customer c on c.assigned_sales_rep_id = sr.sales_rep_key
    where p.active
      and p.rep_group_vendor_id is not null
      and sr.vendor_id is not null
      and not (sr.sales_rep_key = any (public.placeholder_rep_keys()))
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
-- mission_batch_progress — the "did it actually happen" view. Reps get
-- zero rows: security_invoker + admin-only RLS on mission_batches.
--------------------------------------------------------------------------
create or replace view public.mission_batch_progress
with (security_invoker = true)
as
select
    b.id                                                          as batch_id,
    b.title,
    b.description,
    b.scope_type,
    b.scope_value,
    b.requires_visit,
    b.due_date,
    b.created_by,
    b.created_at,
    count(r.id)                                                   as total,
    count(*) filter (where r.status = 'open')                     as open_count,
    count(*) filter (where r.status = 'acted')                    as acted_count,
    count(*) filter (where r.status = 'closed')                   as closed_count,
    count(*) filter (where r.status = 'dismissed')                as dismissed_count,
    count(*) filter (where r.status in ('open','acted')
                       and r.due_date < current_date)             as overdue_count
from public.mission_batches b
left join public.recommendations r on r.batch_id = b.id
group by b.id;

--------------------------------------------------------------------------
-- v_mission_detail — per-account drill-in for a batch: who owns it, where
-- it stands, how it ended.
--------------------------------------------------------------------------
create or replace view public.v_mission_detail
with (security_invoker = true)
as
select
    r.id,
    r.batch_id,
    r.customer_key,
    c.customer_name,
    r.title,
    r.status,
    r.priority,
    r.due_date,
    r.requires_visit,
    r.outcome,
    r.outcome_note,
    r.closed_at,
    (select string_agg(distinct p.full_name, ', ')
       from public.v_user_accounts ua
       join public.profiles p on p.user_id = ua.user_id and p.role = 'rep'
      where ua.customer_key = r.customer_key)                     as rep_names
from public.recommendations r
left join erp.dim_customer c on c.customer_key = r.customer_key
where r.batch_id is not null;

--------------------------------------------------------------------------
-- v_rep_activity — the Activity tab. vendor_id is derived for ordinary
-- reps too (their profile only carries sales_rep_key; the agency comes
-- from erp.dim_sales_rep), so "activity by rep group" covers everyone.
--------------------------------------------------------------------------
create or replace view public.v_rep_activity
with (security_invoker = true)
as
select
    p.user_id,
    p.full_name,
    p.email,
    p.active,
    p.sales_rep_key,
    coalesce(p.rep_group_vendor_id, sr.vendor_id)                 as vendor_id,
    (select max(le.logged_at) from public.login_events le
      where le.user_id = p.user_id)                               as last_login_at,
    (select count(*) from public.login_events le
      where le.user_id = p.user_id
        and le.logged_at >= now() - interval '30 days')           as logins_30d,
    (select count(*) from public.actions a
      where a.user_id = p.user_id
        and a.action_date >= current_date - 30)                   as actions_30d,
    (select max(a.action_date) from public.actions a
      where a.user_id = p.user_id)                                as last_action_date,
    (select count(*) from public.recommendations r
       join public.v_user_accounts ua on ua.customer_key = r.customer_key
      where ua.user_id = p.user_id
        and r.source = 'admin'
        and r.status in ('open','acted'))                         as open_missions,
    (select count(*) from public.recommendations r
       join public.v_user_accounts ua on ua.customer_key = r.customer_key
      where ua.user_id = p.user_id
        and r.source = 'admin'
        and r.status in ('open','acted')
        and r.due_date < current_date)                            as overdue_missions
from public.profiles p
left join erp.dim_sales_rep sr on sr.sales_rep_key = p.sales_rep_key
where p.role = 'rep';

--------------------------------------------------------------------------
-- Cleanup: login_events goes back to RPC-only writes. 006 documented
-- "no client insert policy exists, so the client can't spoof rows or
-- timestamps"; 010 accidentally added one. log_login() (security definer)
-- is the sanctioned path and needs no policy.
--------------------------------------------------------------------------
drop policy if exists "log own login" on public.login_events;
