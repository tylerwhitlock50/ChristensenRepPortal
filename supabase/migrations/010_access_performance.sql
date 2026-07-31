/*============================================================================
  010_access_performance.sql

  Purpose: Make the access model survive real data volume, without changing
           who can see what.

  The problem
  -----------
  `has_account_access()` is SECURITY DEFINER, so Postgres cannot inline it.
  Used directly in a policy it is evaluated ONCE PER ROW. Measured on this
  project at 41,556 customers:

      select … from erp.dim_customer where active_flag='Y'
        order by customer_name limit 50

      RLS bypassed .......    19 ms
      as authenticated ....  3,136 ms      (~75 µs × 41,556 calls)

  Single-row lookups were never affected (0.13 ms) — the primary key narrows
  to one row before the filter runs. It is unfiltered list scans that hurt,
  and erp.fact_order_line (500,995 rows) and erp.fact_invoice_line (529,221)
  are the same shape only worse.

  The fix
  -------
  1. `public.my_customer_keys()` returns the caller's whole book as a set.
     Because it is STABLE and takes no arguments, `key in (select
     public.my_customer_keys())` is uncorrelated, so the planner evaluates it
     ONCE as a hashed subplan and every row is a hash lookup.
  2. Every policy predicate that was invariant across rows — `is_admin()`,
     `auth.uid()` — is wrapped in a scalar subquery so it becomes an InitPlan
     instead of a per-row call.
  3. `has_account_access()` is rewritten to call `my_customer_keys()`, so
     there is exactly ONE implementation of the resolution rules. This is the
     point: two copies of this logic would drift, and a drift here is a
     silent access bug. It is kept because the Edge Functions call it as the
     user (TECH_STACK §5.1).

  Semantic changes — read this
  ----------------------------
  ONE deliberate change: placeholder rep codes are now excluded in SQL.

  TECH_STACK §3.4 excluded only null and '(Unknown)', relying on admin
  discipline to keep codes like WEB/HOUSE off a profile — while §9 asks for a
  test proving a placeholder grants nothing. Those cannot both hold. This
  install has `WEB` assigned to 52 live customers, so the guard is now
  explicit and the test is real. A user who genuinely needs a placeholder's
  book can still be given one with an explicit `grant` row in
  account_assignments, so nothing is locked out — it just has to be
  deliberate. To revert, empty the array in `placeholder_rep_keys()`.

  Everything else resolves exactly as 003 did, including the rule that an
  explicit `revoke` beats every derived branch.

  NOT changed (flagged, not fixed — see the note at the bottom):
    a deactivated profile still keeps access granted by an explicit
    `account_assignments` grant row, exactly as in 003.
============================================================================*/

--------------------------------------------------------------------------
-- Placeholder rep codes. These are real IDs in the ERP, not junk data, and
-- a profile carrying one would inherit that placeholder's entire book.
--------------------------------------------------------------------------
create or replace function public.placeholder_rep_keys()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['(Unknown)', 'WEB', 'HOUSE']::text[];
$$;

comment on function public.placeholder_rep_keys() is
  'Rep codes that must never confer account access. Empty this array to '
  'restore the 003 behaviour of relying on admin discipline alone.';

--------------------------------------------------------------------------
-- The caller''s resolved book, as a set. THE single implementation of the
-- access rules (TECH_STACK §3.4).
--
--   admin                                          → handled by the policies
--   own book    profiles.sales_rep_key
--                 = dim_customer.assigned_sales_rep_id
--   group book  profiles.rep_group_vendor_id
--                 = vendor_id of the account''s assigned rep
--   grant       an explicit account_assignments row
--   MINUS       any explicit revoke row
--
-- The `is not null` guards are NOT redundant. 41 of 138 sales reps have a
-- null vendor_id and most profiles have a null rep_group_vendor_id. Bare
-- equality is null-safe — but `is not distinct from` or `coalesce(x,'')`
-- would make every null-keyed user an owner of every null-keyed account.
-- That is the failure mode this whole function is shaped around: it fails
-- open, silently, and totally.
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
    where p.user_id = auth.uid()
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
    where aa.user_id = auth.uid()
      and aa.access = 'grant'
  )
  select d.customer_key
  from derived d
  where not exists (
    select 1
    from public.account_assignments r
    where r.user_id = auth.uid()
      and r.customer_key = d.customer_key
      and r.access = 'revoke'
  );
