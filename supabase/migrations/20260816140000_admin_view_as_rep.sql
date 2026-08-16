/*============================================================================
  20260816140000_admin_view_as_rep.sql

  "View as rep" — an admin sees the portal exactly as one of their reps sees
  it: the same Overview totals, the same account list, the same intel, the
  same empty states. Read-only.

  ── Why this is two functions and not a filter ────────────────────────────
  The SPA does not filter by rep. It cannot: the Overview query is literally

      .from('v_territory_account_yoy').select('*')   -- RLS is the filter

  and the same is true of the accounts list, every intel page and every
  account view (011, 025, 030 — all `security_invoker`). Scope is decided in
  exactly two places and nowhere else:

      public.is_admin()          -- "sees everything"
      public.my_customer_keys()  -- "sees this book"

  So impersonation is not a feature that has to be threaded through 25 query
  composables. It is those two functions learning about an acting identity.
  Everything downstream — 104 policy references, every view, the AI brief,
  the MCP endpoint — follows for free and stays consistent by construction.
  A client-side rep filter would have had to re-implement the §3.4 rules
  (own book / group book / grant / revoke / placeholder guard) a second time
  in TypeScript, and the second implementation is the one that drifts.

  ── Why a table and not a request header ──────────────────────────────────
  The obvious alternative is an `x-act-as` header read out of
  `current_setting('request.headers')`. Rejected on three counts: it needs a
  CORS preflight allowance we do not control at the gateway; it has to be
  re-attached by hand in every Edge Function that builds a client from the
  caller's JWT; and it leaves no trace. State in a table is picked up by the
  SPA, the Edge Functions and the MCP endpoint identically, because all three
  end up as the same `authenticated` role hitting the same policies.

  ── The direction this fails ──────────────────────────────────────────────
  Every branch fails toward LESS access, which is the only acceptable
  direction for a change that touches is_admin():

    - a stale/expired row      → acting id is null → ordinary admin
    - target profile inactive  → acting id still returned; is_admin() is
                                 false and my_customer_keys() yields nothing,
                                 exactly like signing in as that rep would
    - a rep sends the RPC      → is_real_admin() is false → raises
    - anything unexpected      → coalesce falls back to auth.uid()

  The one thing that must never fail closed is the way OUT. stop_impersonation()
  is gated on is_real_admin(), never on is_admin(), because is_admin() is
  false for the whole duration and an exit gated on it would lock the admin
  into the rep's view with no way back short of psql.

  ── Read-only, enforced in the database ───────────────────────────────────
  auth.uid() is still the admin while impersonating, so without a guard an
  admin could log a visit or write a note that lands on the rep's account
  under the admin's name. Hiding the buttons is not the same as it being
  impossible, so the block is a trigger on every RLS-enabled table in
  `public` rather than a `and not is_impersonating()` bolted onto ~20
  `with check` clauses that a future migration would forget to extend.
============================================================================*/

--------------------------------------------------------------------------
-- 1. State: at most one live impersonation per admin.
--
-- Keyed by the admin, not by session: an admin with the portal open on a
-- laptop and a phone is viewing as the same rep on both, and "why does my
-- other tab disagree" is a worse surprise than "both tabs followed me".
--
-- expires_at is the backstop for the real failure mode here, which is not
-- security but confusion: an admin who closes the tab still impersonating
-- and comes back tomorrow to a portal that is inexplicably missing 90% of
-- its accounts. After 12 hours the row stops counting on its own.
--------------------------------------------------------------------------
create table if not exists public.impersonation (
    admin_user_id  uuid primary key references public.profiles (user_id) on delete cascade,
    target_user_id uuid not null references public.profiles (user_id) on delete cascade,
    started_at     timestamptz not null default now(),
    expires_at     timestamptz not null default now() + interval '12 hours',
    check (admin_user_id <> target_user_id)
);
alter table public.impersonation enable row level security;

comment on table public.impersonation is
  'Live "view as rep" state, one row per admin. Written only by '
  'start_impersonation() / stop_impersonation(); read by acting_as_user_id().';

--------------------------------------------------------------------------
-- 2. Audit: append-only, because "the admin was looking at someone else''s
--    book at the time" is the kind of thing you want to be able to answer
--    later, and the state table above forgets by design.
--------------------------------------------------------------------------
create table if not exists public.impersonation_events (
    id             bigint generated always as identity primary key,
    admin_user_id  uuid not null references public.profiles (user_id) on delete cascade,
    target_user_id uuid not null references public.profiles (user_id) on delete cascade,
    action         text not null check (action in ('start', 'stop')),
    at             timestamptz not null default now()
);
alter table public.impersonation_events enable row level security;
create index if not exists idx_impersonation_events_admin
  on public.impersonation_events (admin_user_id, at desc);

