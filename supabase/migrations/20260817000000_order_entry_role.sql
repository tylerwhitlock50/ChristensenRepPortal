/*============================================================================
  20260817000000_order_entry_role.sql
  Purpose: Third profile role, `order_entry`, for the order-writer workstream.

  An order_entry user is the person who keys submitted portal orders into the
  ERP and records the ERP order number. They are deliberately NOT a rep:
    - no sales_rep_key / rep_group_vendor_id → my_customer_keys() resolves to
      an empty book, so every account-scoped surface (accounts, intel, ERP
      facts) is naturally empty for them. Nothing else needs re-gating.
    - their access is granted table-by-table in the orders migration
      (20260817000200): read post-draft orders, and perform status
      transitions ONLY through the transition RPCs — no direct writes.

  This migration only widens the role vocabulary and adds the helper the
  order policies/RPCs lean on, mirroring is_admin() from 003.
============================================================================*/

--------------------------------------------------------------------------
-- profiles.role: ('admin','rep') → ('admin','rep','order_entry')
-- 003 declared the check inline, so it carries the auto-generated name.
--------------------------------------------------------------------------
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check
  check (role in ('admin', 'rep', 'order_entry'));

--------------------------------------------------------------------------
-- is_order_entry() — same shape as is_admin(): SECURITY DEFINER so it can
-- sit inside RLS policies without recursive policy evaluation, and always
-- wrapped as `(select public.is_order_entry())` at the call site so it
-- becomes an InitPlan, not a per-row call (the 010 lesson).
--------------------------------------------------------------------------
create or replace function public.is_order_entry()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.profiles
    where user_id = auth.uid() and role = 'order_entry' and active
  );
$$;

revoke execute on function public.is_order_entry() from public, anon;
grant execute on function public.is_order_entry() to authenticated;

comment on function public.is_order_entry() is
  'True when the caller''s active profile has role=order_entry. The order '
  'entry role reads post-draft orders and transitions them via RPCs only; '
  'it owns no account book.';