$$;

comment on function public.my_customer_keys() is
  'The calling user''s resolved account book. Use `key in (select '
  'public.my_customer_keys())` in RLS policies — uncorrelated and STABLE, so '
  'it is evaluated once per query rather than once per row.';

-- Callable by signed-in users only. It returns nothing for anon (auth.uid()
-- is null), but there is no reason to expose it on /rest/v1/rpc to the world.
revoke execute on function public.my_customer_keys() from public, anon;
revoke execute on function public.placeholder_rep_keys() from public, anon;
grant execute on function public.my_customer_keys() to authenticated;
grant execute on function public.placeholder_rep_keys() to authenticated;

--------------------------------------------------------------------------
-- has_account_access() — same answers as 003, now delegating so the rules
-- live in exactly one place. Kept for the Edge Functions and for single-key
-- checks, where per-row cost is irrelevant.
--------------------------------------------------------------------------
create or replace function public.has_account_access(p_customer_key text)
returns boolean
language sql
stable
security definer
set search_path = public, erp
as $$
  select public.is_admin()
      or exists (
           select 1
           from public.my_customer_keys() k
           where k = p_customer_key
         );
$$;

--------------------------------------------------------------------------
-- erp — customer-scoped read policies
--------------------------------------------------------------------------
drop policy if exists "read own dim_customer" on erp.dim_customer;
create policy "read own dim_customer" on erp.dim_customer
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

-- dim_ship_to.customer_id holds CUSTOMER.ID, which IS dim_customer.customer_key
-- (bi.vw_DimCustomer: CustomerKey = CUSTOMER.ID). Same domain, different name.
drop policy if exists "read own dim_ship_to" on erp.dim_ship_to;
create policy "read own dim_ship_to" on erp.dim_ship_to
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_id in (select public.my_customer_keys())
  );

drop policy if exists "read own fact_order_line" on erp.fact_order_line;
create policy "read own fact_order_line" on erp.fact_order_line
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

drop policy if exists "read own fact_invoice_line" on erp.fact_invoice_line;
create policy "read own fact_invoice_line" on erp.fact_invoice_line
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

drop policy if exists "read own fact_shipment_line" on erp.fact_shipment_line;
create policy "read own fact_shipment_line" on erp.fact_shipment_line
  for select to authenticated
  using (
    (select public.is_admin())
    or customer_key in (select public.my_customer_keys())
  );

--------------------------------------------------------------------------
-- public — account-scoped tables
--------------------------------------------------------------------------
drop policy if exists "read contacts" on public.contacts;
create policy "read contacts" on public.contacts
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "write contacts" on public.contacts;
create policy "write contacts" on public.contacts
  for insert to authenticated
  with check (
    ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
    and created_by = (select auth.uid())
  );

drop policy if exists "update contacts" on public.contacts;
create policy "update contacts" on public.contacts
  for update to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "read notes" on public.notes;
create policy "read notes" on public.notes
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "write notes" on public.notes;
create policy "write notes" on public.notes
  for insert to authenticated
  with check (
    ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
    and created_by = (select auth.uid())
  );

drop policy if exists "read photos" on public.photos;
create policy "read photos" on public.photos
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "write photos" on public.photos;
create policy "write photos" on public.photos
  for insert to authenticated
  with check (
    ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
    and created_by = (select auth.uid())
  );

drop policy if exists "read recommendations" on public.recommendations;
create policy "read recommendations" on public.recommendations
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "update recommendations" on public.recommendations;
create policy "update recommendations" on public.recommendations
  for update to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
  with check ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "read actions" on public.actions;
create policy "read actions" on public.actions
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "write actions" on public.actions;
create policy "write actions" on public.actions
  for insert to authenticated
  with check (
    ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
    and user_id = (select auth.uid())
  );

