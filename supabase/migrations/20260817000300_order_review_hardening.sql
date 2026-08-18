/*============================================================================
  20260817000300_order_review_hardening.sql
  Purpose: post-review hardening of the order-writer schema (PR #27 review).

  1. order_entry profiles must carry an EMPTY book — structurally.
     20260817000000 documents the empty-book model but nothing enforced it:
     a rep switched to order_entry kept their sales_rep_key /
     rep_group_vendor_id, and my_customer_keys() derives access solely from
     those fields (it never looks at role) — so the supposed entry-only user
     silently retained Data API access to the whole customer book and its
     ERP facts. The scope fields are cleared once for any existing rows,
     then a CHECK constraint holds the invariant. The admin UI and
     admin-create-user clear the fields on role changes; any path that
     forgets fails loudly instead of leaking a book.

  2. submit/recall/cancel must reject deactivated callers. is_admin() and
     is_order_entry() already require an active profile, but the owner
     branch of these three RPCs checked only user_id — a deactivated rep
     with a still-valid JWT could keep mutating their orders until the
     token expired, bypassing the profile-based deactivation cutoff. Each
     RPC now requires the caller's profile to be active before anything
     else. (mark_order_entered / reopen / resolve already gate on
     is_order_entry()/is_admin(), which check `active`.)

  3. run_order_qc() matches erp.fact_order_line by upper(trim(order_id)),
     an expression the (order_id, line_num) primary key cannot serve — on a
     populated fact table that is three sequential scans per queued order,
     inside the nightly ETL's post-load step. A matching expression index
     turns each probe into an index lookup. (The fact table is truncated
     and re-COPYed nightly; the index simply rebuilds with the load.)
============================================================================*/

--------------------------------------------------------------------------
-- 1. order_entry ⇒ empty book, as a constraint.
--------------------------------------------------------------------------
update public.profiles
set sales_rep_key = null,
    rep_group_vendor_id = null
where role = 'order_entry'
  and (sales_rep_key is not null or rep_group_vendor_id is not null);

alter table public.profiles drop constraint if exists order_entry_empty_book;
alter table public.profiles
  add constraint order_entry_empty_book
  check (role <> 'order_entry'
         or (sales_rep_key is null and rep_group_vendor_id is null));

comment on constraint order_entry_empty_book on public.profiles is
  'order_entry users own no account book (20260817000000). my_customer_keys() '
  'derives access from the scope fields alone, so leaving them populated on a '
  'role change would silently keep the old book alive.';

--------------------------------------------------------------------------
-- 2. Deactivation cuts off order transitions immediately.
--    Full re-creations of the three owner-path RPCs from 20260817000200,
--    each with the caller-active check added ahead of everything else.
--------------------------------------------------------------------------

create or replace function public.submit_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
  v_cust  record;
  v_bad   text;
begin
  -- A JWT outlives deactivation; the profile is the cutoff, not the token.
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if not (v_order.user_id = v_uid or public.is_admin()) then
    raise exception 'only the order''s owner may submit it';
  end if;
  if v_order.status <> 'draft' then
    raise exception 'order % is %, only drafts can be submitted',
      p_order_id, v_order.status;
  end if;
  if not exists (select 1 from public.order_lines where order_id = p_order_id) then
    raise exception 'order % has no lines', p_order_id;
  end if;

  select c.customer_name, c.customer_type into v_cust
  from erp.dim_customer c where c.customer_key = v_order.customer_key;
  if not found then
    raise exception 'customer % not found in the ERP', v_order.customer_key;
  end if;

  -- Every line must sit on a list effective today for this customer type,
  -- and its captured price must still be the published price.
  select string_agg(distinct l.part_id, ', ') into v_bad
  from public.order_lines l
  where l.order_id = p_order_id
    and not exists (
      select 1
      from public.effective_price_lists(v_cust.customer_type) epl
      join public.price_list_items i
        on i.price_list_id = epl.id and i.part_id = l.part_id
      where epl.id = l.price_list_id
        and i.unit_price = l.unit_price
    );
  if v_bad is not null then
    raise exception 'lines no longer valid against today''s price lists: %. '
      'Re-open the draft to refresh pricing.', v_bad;
  end if;

  -- Authoritative promo pass (overwrites whatever the client previewed).
  with totals as (
    select l.price_list_id,
           sum(l.qty)::numeric as total_qty,
           pl.promo_buy_qty, pl.promo_get_qty
    from public.order_lines l
    join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = p_order_id
    group by l.price_list_id, pl.promo_buy_qty, pl.promo_get_qty
  ),
  pct as (
    select price_list_id,
           case
             when promo_buy_qty is null then 0::numeric
             else round(
               100 * (floor(total_qty / (promo_buy_qty + promo_get_qty))
                      * promo_get_qty) / total_qty, 4)
           end as discount_pct
    from totals
  )
  update public.order_lines l
  set discount_pct         = pct.discount_pct,
      effective_unit_price = round(l.unit_price * (1 - pct.discount_pct / 100), 2)
  from pct
  where l.order_id = p_order_id
    and l.price_list_id = pct.price_list_id;

  update public.orders o
  set status        = 'submitted',
      customer_name = coalesce(v_cust.customer_name, v_order.customer_key),
      customer_type = v_cust.customer_type,
      total_amount  = (select sum(line_total) from public.order_lines
                       where order_id = p_order_id),
      submitted_at  = now()
  where o.id = p_order_id
  returning * into v_order;

  return v_order;
end;
$$;

create or replace function public.recall_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
begin
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if not (v_order.user_id = v_uid or public.is_admin()) then
    raise exception 'only the order''s owner may recall it';
  end if;
  if v_order.status <> 'submitted' then
    raise exception 'order % is %, only submitted orders can be recalled',
      p_order_id, v_order.status;
  end if;

  update public.orders
  set status = 'draft', submitted_at = null, total_amount = null
  where id = p_order_id
  returning * into v_order;
  return v_order;
end;
$$;

create or replace function public.cancel_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
begin
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if not (v_order.user_id = v_uid or public.is_admin()) then
    raise exception 'only the order''s owner may cancel it';
  end if;
  if v_order.status not in ('draft', 'submitted') then
    raise exception 'order % is %, only draft or submitted orders can be cancelled',
      p_order_id, v_order.status;
  end if;

  update public.orders set status = 'cancelled'
  where id = p_order_id
  returning * into v_order;
  return v_order;
end;
$$;

-- create or replace keeps existing ACLs, but re-assert the 20260817000200
-- exposure anyway so this file stands alone.
revoke execute on function public.submit_order(bigint) from public, anon;
revoke execute on function public.recall_order(bigint) from public, anon;
revoke execute on function public.cancel_order(bigint) from public, anon;
grant execute on function public.submit_order(bigint) to authenticated;
grant execute on function public.recall_order(bigint) to authenticated;
grant execute on function public.cancel_order(bigint) to authenticated;

--------------------------------------------------------------------------
-- 3. Serve run_order_qc()'s normalized order-number probes from an index.
--------------------------------------------------------------------------
create index if not exists idx_fact_order_line_order_id_norm
  on erp.fact_order_line (upper(trim(order_id)));

comment on index erp.idx_fact_order_line_order_id_norm is
  'Serves run_order_qc()''s upper(trim(order_id)) equality probes (three per '
  'queued order per run). VISUAL order ids can carry stray case/whitespace, '
  'so the QC normalizes at compare time rather than trusting the load.';
