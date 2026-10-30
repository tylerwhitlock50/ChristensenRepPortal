/*============================================================================
  20261030120000_order_ship_to_ffl.sql
  Purpose: a portal order must name its ship-to address and carry the FFL it
           ships under, so order entry (and the order loader that writes it
           into Visual) never has to guess either.

  1. orders gains what the rep chooses on a draft:
       ship_to_key         erp.dim_ship_to.ship_to_key (CUSTOMER_ID|ADDR_NO)
       ffl_license_number  the receiving FFL's licence number
       ffl_expires_on      its expiry
     The writer prefills both FFL fields from the ship-to's licence on file in
     Visual (CUST_ADDRESS.USER_4 / USER_5) and the rep confirms or corrects them.

  2. submit_order() refuses an order without an active ship-to that belongs
     to the account, or without a 15-character FFL number and an unexpired
     date, then snapshots the ship-to (ID, ADDR_NO, name, address) and the FFL
     on file at that moment. order_entry owns no account book and cannot read
     erp.dim_ship_to, so the queue and the order loader work from the snapshot
     (the same reason customer_name is stamped).

  3. run_order_qc() gains 'ship_to_mismatch': the ERP order's ship_to_key
     must be the one the rep chose. Orders submitted before this migration
     have no ship_to_key and are not checked for it.

  The order loader repeats the FFL check against Visual itself: the order's
  FFL must match the ship-to's licence on file (EZ Check masked digits match
  anything, as in sql-toolbox's audit) and that licence must not be expired.
  A rep can submit a renewed licence; order entry updates Visual's ship-to
  before the order can be written.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Columns
--------------------------------------------------------------------------
alter table public.orders
  add column if not exists ship_to_key                text,
  add column if not exists ffl_license_number         text,
  add column if not exists ffl_expires_on             date,
  -- Snapshots stamped by submit_order().
  add column if not exists ship_to_id                 text,
  add column if not exists ship_to_addr_no            int,
  add column if not exists ship_to_name               text,
  add column if not exists ship_to_address            text,
  add column if not exists ffl_on_file_number         text,
  add column if not exists ffl_on_file_expiration_raw text;

comment on column public.orders.ship_to_key is
  'erp.dim_ship_to.ship_to_key the rep chose (CUSTOMER_ID|ADDR_NO). Required to submit.';
comment on column public.orders.ffl_license_number is
  'FFL the order ships under, prefilled from the ship-to''s licence on file. Required to submit.';
comment on column public.orders.ffl_on_file_number is
  'Visual''s licence on the ship-to (CUST_ADDRESS.USER_4) when the order was submitted.';

-- FFL numbers are written with and without dashes and spaces; compare them bare.
create or replace function public.ffl_normalize(p text)
returns text
language sql immutable
as $$ select upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g')) $$;

--------------------------------------------------------------------------
-- 2. submit_order: ship-to + FFL, and the snapshot. Full re-creation of
--    the 20260817000300 version with the new block after the customer check.
--------------------------------------------------------------------------
create or replace function public.submit_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
  v_cust  record;
  v_ship  erp.dim_ship_to;
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

  -- Ship-to: one of this account's own Visual ship-to addresses (CUST_ADDRESS,
  -- so it has a SHIPTO_ID the order can carry), and still active.
  if v_order.ship_to_key is null then
    raise exception 'pick a ship-to address for this order';
  end if;
  select s.* into v_ship from erp.dim_ship_to s where s.ship_to_key = v_order.ship_to_key;
  if not found
     or v_ship.customer_id is distinct from v_order.customer_key
     or v_ship.address_source is distinct from 'ShipTo'
     or coalesce(v_ship.is_unknown_ship_to, false)
     or nullif(trim(v_ship.ship_to_id), '') is null then
    raise exception 'ship-to % is not one of this account''s ship-to addresses', v_order.ship_to_key;
  end if;
  if upper(coalesce(v_ship.active_flag, 'Y')) = 'N' then
    raise exception 'ship-to % (%) is inactive in the ERP; pick another address',
      v_ship.ship_to_id, v_ship.ship_to_name;
  end if;

  -- FFL: a full licence number and an expiry that has not passed. Whether it
  -- matches the licence on file for the ship-to is order entry's check (the
  -- loader compares it with Visual and blocks until the two agree).
  if length(public.ffl_normalize(v_order.ffl_license_number)) <> 15 then
    raise exception 'an FFL number is required: 15 characters, e.g. 1-23-456-78-9A-12345';
  end if;
  if v_order.ffl_expires_on is null then
    raise exception 'the FFL expiration date is required';
  end if;
  if v_order.ffl_expires_on < current_date then
    raise exception 'the FFL expired on %; get the renewed licence before submitting',
      v_order.ffl_expires_on;
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
      ship_to_id      = v_ship.ship_to_id,
      ship_to_addr_no = v_ship.addr_no,
      ship_to_name    = v_ship.ship_to_name,
      ship_to_address = concat_ws(', ',
                          nullif(trim(v_ship.address1), ''), nullif(trim(v_ship.address2), ''),
                          nullif(trim(v_ship.address3), ''), nullif(trim(v_ship.city), ''),
                          nullif(trim(concat_ws(' ', v_ship.state, v_ship.zip_code)), '')),
      ffl_license_number         = upper(trim(v_order.ffl_license_number)),
      ffl_on_file_number         = v_ship.ffl_license_number,
      ffl_on_file_expiration_raw = v_ship.ffl_expiration_raw,
      total_amount  = (select sum(line_total) from public.order_lines
                       where order_id = p_order_id),
      submitted_at  = now()
  where o.id = p_order_id
  returning * into v_order;

  return v_order;
end;
$$;

revoke execute on function public.submit_order(bigint) from public, anon;
grant execute on function public.submit_order(bigint) to authenticated;

--------------------------------------------------------------------------
-- 3. run_order_qc: + ship_to_mismatch. Full re-creation of the
--    20260817000200 version with the ship-to block before the line compare.
--------------------------------------------------------------------------
alter table public.order_qc_results drop constraint if exists order_qc_results_result_check;
alter table public.order_qc_results
  add constraint order_qc_results_result_check check (result in
    ('customer_mismatch','ship_to_mismatch','price_mismatch','qty_mismatch',
     'missing_in_erp','extra_in_erp','order_not_found'));

create or replace function public.run_order_qc(p_order_id bigint default null)
returns int
language plpgsql security definer set search_path = public, erp
as $$
declare
  c_tolerance constant numeric := 0.011;
  c_grace     constant interval := interval '3 days';
  v_order     record;
  v_erp_count int;
  v_findings  int;
  v_rows      int;
  v_checked   int := 0;
begin
  if auth.uid() is not null
     and not (public.is_admin() or public.is_order_entry()) then
    raise exception 'only order entry or an admin may run the order QC';
  end if;

  for v_order in
    select o.* from public.orders o
    where o.erp_order_number is not null
      and ( (p_order_id is null and o.status in ('entered','discrepancy'))
         or (o.id = p_order_id and o.status in ('entered','discrepancy','verified')) )
    order by o.id
    for update
  loop
    v_checked := v_checked + 1;
    v_findings := 0;

    select count(*) into v_erp_count
    from erp.fact_order_line f
    where upper(trim(f.order_id)) = v_order.erp_order_number
      and coalesce(f.is_service_line, false) = false
      and coalesce(f.line_status, '') <> 'X';

    if v_erp_count = 0 and v_order.entered_at > now() - c_grace then
      -- ETL simply hasn't caught up; check again tomorrow.
      continue;
    end if;

    delete from public.order_qc_results where order_id = v_order.id;

    if v_erp_count = 0 then
      insert into public.order_qc_results (order_id, result, detail)
      values (v_order.id, 'order_not_found',
              format('No ERP order lines found for %s after %s days',
                     v_order.erp_order_number, extract(day from c_grace)));
      v_findings := 1;
    else
      -- Order-level: every ERP line must belong to this customer.
      insert into public.order_qc_results (order_id, result, detail)
      select v_order.id, 'customer_mismatch',
             format('ERP order %s is on customer %s, portal order is for %s',
                    v_order.erp_order_number,
                    min(f.customer_key), v_order.customer_key)
      from erp.fact_order_line f
      where upper(trim(f.order_id)) = v_order.erp_order_number
        and coalesce(f.is_service_line, false) = false
        and coalesce(f.line_status, '') <> 'X'
        and f.customer_key <> v_order.customer_key
      having count(*) > 0;
      get diagnostics v_rows = row_count;
      v_findings := v_findings + v_rows;

      -- Order-level: the ERP order must ship to the address the rep chose.
      -- fact_order_line.ship_to_key uses the same CUSTOMER_ID|ADDR_NO key as
      -- dim_ship_to (CUSTOMER_ID|CUST when the ERP order has no ship-to).
      if v_order.ship_to_key is not null then
        insert into public.order_qc_results (order_id, result, detail)
        select v_order.id, 'ship_to_mismatch',
               format('ERP order %s ships to %s; the portal order chose %s (%s)',
                      v_order.erp_order_number,
                      string_agg(distinct coalesce(f.ship_to_key, '(none)'), ', '),
                      v_order.ship_to_key, coalesce(v_order.ship_to_id, '?'))
        from erp.fact_order_line f
        where upper(trim(f.order_id)) = v_order.erp_order_number
          and coalesce(f.is_service_line, false) = false
          and coalesce(f.line_status, '') <> 'X'
          and f.ship_to_key is distinct from v_order.ship_to_key
        having count(*) > 0;
        get diagnostics v_rows = row_count;
        v_findings := v_findings + v_rows;
      end if;

      -- Line-level: aggregate both sides by part number and compare.
      with app_side as (
        select l.part_id,
               sum(l.qty)::numeric as qty,
               sum(l.qty * l.effective_unit_price) / sum(l.qty) as price
        from public.order_lines l
        where l.order_id = v_order.id
        group by l.part_id
      ),
      erp_side as (
        select coalesce(dp.part_id, f.part_key) as part_id,
               sum(f.order_qty) as qty,
               case when sum(f.order_qty) > 0
                 then sum(f.order_qty * f.unit_price
                          * (1 - coalesce(f.trade_discount_pct, 0) / 100))
                      / sum(f.order_qty)
               end as price
        from erp.fact_order_line f
        left join erp.dim_part dp on dp.part_key = f.part_key
        where upper(trim(f.order_id)) = v_order.erp_order_number
          and coalesce(f.is_service_line, false) = false
          and coalesce(f.line_status, '') <> 'X'
        group by coalesce(dp.part_id, f.part_key)
      )
      insert into public.order_qc_results
        (order_id, result, part_id, app_qty, erp_qty,
         app_unit_price, erp_unit_price, detail)
      select
        v_order.id,
        case
          when e.part_id is null then 'missing_in_erp'
          when a.part_id is null then 'extra_in_erp'
          when a.qty is distinct from e.qty then 'qty_mismatch'
          else 'price_mismatch'
        end,
        coalesce(a.part_id, e.part_id),
        a.qty, e.qty,
        round(a.price, 2), round(e.price, 2),
        case
          when e.part_id is null then 'On the portal order but not in the ERP'
          when a.part_id is null then 'In the ERP but not on the portal order'
          when a.qty is distinct from e.qty
            then format('Portal qty %s, ERP qty %s', a.qty, e.qty)
          else format('Portal price %s, ERP effective price %s',
                      round(a.price, 2), round(e.price, 2))
        end
      from app_side a
      full outer join erp_side e using (part_id)
      where e.part_id is null
         or a.part_id is null
         or a.qty is distinct from e.qty
         or abs(a.price - e.price) > c_tolerance;
      get diagnostics v_rows = row_count;
      v_findings := v_findings + v_rows;
    end if;

    if v_findings = 0 then
      update public.orders
      set status = 'verified',
          verified_at = coalesce(verified_at, now()),
          qc_checked_at = now()
      where id = v_order.id;
    else
      update public.orders
      set status = 'discrepancy',
          verified_at = null,
          qc_checked_at = now()
      where id = v_order.id;
    end if;
  end loop;

  return v_checked;
end;
$$;

revoke execute on function public.run_order_qc(bigint) from public, anon;
grant execute on function public.run_order_qc(bigint) to authenticated;