drop policy if exists "read visits" on public.visits;
create policy "read visits" on public.visits
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "write visits" on public.visits;
create policy "write visits" on public.visits
  for insert to authenticated
  with check (
    ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
    and user_id = (select auth.uid())
  );

drop policy if exists "read ai summaries" on public.ai_summaries;
create policy "read ai summaries" on public.ai_summaries
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "write ai summaries" on public.ai_summaries;
create policy "write ai summaries" on public.ai_summaries
  for insert to authenticated
  with check ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

drop policy if exists "update ai summaries" on public.ai_summaries;
create policy "update ai summaries" on public.ai_summaries
  for update to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

--------------------------------------------------------------------------
-- public — admin/self policies. No has_account_access here; these only need
-- the invariant predicates hoisted out of the per-row path.
--------------------------------------------------------------------------
drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "admin manages profiles" on public.profiles;
create policy "admin manages profiles" on public.profiles
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists "read own assignments" on public.account_assignments;
create policy "read own assignments" on public.account_assignments
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "admin manages assignments" on public.account_assignments;
create policy "admin manages assignments" on public.account_assignments
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists "own tasks" on public.tasks;
create policy "own tasks" on public.tasks
  for all to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()))
  with check (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "admin manages rules" on public.rule_settings;
create policy "admin manages rules" on public.rule_settings
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists "admin deletes contacts" on public.contacts;
create policy "admin deletes contacts" on public.contacts
  for delete to authenticated using ((select public.is_admin()));

drop policy if exists "admin deletes notes" on public.notes;
create policy "admin deletes notes" on public.notes
  for delete to authenticated using ((select public.is_admin()));

drop policy if exists "admin deletes photos" on public.photos;
create policy "admin deletes photos" on public.photos
  for delete to authenticated using ((select public.is_admin()));

drop policy if exists "admin creates recommendations" on public.recommendations;
create policy "admin creates recommendations" on public.recommendations
  for insert to authenticated with check ((select public.is_admin()));

drop policy if exists "admin deletes recommendations" on public.recommendations;
create policy "admin deletes recommendations" on public.recommendations
  for delete to authenticated using ((select public.is_admin()));

drop policy if exists "admin deletes actions" on public.actions;
create policy "admin deletes actions" on public.actions
  for delete to authenticated using ((select public.is_admin()));

drop policy if exists "admin deletes visits" on public.visits;
create policy "admin deletes visits" on public.visits
  for delete to authenticated using ((select public.is_admin()));

drop policy if exists "log own login" on public.login_events;
create policy "log own login" on public.login_events
  for insert to authenticated with check (user_id = (select auth.uid()));

drop policy if exists "read login events" on public.login_events;
create policy "read login events" on public.login_events
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

--------------------------------------------------------------------------
-- storage — same rewrite. Listing a bucket is a scan too.
--------------------------------------------------------------------------
drop policy if exists "read account photos" on storage.objects;
create policy "read account photos" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'account-photos'
    and (
      (select public.is_admin())
      or (storage.foldername(name))[1] in (select public.my_customer_keys())
    )
  );

drop policy if exists "upload account photos" on storage.objects;
create policy "upload account photos" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'account-photos'
    and (
      (select public.is_admin())
      or (storage.foldername(name))[1] in (select public.my_customer_keys())
    )
  );

drop policy if exists "admin deletes account photos" on storage.objects;
create policy "admin deletes account photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'account-photos' and (select public.is_admin()));

/*============================================================================
  Known gap, deliberately NOT changed here
  ----------------------------------------
  A profile with active = false still keeps access to any account granted by
  an explicit `account_assignments` row: the grant branch checks auth.uid()
  but not profiles.active, exactly as 003 did. The derived branches DO check
  it, and is_admin() checks it.

  The frontend blocks an inactive user at sign-in, but a JWT that is still
  valid can call the API directly, so this is a real hole for the PRD's
  "deactivate a user" story — not a theoretical one.

  Left alone on purpose so this migration is a performance change plus one
  clearly-labelled guard, rather than a quiet redefinition of who can see
  what. Fixing it is a one-line addition to the grant branch and belongs in
  its own migration with its own test.
============================================================================*/