--------------------------------------------------------------------------
-- 3. is_real_admin() — the admin check that impersonation cannot touch.
--
-- This is verbatim the body is_admin() carried from 003 until this file.
-- It exists because is_admin() is about to start answering "is the EFFECTIVE
-- user an admin", and three things still need to ask about the person
-- actually holding the credential: starting an impersonation, ending one,
-- and reading the audit log.
--------------------------------------------------------------------------
create or replace function public.is_real_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where user_id = auth.uid() and role = 'admin' and active
  );
$$;

comment on function public.is_real_admin() is
  'True when the credential-holder is an active admin, regardless of any '
  'active "view as rep". Use for entering/leaving impersonation only — '
  'everything else wants is_admin().';

--------------------------------------------------------------------------
-- 4. The acting identity.
--
-- Note what is NOT checked here: whether the target profile is still active.
-- If a rep is deactivated mid-session the admin stays pinned to them and
-- sees nothing, which is what signing in as that rep would show. Checking
-- `active` here would instead silently promote the admin back to seeing
-- every account in the company, which is a privilege jump nobody asked for.
--------------------------------------------------------------------------
create or replace function public.acting_as_user_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select i.target_user_id
  from public.impersonation i
  where i.admin_user_id = auth.uid()
    and i.expires_at > now()
    and public.is_real_admin();
$$;

create or replace function public.effective_user_id()
returns uuid
language sql stable security definer set search_path = public
as $$
  select coalesce(public.acting_as_user_id(), auth.uid());
$$;

create or replace function public.is_impersonating()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.acting_as_user_id() is not null;
$$;

comment on function public.effective_user_id() is
  'The user the app should behave as: the impersonation target for an admin '
  'in "view as rep", otherwise auth.uid(). THE identity every access rule '
  'resolves through.';

--------------------------------------------------------------------------
-- 5. is_admin() — same question, asked of the effective user.
--
-- With no impersonation row this is byte-for-byte the 003 behaviour, since
-- effective_user_id() is then auth.uid(). Impersonating a rep makes it
-- false, which is what scopes the admin down across all 104 references to
-- it without touching a single policy. Impersonating another admin keeps it
-- true, which is the honest answer — you asked to see what they see.
--------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where user_id = public.effective_user_id() and role = 'admin' and active
  );
$$;

--------------------------------------------------------------------------
-- 6. my_customer_keys() — auth.uid() → effective_user_id(), three places.
--
-- Deliberately a substitution and not a rewrite. In particular the grant
-- branch still carries no `active` check: an inactive profile with an
-- explicit grant row resolves that one account today, and this migration is
-- not the place to change that (010's T8 passes either way, so a "tidy-up"
-- here would be an untested behaviour change).
--------------------------------------------------------------------------
create or replace function public.my_customer_keys()
returns setof text
language sql
stable
security definer
set search_path = public, erp
as $$
  with me as (
    select p.sales_rep_key, p.rep_group_vendor_id
    from public.profiles p
    where p.user_id = public.effective_user_id()
      and p.active
  ),
  derived as (
    -- own book
    select c.customer_key
    from me
    join erp.dim_customer c
      on c.assigned_sales_rep_id = me.sales_rep_key
    where me.sales_rep_key is not null
      and not (me.sales_rep_key = any (public.placeholder_rep_keys()))

    union

    -- group book: principal over every rep in their agency (vendor)
    select c.customer_key
    from me
    join erp.dim_sales_rep sr
      on sr.vendor_id = me.rep_group_vendor_id
    join erp.dim_customer c
      on c.assigned_sales_rep_id = sr.sales_rep_key
    where me.rep_group_vendor_id is not null
      and sr.vendor_id is not null
      and not (sr.sales_rep_key = any (public.placeholder_rep_keys()))

    union

    -- explicit grant (house accounts, temporary coverage)
    select aa.customer_key
    from public.account_assignments aa
    where aa.user_id = public.effective_user_id()
      and aa.access = 'grant'
  )
  select d.customer_key
  from derived d
  where not exists (
    select 1
    from public.account_assignments r
    where r.user_id = public.effective_user_id()
      and r.customer_key = d.customer_key
      and r.access = 'revoke'
  );
