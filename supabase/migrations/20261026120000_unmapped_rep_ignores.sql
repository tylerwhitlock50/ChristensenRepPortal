/*============================================================================
  20261026120000_unmapped_rep_ignores.sql — an admin's "not this one" for the
  Users page's "Reps without an account" list.

  Why
  ---
  20261013170000 lists every ERP rep whose code is on no profile. Most of
  them will never get a portal login — retired contract reps, house buckets
  the ETL does not flag, agencies that work the book through one principal.
  The list is only useful if the admin can shorten it: "Create" for the
  ones who are getting an account, "Ignore" for the rest, and the ignored
  ones out of the way but one click from coming back.

  What
  ----
  1. public.unmapped_rep_ignores — one row per ignored rep code. Admin-only
     in every direction. No FK to erp.dim_sales_rep (the erp schema is
     reloaded wholesale); a key the ERP later drops just stops mattering.
     Append and delete, never update: restoring is a delete, changing your
     mind again is a new row.
  2. public.admin_unmapped_reps() restated with `ignored` and `ignore_note`.
     Ignored reps stay IN the result — the client hides them behind a
     toggle — so "show ignored" costs no second query and the count is
     always right. The return type changes, hence drop + create.
  3. The view-as read-only trigger, re-swept onto the new table.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The table
--------------------------------------------------------------------------
create table if not exists public.unmapped_rep_ignores (
    sales_rep_key  text primary key,
    ignored_by     uuid default auth.uid()
                   references public.profiles (user_id) on delete set null,
    note           text check (note is null or length(note) <= 200),
    created_at     timestamptz not null default now()
);
alter table public.unmapped_rep_ignores enable row level security;

comment on table public.unmapped_rep_ignores is
  'ERP rep codes an admin chose not to create a portal account for. Hides '
  'the row from the Users page''s "Reps without an account" list until the '
  'row is deleted. Admin-only; no FK to erp.dim_sales_rep on purpose.';

-- Reads and writes follow the credential-holder, never the view-as target:
-- is_real_admin(), same as admin_unmapped_reps() itself. The view-as trigger
-- below refuses writes while impersonating regardless.
drop policy if exists "admins read rep ignores" on public.unmapped_rep_ignores;
create policy "admins read rep ignores" on public.unmapped_rep_ignores
  for select to authenticated
  using ((select public.is_real_admin()));

drop policy if exists "admins ignore reps" on public.unmapped_rep_ignores;
create policy "admins ignore reps" on public.unmapped_rep_ignores
  for insert to authenticated
  with check ((select public.is_real_admin())
              and ignored_by = (select auth.uid()));

drop policy if exists "admins restore reps" on public.unmapped_rep_ignores;
create policy "admins restore reps" on public.unmapped_rep_ignores
  for delete to authenticated
  using ((select public.is_real_admin()));

revoke all on public.unmapped_rep_ignores from anon, public;
revoke all on public.unmapped_rep_ignores from authenticated;
grant select, insert, delete on public.unmapped_rep_ignores to authenticated;

--------------------------------------------------------------------------
-- 2. admin_unmapped_reps() with the ignore flag
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
  ignore_note            text
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
    i.note                                                      as ignore_note
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
  'so an admin can create the account from the row, and `ignored` when the '
  'admin has parked the rep in unmapped_rep_ignores. Returns nothing unless '
  'the credential-holder is an active admin (is_real_admin — view-as does '
  'not matter here). Security definer because sales_rep_email is '
  'column-revoked from authenticated (20260901190300).';

revoke execute on function public.admin_unmapped_reps() from public, anon;
grant  execute on function public.admin_unmapped_reps() to authenticated;

--------------------------------------------------------------------------
-- 3. View-as is read-only here too (same sweep as 20260901190200).
--------------------------------------------------------------------------
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
