/*============================================================================
  003_app_core.sql
  Purpose: App-owned core — user profiles, account assignments, and the two
           access-control helper functions every RLS policy leans on.
  Auth   : Users are created ONLY by the admin (Supabase Dashboard or admin
           API with service_role). No self-signup — disable signups in
           Supabase Auth settings. A trigger auto-creates the profile row.
============================================================================*/

--------------------------------------------------------------------------
-- profiles — one row per auth user
--------------------------------------------------------------------------
create table if not exists public.profiles (
    user_id             uuid primary key references auth.users (id) on delete cascade,
    full_name           text not null default '',
    role                text not null default 'rep' check (role in ('admin', 'rep')),
    -- Ownership is DERIVED from the ERP (see has_account_access below):
    --   sales_rep_key        → erp.dim_customer.assigned_sales_rep_id (own book)
    --   rep_group_vendor_id  → erp.dim_sales_rep.vendor_id (principal: group book)
    -- Never stamp placeholder rep codes (WEB, HOUSE, …) on a profile — a
    -- placeholder key would grant that user the placeholder's entire book.
    sales_rep_key       text,
    rep_group_vendor_id text,
    active              boolean not null default true,
    created_at          timestamptz not null default now()
);
alter table public.profiles enable row level security;

-- Auto-create a profile when the admin creates an auth user
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (user_id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.email))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

--------------------------------------------------------------------------
-- account_assignments — OVERRIDE layer only. The record of ownership is
-- the ERP (dim_customer.assigned_sales_rep_id); rows here grant access
-- the ERP doesn't imply (house accounts, temporary coverage) or revoke
-- access it does. Revoke beats everything except admin.
--------------------------------------------------------------------------
create table if not exists public.account_assignments (
    id            bigint generated always as identity primary key,
    customer_key  text not null,          -- erp.dim_customer.customer_key
    user_id       uuid not null references public.profiles (user_id) on delete cascade,
    access        text not null default 'grant' check (access in ('grant','revoke')),
    assigned_by   uuid references public.profiles (user_id),
    created_at    timestamptz not null default now(),
    unique (customer_key, user_id)
);
alter table public.account_assignments enable row level security;
create index if not exists idx_assignments_user on public.account_assignments (user_id);
create index if not exists idx_assignments_customer on public.account_assignments (customer_key);

--------------------------------------------------------------------------
-- Access helpers (security definer so they can be used inside RLS on any
-- table without recursive policy evaluation)
--------------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where user_id = auth.uid() and role = 'admin' and active
  );
$$;

/*
  Access resolution (TECH_STACK.md §3.4 — customer-assigned sales rep wins):

    admin                                                    → everything
    else, an explicit REVOKE row                             → nothing
    else:  own book    profiles.sales_rep_key
                         = dim_customer.assigned_sales_rep_id
        OR group book  profiles.rep_group_vendor_id
                         = vendor_id of the account's assigned rep
        OR an explicit GRANT row

  The `is not null` / '(Unknown)' guards are NOT redundant: many SALES_REP
  rows have a null VENDOR_ID and many profiles have a null sales_rep_key or
  rep_group_vendor_id. Bare equality is null-safe, but the guards make the
  fail-closed intent explicit and protect against a future rewrite to
  `is not distinct from` / coalesce — either of which would silently make
  every null-keyed user an owner of every null-keyed account.
*/
create or replace function public.has_account_access(p_customer_key text)
returns boolean
language sql stable security definer set search_path = public, erp
as $$
  select
    public.is_admin()
    or (
      not exists (
        select 1 from public.account_assignments
        where customer_key = p_customer_key
          and user_id = auth.uid()
          and access = 'revoke'
      )
      and (
        -- own book: derived from the customer header's assigned rep
        exists (
          select 1
          from public.profiles p
          join erp.dim_customer c
            on c.assigned_sales_rep_id = p.sales_rep_key
          where p.user_id = auth.uid()
            and p.active
            and p.sales_rep_key is not null
            and p.sales_rep_key <> '(Unknown)'
            and c.customer_key = p_customer_key
        )
        -- group book: principal over every rep in their agency (vendor)
        or exists (
          select 1
          from public.profiles p
          join erp.dim_sales_rep sr
            on sr.vendor_id = p.rep_group_vendor_id
          join erp.dim_customer c
            on c.assigned_sales_rep_id = sr.sales_rep_key
          where p.user_id = auth.uid()
            and p.active
            and p.rep_group_vendor_id is not null
            and sr.vendor_id is not null
            and sr.sales_rep_key <> '(Unknown)'
            and c.customer_key = p_customer_key
        )
        -- explicit grant (house accounts, temporary coverage)
        or exists (
          select 1 from public.account_assignments
          where customer_key = p_customer_key
            and user_id = auth.uid()
            and access = 'grant'
        )
      )
    );
$$;