$$;

--------------------------------------------------------------------------
-- 7. Personal-scope READS follow the acting identity too.
--
-- Account-scoped tables need nothing here: they route through
-- has_account_access() and already followed at step 6. But two tables are
-- keyed by user rather than by account, and both are part of what "the app
-- as that rep sees it" means — an admin checking why a rep's Today screen
-- looks empty needs to see the rep's follow-ups, not their own.
--
--   tasks       the rep's follow-up list
--   ai_briefs   their cached AI Action output
--
-- SELECT only. The write halves keep resolving through auth.uid(), so even
-- with the step-10 trigger lifted, nothing here could author a row as
-- somebody else. Note what is deliberately absent: mcp_tokens. Those are
-- credentials, not content, and "see the app as they see it" has never
-- meant "hold what they hold". login_events and ai_usage_events are also
-- left alone — metering and audit belong to the real user.
--------------------------------------------------------------------------
drop policy if exists "own tasks" on public.tasks;

create policy "read own tasks" on public.tasks
  for select to authenticated
  using (user_id = (select public.effective_user_id()) or (select public.is_admin()));

create policy "write own tasks" on public.tasks
  for insert to authenticated
  with check (user_id = (select auth.uid()) or (select public.is_admin()));

create policy "update own tasks" on public.tasks
  for update to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()))
  with check (user_id = (select auth.uid()) or (select public.is_admin()));

create policy "delete own tasks" on public.tasks
  for delete to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "own ai briefs" on public.ai_briefs;
create policy "own ai briefs" on public.ai_briefs
  for select to authenticated
  using (user_id = (select public.effective_user_id()) or (select public.is_admin()));

