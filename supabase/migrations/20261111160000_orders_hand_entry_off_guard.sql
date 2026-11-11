/*============================================================================
  20261111160000_orders_hand_entry_off_guard.sql
  Purpose: make feature.orders (hand entry) a server-side switch, not just a
           hidden tab.

  Before this, the flag lived only in the portal: the Orders section and the
  writer were hidden, but neither the "rep creates draft orders" policy nor
  submit_order() read it. With hand entry off, any signed-in rep could still
  insert a draft on their own book over PostgREST and submit it.

  The rule, enforced by a trigger on public.orders (so submit_order() is NOT
  restated - its body drifts if copied, see migration-numbering notes):

    While feature.orders is off, a person cannot
      * create a hand-typed (source = 'portal') order, or
      * move a hand-typed order from draft to submitted.

  Untouched:
    * Claude-drafted orders (source 'mcp' / 'inbox'). They are created by the
      SECURITY DEFINER mcp_* RPCs and submitted by a person after the
      acknowledgement, governed by feature.mcp_orders.
    * Sessions with no user identity (ETL, maintenance as postgres /
      service_role), same carve-out as orders_protect_provenance().
    * Editing, cancelling or deleting an existing hand draft: harmless,
      it cannot leave draft while the flag is off.
  Admins are NOT exempt: the flag is off for everyone.

  Error prefix 'orders_disabled:' so the portal's rpcErrorText() shows the
  human half.
============================================================================*/

create or replace function public.orders_hand_entry_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if auth.uid() is null or new.source is distinct from 'portal' then
    return new;
  end if;
  if public.feature_enabled('feature.orders') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    raise exception 'orders_disabled: writing orders in the portal is turned off'
      using errcode = '42501';
  end if;
  if old.status = 'draft' and new.status = 'submitted' then
    raise exception 'orders_disabled: writing orders in the portal is turned off, so this hand-written draft cannot be submitted'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

comment on function public.orders_hand_entry_guard() is
  'While feature.orders is off, a person cannot create or submit a hand-typed '
  '(source=portal) order. Claude-drafted orders are governed by feature.mcp_orders.';

revoke execute on function public.orders_hand_entry_guard() from public, anon, authenticated;

drop trigger if exists trg_orders_hand_entry_guard on public.orders;
create trigger trg_orders_hand_entry_guard
  before insert or update of status on public.orders
  for each row execute function public.orders_hand_entry_guard();
