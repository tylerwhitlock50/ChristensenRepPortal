/*============================================================================
  20261030140000_order_ffl_when_needed.sql
  Purpose: ask for an FFL only when it matters (follows 20261030120000).

  1. An order needs an FFL only when one of its lines is a firearm:
     part_requires_ffl() is the portal's existing finished-firearm rule
     (report_account_sku_gaps / isGunRow): the product code is not a
     component, and the part carries a real product family or chambering
     (Z_PRODUCT_DETAIL only specs finished goods). Accessories need none.

  2. When the ship-to's licence on file is complete and current, the order
     uses it and the rep enters nothing. The rep enters an FFL only when the
     licence on file is missing, unreadable or expired (or to give a renewed
     one). ffl_on_file_current() decides, with parse_ffl_expiry() reading the
     free-form CUST_ADDRESS.USER_5 string the way sql-toolbox's audit and the
     order loader do (unreadable = not current, never a guess).

  3. order_ffl_context(customer, part ids) gives the writer both answers
     from these same functions, so the screen and submit_order() agree.
     SECURITY INVOKER: a rep sees only their own book's ship-tos.

  submit_order() is re-created from 20261030120000 with the FFL block
  replaced; orders gains requires_ffl, stamped at submit.
============================================================================*/

alter table public.orders add column if not exists requires_ffl boolean;
comment on column public.orders.requires_ffl is
  'Stamped by submit_order(): a line is a firearm (part_requires_ffl), so the order ships under an FFL.';

--------------------------------------------------------------------------
-- Firearm rule: mirrors report_account_sku_gaps / isGunRow(). A part the
-- ERP doesn't know is treated as needing one (fail safe).
--------------------------------------------------------------------------
create or replace function public.part_requires_ffl(p_part_id text)
returns boolean
language sql stable security definer set search_path = public, erp
as $$
  select coalesce((
    select coalesce(p.product_code, '') !~* 'component'
       and (   coalesce(nullif(btrim(p.product_family), ''), 'N/A') <> 'N/A'
            or coalesce(nullif(btrim(p.chambering), ''), 'N/A')     <> 'N/A')
    from erp.dim_part p
    where p.part_id = p_part_id
    limit 1), true);
$$;

--------------------------------------------------------------------------
-- USER_5 is free text: "1/31/2027", "01-31-27", "2027-01-31", "Exp 1/31/27",
-- "January 31, 2027". Anything else, or an implausible date, is NULL —
-- unknown, never a guess, because "current" on a compliance field must not
-- come from a misread. Two-digit years: < 70 is 20xx (as sql-toolbox does).
--------------------------------------------------------------------------
create or replace function public.parse_ffl_expiry(p_raw text)
returns date
language plpgsql stable
as $$
declare
  v text := btrim(coalesce(p_raw, ''));
  m text[];
  y int;
  d date;
begin
  v := regexp_replace(v, '^(exp(ires?)?|valid\s+(un)?til)\M[:.\s]*', '', 'i');
  v := btrim(regexp_replace(v, '[.,;]+$', ''));
  if v = '' then
    return null;
  end if;
  begin
    if v ~ '^\d{4}-\d{1,2}-\d{1,2}$' then
      m := regexp_match(v, '^(\d{4})-(\d{1,2})-(\d{1,2})$');
      d := make_date(m[1]::int, m[2]::int, m[3]::int);
    elsif v ~ '^\d{1,2}([/-])\d{1,2}\1(\d{4}|\d{2})$' then
      m := regexp_match(v, '^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$');
      y := m[3]::int;
      if length(m[3]) = 2 then
        y := y + case when y < 70 then 2000 else 1900 end;
      end if;
      d := make_date(y, m[1]::int, m[2]::int);
    elsif v ~ '^\d{8}$' then
      d := make_date(substr(v, 5, 4)::int, substr(v, 1, 2)::int, substr(v, 3, 2)::int);
    elsif v ~* '^[a-z]+\.? \d{1,2}, \d{4}$' then
      m := regexp_match(v, '^([A-Za-z]+)\.? (\d{1,2}), (\d{4})$');
      d := make_date(m[3]::int,
                     extract(month from to_date(substr(m[1], 1, 3) || ' 1 2000', 'Mon DD YYYY'))::int,
                     m[2]::int);
    else
      return null;
    end if;
  exception when others then
    return null;
  end;
  if abs(d - current_date) > 365 * 25 then
    return null;
  end if;
  return d;