--------------------------------------------------------------------------
-- 8. Entering and leaving.
--------------------------------------------------------------------------
create or replace function public.start_impersonation(p_target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target public.profiles;
begin
  if not public.is_real_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;
  if p_target_user_id = auth.uid() then
    raise exception 'cannot_impersonate_self' using errcode = '22023';
  end if;

  select * into v_target from public.profiles where user_id = p_target_user_id;
  if not found then
    raise exception 'no_such_profile' using errcode = '22023';
  end if;
  if not v_target.active then
    raise exception 'profile_inactive' using errcode = '22023';
  end if;

  insert into public.impersonation (admin_user_id, target_user_id, started_at, expires_at)
  values (auth.uid(), p_target_user_id, now(), now() + interval '12 hours')
  on conflict (admin_user_id) do update
    set target_user_id = excluded.target_user_id,
        started_at     = excluded.started_at,
        expires_at     = excluded.expires_at;

  insert into public.impersonation_events (admin_user_id, target_user_id, action)
  values (auth.uid(), p_target_user_id, 'start');
end;
$$;

/*
  Gated on is_real_admin(), NOT is_admin(). is_admin() is false for the whole
  duration of a rep impersonation, so gating the exit on it would be a
  one-way door.
*/
create or replace function public.stop_impersonation()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target uuid;
begin
  if not public.is_real_admin() then
    raise exception 'not_admin' using errcode = '42501';
  end if;

  delete from public.impersonation
   where admin_user_id = auth.uid()
  returning target_user_id into v_target;

  if v_target is not null then
    insert into public.impersonation_events (admin_user_id, target_user_id, action)
    values (auth.uid(), v_target, 'stop');
  end if;
end;
$$;

--------------------------------------------------------------------------
-- 9. acting_context() — what the SPA renders the banner from.
--
-- Needed as a definer RPC because while impersonating, the "read own
-- profile" policy resolves against auth.uid() and is_admin() is false, so
-- the admin can no longer read the target''s profile row through PostgREST.
-- Returns one row always; impersonating is false and the target columns are
-- null in the ordinary case.
--------------------------------------------------------------------------
create or replace function public.acting_context()
returns table (
  impersonating       boolean,
  real_user_id        uuid,
  real_full_name      text,
  real_is_admin       boolean,
  target_user_id      uuid,
  target_full_name    text,
  target_role         text,
  target_sales_rep_key text,
  target_rep_group_vendor_id text,
  expires_at          timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    t.user_id is not null,
    me.user_id,
    me.full_name,
    public.is_real_admin(),
    t.user_id,
    t.full_name,
    t.role,
    t.sales_rep_key,
    t.rep_group_vendor_id,
    i.expires_at
  from public.profiles me
  left join public.impersonation i
    on i.admin_user_id = me.user_id
   and i.expires_at > now()
   and public.is_real_admin()
  left join public.profiles t on t.user_id = i.target_user_id
  where me.user_id = auth.uid();
$$;

--------------------------------------------------------------------------
-- 10. impersonatable_profiles() — the picker''s options.
--
-- A plain select on profiles would do, except that the admin has to be able
-- to open the picker while ALREADY impersonating (to switch reps), and by
-- then is_admin() is false and the profiles policy hides everyone else.
-- Deliberately narrow: identity and rep keys, nothing else.
--------------------------------------------------------------------------
create or replace function public.impersonatable_profiles()
returns table (
  user_id             uuid,
  full_name           text,
  role                text,
  sales_rep_key       text,
  rep_group_vendor_id text
)
language sql
stable
security definer
set search_path = public
as $$
  select p.user_id, p.full_name, p.role, p.sales_rep_key, p.rep_group_vendor_id
  from public.profiles p
  where public.is_real_admin()
    and p.active
    and p.user_id <> auth.uid()
  order by p.full_name, p.user_id;
$$;

--------------------------------------------------------------------------
-- 11. Read-only enforcement.
--
-- One trigger function, attached to every RLS-enabled table in `public`
-- except the four that must keep working while impersonating:
--
--   impersonation, impersonation_events  the way out would block itself
--   login_events                         an admin must be able to sign in
--                                        again with a live row outstanding
--   job_runs                             service_role only; auth.uid() is
--                                        null there, but excluding it keeps
--                                        the ETL provably out of scope
--
-- 42501 (insufficient_privilege) so PostgREST answers 403 rather than 500.
--------------------------------------------------------------------------
create or replace function public.block_writes_while_impersonating()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.acting_as_user_id() is not null then
    raise exception 'read_only_while_viewing_as' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

revoke execute on function public.block_writes_while_impersonating()
  from public, anon, authenticated;

do $$
declare
  t record;
begin
  for t in
    select tablename
    from pg_tables
    where schemaname = 'public'
      and rowsecurity
      and tablename not in ('impersonation', 'impersonation_events',
                            'login_events', 'job_runs')
    order by tablename
  loop
    execute format(
      'drop trigger if exists trg_%1$s_no_write_while_viewing_as on public.%1$I',
      t.tablename);
    execute format(
      'create trigger trg_%1$s_no_write_while_viewing_as '
      'before insert or update or delete on public.%1$I '
      'for each row execute function public.block_writes_while_impersonating()',
      t.tablename);
  end loop;
end;
$$;

--------------------------------------------------------------------------
-- 12. Policies and grants.
--
-- The state and audit tables are readable by their own admin (so the
-- banner survives a reload even if acting_context() is bypassed) and
-- writable by nobody: every mutation goes through the definer RPCs above.
--------------------------------------------------------------------------
drop policy if exists "read own impersonation" on public.impersonation;
create policy "read own impersonation" on public.impersonation
  for select to authenticated using (admin_user_id = (select auth.uid()));

drop policy if exists "read own impersonation events" on public.impersonation_events;
create policy "read own impersonation events" on public.impersonation_events
  for select to authenticated
  using (admin_user_id = (select auth.uid()) or (select public.is_real_admin()));

grant select on public.impersonation to authenticated;
grant select on public.impersonation_events to authenticated;

-- Same posture as 017: definer helpers are for signed-in callers only.
revoke execute on function public.is_real_admin()            from public, anon;
revoke execute on function public.acting_as_user_id()        from public, anon;
revoke execute on function public.effective_user_id()        from public, anon;
revoke execute on function public.is_impersonating()         from public, anon;
revoke execute on function public.start_impersonation(uuid)  from public, anon;
revoke execute on function public.stop_impersonation()       from public, anon;
revoke execute on function public.acting_context()           from public, anon;
revoke execute on function public.impersonatable_profiles()  from public, anon;

grant execute on function public.is_real_admin()             to authenticated;
grant execute on function public.acting_as_user_id()         to authenticated;
grant execute on function public.effective_user_id()         to authenticated;
grant execute on function public.is_impersonating()          to authenticated;
grant execute on function public.start_impersonation(uuid)   to authenticated;
grant execute on function public.stop_impersonation()        to authenticated;
grant execute on function public.acting_context()            to authenticated;
grant execute on function public.impersonatable_profiles()   to authenticated;