end;
$$;

create or replace function public.ffl_on_file_current(p_number text, p_expiration_raw text)
returns boolean
language sql stable
as $$
  select length(public.ffl_normalize(p_number)) = 15
     and coalesce(public.parse_ffl_expiry(p_expiration_raw) >= current_date, false);
$$;

--------------------------------------------------------------------------
-- What the writer needs to know, from the same rules submit_order uses.
--------------------------------------------------------------------------
create or replace function public.order_ffl_context(p_customer_key text, p_part_ids text[])
returns jsonb
language sql stable security invoker set search_path = public, erp
as $$
  select jsonb_build_object(
    'requires_ffl',
      exists (select 1 from unnest(coalesce(p_part_ids, '{}'::text[])) as pid
              where public.part_requires_ffl(pid)),
    'ship_tos',
      coalesce((
        select jsonb_agg(jsonb_build_object(
                 'ship_to_key', s.ship_to_key,
                 'ffl_expires_on', public.parse_ffl_expiry(s.ffl_expiration_raw),
                 'ffl_current', public.ffl_on_file_current(s.ffl_license_number, s.ffl_expiration_raw)))
        from erp.dim_ship_to s
        where s.customer_id = p_customer_key), '[]'::jsonb));
$$;

revoke execute on function public.part_requires_ffl(text) from public, anon;
revoke execute on function public.parse_ffl_expiry(text) from public, anon;
revoke execute on function public.ffl_on_file_current(text, text) from public, anon;
revoke execute on function public.order_ffl_context(text, text[]) from public, anon;
grant execute on function public.part_requires_ffl(text) to authenticated;
grant execute on function public.parse_ffl_expiry(text) to authenticated;
grant execute on function public.ffl_on_file_current(text, text) to authenticated;
grant execute on function public.order_ffl_context(text, text[]) to authenticated;

--------------------------------------------------------------------------
-- submit_order: FFL only when needed, licence on file when current.
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
  v_needs boolean;
  v_ffl   text;
  v_exp   date;
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

  -- FFL: only when a line is a firearm (part_requires_ffl). The ship-to's
  -- licence on file is used when it is complete and current; the rep enters
  -- one only when it is not (or to give a renewed licence). Whether an
  -- entered licence matches Visual is order entry's check: the loader
  -- refuses to write until the ship-to in Visual carries it.
  v_needs := exists (select 1 from public.order_lines l
                     where l.order_id = p_order_id and public.part_requires_ffl(l.part_id));
  if not v_needs then
    v_ffl := null;
    v_exp := null;
  elsif nullif(trim(v_order.ffl_license_number), '') is null
        and public.ffl_on_file_current(v_ship.ffl_license_number, v_ship.ffl_expiration_raw) then
    v_ffl := upper(trim(v_ship.ffl_license_number));
    v_exp := public.parse_ffl_expiry(v_ship.ffl_expiration_raw);
  else
    if length(public.ffl_normalize(v_order.ffl_license_number)) <> 15 then
      raise exception 'this order has firearms and ship-to % has no current FFL on file: enter the FFL '
        'number (15 characters, e.g. 1-23-456-78-9A-12345)', v_ship.ship_to_id;
    end if;
    if v_order.ffl_expires_on is null then
      raise exception 'the FFL expiration date is required';
    end if;
    if v_order.ffl_expires_on < current_date then
      raise exception 'the FFL expired on %; get the renewed licence before submitting',
        v_order.ffl_expires_on;
    end if;
    v_ffl := upper(trim(v_order.ffl_license_number));
    v_exp := v_order.ffl_expires_on;
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
      requires_ffl               = v_needs,
      ffl_license_number         = v_ffl,
      ffl_expires_on             = v_exp,
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
