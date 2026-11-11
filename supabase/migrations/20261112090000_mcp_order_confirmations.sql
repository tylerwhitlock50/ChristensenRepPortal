/*============================================================================
  20261112090000_mcp_order_confirmations.sql
  Purpose: the order-drafting rules the 2026-11-11 test session showed are
  needed ON THE SERVER, not in the prompt (draft #345: Claude picked the
  ship-to and the SKU itself, left the PO blank, and the $1,485 the user
  asked for silently became $1,566.67). Follows 20261111150000.

  The model asserts each confirmation with a flag; the database refuses the
  draft without it and hands back the choices to show the user. A flag is a
  claim that the user was asked, not proof, but the agent can no longer
  skip a step by accident, and every refusal is in mcp_tool_calls.

  New rules in mcp_order_apply (create AND update; an update is a full
  replacement, so the flags are sent every time):
    customer_confirmed  required when another active account the caller can
                        see has the same name (Al's has four). Refusal
                        customer_confirmation_required, DETAIL = the accounts.
    ship_to_confirmed   required, with ship_to_key, when the account has more
                        than one orderable ship-to. Refusal
                        ship_to_confirmation_required, DETAIL = the ship-tos
                        with FFL number / expiry / current.
    lines[].part_confirmed  required on EVERY line (the simple rule: the
                        server cannot know which search a part came from).
                        Refusal part_confirmation_required, DETAIL = per
                        line, the part and its nearest priced siblings.
    po_number           required (po_required). Never invented.
    lines[].expected_unit_price  optional: the price the user said. Stored
                        on the line; when it differs from the server price
                        the preview carries a price_mismatch alert. The
                        model still never sets a price.
    is_test             optional: a test draft. Labelled in the portal and
                        can never be submitted (trigger below).

  Expired FFL rule (decided here): a ship-to whose FFL on file is expired
  stays ORDERABLE. The licence may have been renewed and the ERP not yet
  updated, and submit_order already refuses a firearm order without a
  current FFL unless the person submitting enters one. So the choices show
  ffl_current, and the preview carries a hard `ffl_not_current` alert
  (would_submit is false until a person enters the renewed licence).

  Bugs fixed:
    - lines[].description: the Buy Group list was uploaded with the UPC in
      the description column; the ERP part description now wins (as
      v_price_list_items already does), and stored lines are repaired.
    - contact name: falls back to the e-mail before the contact id.
    - order_context.data_as_of was dim_customer.loaded_at, which only moves
      when the ERP row changes (SPOR SOU1 last changed 11/01). It is now the
      last successful ETL run (v_data_freshness.data_loaded_at);
      account_changed_at keeps the row's own stamp.

  Errors keep the '<code>[:<detail>]: <text>' message; the structured
  choices ride in the error's DETAIL (PostgREST `details`) as JSON.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Columns
--------------------------------------------------------------------------
alter table public.orders
  add column if not exists is_test boolean not null default false;
comment on column public.orders.is_test is
  'A test draft (MCP is_test). Labelled in the portal; can never be '
  'submitted (trg_orders_test_never_submits). Set only by the mcp_* RPCs.';

alter table public.order_lines
  add column if not exists mcp_expected_unit_price numeric(12,2)
    check (mcp_expected_unit_price is null or mcp_expected_unit_price > 0);
comment on column public.order_lines.mcp_expected_unit_price is
  'The unit price the user told Claude to expect (expected_unit_price). '
  'Display only: the line is always priced from the price list; a '
  'difference is a price_mismatch alert on the draft.';

--------------------------------------------------------------------------
-- 2. A test order never submits, and only the server sets is_test
--------------------------------------------------------------------------
create or replace function public.orders_test_never_submits()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if coalesce(current_setting('app.mcp_order_write', true), '') <> 'on'
     and auth.uid() is not null
     and ((tg_op = 'INSERT' and new.is_test)
          or (tg_op = 'UPDATE' and new.is_test is distinct from old.is_test)) then
    raise exception 'protected_column: is_test is set by the server'
      using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and new.is_test
     and old.status = 'draft' and new.status is distinct from 'draft'
     and new.status is distinct from 'cancelled' then
    raise exception 'test_order: order % is a test draft and cannot be submitted; cancel it, or have Claude draft it again without is_test', new.id
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke execute on function public.orders_test_never_submits() from public, anon, authenticated;

drop trigger if exists trg_orders_test_never_submits on public.orders;
create trigger trg_orders_test_never_submits
  before insert or update on public.orders
  for each row execute function public.orders_test_never_submits();

--------------------------------------------------------------------------
-- 3. Helpers
--------------------------------------------------------------------------
-- "AL'S SPORTING GOODS", "Al's Sporting Goods" and "ALS SPORTING GOODS"
-- are one name; so are "Sports South" and "Sports South LLC".
create or replace function public.customer_name_key(p text)
returns text
language sql immutable set search_path = public
as $$
  select nullif(replace(regexp_replace(regexp_replace(regexp_replace(
           upper(coalesce(p, '')), '''', '', 'g'),
           '[^A-Z0-9]+', ' ', 'g'),
           '( (LLC|INC|CO|CORP|CORPORATION|LTD|COMPANY))+ *$', ''), ' ', ''), '')
$$;
revoke execute on function public.customer_name_key(text) from public, anon;
grant execute on function public.customer_name_key(text) to authenticated;

-- A full scan normalising ~42k names costs ~190 ms; every draft asks.
create index if not exists idx_dim_customer_name_key
  on erp.dim_customer (public.customer_name_key(customer_name));

-- Other active accounts with the same name that the caller may order for.
-- DEFINER callers restate the read policy (admin, or on my book).
create or replace function public.order_same_name_accounts(p_customer_key text)
returns jsonb
language plpgsql stable security invoker set search_path = public, erp
as $$
declare
  v_name text;
begin
  select public.customer_name_key(dc.customer_name) into v_name
  from erp.dim_customer dc where dc.customer_key = p_customer_key;
  if v_name is null then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'customer_key',  d.customer_key,
             'customer_name', d.customer_name,
             'customer_type', d.customer_type,
             'city',          nullif(btrim(d.sold_to_city), ''),
             'state',         nullif(btrim(d.sold_to_state), ''),
             'last_order_date', d.last_order_date,
             'has_price_list', exists (select 1 from public.effective_price_lists(d.customer_type) l
                                       where not l.is_special),
             'orderable_ship_tos', (select count(*) from erp.dim_ship_to s
                                    where s.customer_id = d.customer_key and s.address_source = 'ShipTo'
                                      and not coalesce(s.is_unknown_ship_to, false)
                                      and nullif(btrim(s.ship_to_id), '') is not null
                                      and upper(coalesce(s.active_flag, 'Y')) <> 'N'),
             'this_one',      d.customer_key = p_customer_key)
             order by (d.customer_key = p_customer_key) desc, d.last_order_date desc nulls last, d.customer_key)
    from erp.dim_customer d
    where public.customer_name_key(d.customer_name) = v_name
      and upper(coalesce(d.active_flag, 'Y')) <> 'N'
      and (public.is_admin() or d.customer_key in (select public.my_customer_keys()))
    having count(*) > 1), '[]'::jsonb);
end;
$$;
revoke execute on function public.order_same_name_accounts(text) from public, anon;
grant execute on function public.order_same_name_accounts(text) to authenticated;

comment on function public.order_same_name_accounts(text) is
  'Active accounts the caller can see whose name matches this one''s '
  '(customer_name_key), this one first; [] when it is the only one.';

-- The account's orderable ship-tos as confirmation choices.
create or replace function public.order_ship_to_choices(p_customer_key text)
returns jsonb
language sql stable security definer set search_path = public, erp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'ship_to_key', s.ship_to_key,
           'ship_to_id',  s.ship_to_id,
           'name',        s.ship_to_name,
           'address',     nullif(concat_ws(', ', nullif(btrim(s.address1), ''),
                            nullif(btrim(s.address2), ''), nullif(btrim(s.address3), '')), ''),
           'city',        s.city,
           'state',       s.state,
           'ffl_number',  nullif(btrim(s.ffl_license_number), ''),
           'ffl_expires', public.parse_ffl_expiry(s.ffl_expiration_raw),
           'ffl_current', public.ffl_on_file_current(s.ffl_license_number, s.ffl_expiration_raw))
           order by public.ffl_on_file_current(s.ffl_license_number, s.ffl_expiration_raw) desc,
                    s.addr_no nulls last, s.ship_to_key), '[]'::jsonb)
  from erp.dim_ship_to s
  where s.customer_id = p_customer_key
    and s.address_source = 'ShipTo'
    and not coalesce(s.is_unknown_ship_to, false)
    and nullif(btrim(s.ship_to_id), '') is not null
    and upper(coalesce(s.active_flag, 'Y')) <> 'N'
$$;
revoke execute on function public.order_ship_to_choices(text) from public, anon, authenticated;

-- A part and its nearest priced siblings (same chambering, same model line)
-- for a part_confirmation_required refusal. The edge function turns each
-- into a short label ("RH · Ridgeline FFT · Carbon/Gray · $1,566.67").
create or replace function public.order_part_choices(p_customer_type text, p_part_id text, p_limit int default 6)
returns jsonb
language sql stable security definer set search_path = public, erp
as $$
  with me as (
    select p.part_id, p.product_family, p.chambering, p.stock_color, p.handedness, p.barrel_length
    from erp.dim_part p where p.part_id = p_part_id order by p.part_key limit 1
  ),
  priced as (
    select distinct on (i.part_id) i.part_id, i.unit_price, l.name as price_list_name
    from public.effective_price_lists(p_customer_type) l
    join public.price_list_items i on i.price_list_id = l.id
    where not l.is_special
    order by i.part_id, l.effective_from desc, l.id
  ),
  cand as (
    select pr.part_id, pr.unit_price, pr.price_list_name,
           dp.part_description, dp.product_family, dp.chambering, dp.barrel_length,
           dp.finish, dp.stock_color, dp.handedness, dp.status
    from priced pr
    join lateral (select p.* from erp.dim_part p where p.part_id = pr.part_id
                  order by p.part_key limit 1) dp on true
    cross join me
    where pr.part_id = me.part_id
       or (upper(btrim(dp.chambering)) = upper(btrim(me.chambering))
           and split_part(upper(btrim(dp.product_family)), ' ', 1)
               = split_part(upper(btrim(me.product_family)), ' ', 1)
           and coalesce(dp.status, '') = 'A'
           and coalesce(dp.is_kit_flag, 'N') <> 'Y')
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'part_id',       c.part_id,
           'description',   c.part_description,
           'family',        c.product_family,
           'chambering',    c.chambering,
           'barrel_length', c.barrel_length,
           'finish',        c.finish,
           'stock_color',   c.stock_color,
           'handedness',    c.handedness,
           'unit_price',    c.unit_price,
           'price_list',    c.price_list_name,
           'as_sent',       c.part_id = p_part_id) order by c.rn), '[]'::jsonb)
  from (
    select c.*, row_number() over (
             order by (c.part_id = me.part_id) desc,
                      (upper(c.stock_color) is not distinct from upper(me.stock_color)) desc,
                      (upper(c.product_family) is not distinct from upper(me.product_family)) desc,
                      (c.barrel_length is not distinct from me.barrel_length) desc,
                      (c.handedness is not distinct from me.handedness) desc,
                      c.part_id) as rn
    from cand c cross join me
  ) c
  where c.rn <= greatest(1, least(coalesce(p_limit, 6), 12))
$$;
revoke execute on function public.order_part_choices(text, text, int) from public, anon, authenticated;

-- How a contact is named: name, first + last, e-mail, then the id.
create or replace function public.contact_display_name(
  p_contact_name text, p_first text, p_last text, p_email text, p_contact_id text)
returns text
language sql immutable set search_path = public
as $$
  select coalesce(nullif(btrim(p_contact_name), ''),
                  nullif(btrim(concat_ws(' ', btrim(p_first), btrim(p_last))), ''),
                  nullif(btrim(p_email), ''),
                  p_contact_id)
$$;
revoke execute on function public.contact_display_name(text, text, text, text, text) from public, anon;
grant execute on function public.contact_display_name(text, text, text, text, text) to authenticated;

--------------------------------------------------------------------------
-- 4. order_context (restated from 20261111100100): contact names, FFL
--    expiry, same-name accounts, the real data_as_of
--------------------------------------------------------------------------
create or replace function public.order_context(p_customer_key text)
returns jsonb
language plpgsql stable security invoker set search_path = public, erp
as $$
declare
  c          record;
  v_blockers text[] := '{}';
  v_ships    jsonb;
  v_n_ok     int;
  v_default  text;
begin
  select dc.customer_key, dc.customer_name, dc.customer_type, dc.credit_status,
         dc.active_flag, dc.loaded_at
    into c
  from erp.dim_customer dc
  where dc.customer_key = p_customer_key;
  if not found then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', p_customer_key;
  end if;

  if upper(coalesce(c.active_flag, 'Y')) = 'N' then
    v_blockers := v_blockers || 'inactive'::text;
  end if;
  if upper(coalesce(c.credit_status, '')) like 'HOLD%' then
    v_blockers := v_blockers || 'credit_hold'::text;
  end if;
  if not exists (select 1 from public.effective_price_lists(c.customer_type) l where not l.is_special) then
    v_blockers := v_blockers || 'no_price_list_for_type'::text;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'ship_to_key', s.ship_to_key,
           'ship_to_id',  s.ship_to_id,
           'addr_no',     s.addr_no,
           'name',        s.ship_to_name,
           'address',     nullif(concat_ws(', ', nullif(btrim(s.address1), ''),
                                 nullif(btrim(s.address2), ''), nullif(btrim(s.address3), '')), ''),
           'city',        s.city,
           'state',       s.state,
           'zip',         s.zip_code,
           'active',      upper(coalesce(s.active_flag, 'Y')) <> 'N',
           'orderable',   s.ok,
           'ffl', jsonb_build_object(
                    'number_on_file', nullif(btrim(s.ffl_license_number), ''),
                    'expires_raw',    nullif(btrim(s.ffl_expiration_raw), ''),
                    'expires_on',     public.parse_ffl_expiry(s.ffl_expiration_raw),
                    'current',        public.ffl_on_file_current(s.ffl_license_number, s.ffl_expiration_raw)))
           order by s.ok desc, s.addr_no nulls last, s.ship_to_key), '[]'::jsonb),
         count(*) filter (where s.ok),
         min(s.ship_to_key) filter (where s.ok)
    into v_ships, v_n_ok, v_default
  from (
    select x.*,
           (nullif(btrim(x.ship_to_id), '') is not null
            and upper(coalesce(x.active_flag, 'Y')) <> 'N') as ok
    from erp.dim_ship_to x
    where x.customer_id = c.customer_key
      and x.address_source = 'ShipTo'
      and not coalesce(x.is_unknown_ship_to, false)
  ) s;

  if v_n_ok = 0 then
    v_blockers := v_blockers || 'no_orderable_ship_to'::text;
  end if;

  return jsonb_build_object(
    'customer', jsonb_build_object(
       'customer_key',  c.customer_key,
       'customer_name', c.customer_name,
       'customer_type', c.customer_type,
       'credit_status', c.credit_status,
       'active',        upper(coalesce(c.active_flag, 'Y')) <> 'N'),
    'orderable', cardinality(v_blockers) = 0,
    'blockers',  to_jsonb(v_blockers),
    'same_name_accounts', public.order_same_name_accounts(c.customer_key),
    'price_lists', coalesce((
       select jsonb_agg(jsonb_build_object(
                'price_list_id', l.id,
                'name',          l.name,
                'is_special',    l.is_special,
                'promo_buy_qty', l.promo_buy_qty,
                'promo_get_qty', l.promo_get_qty)
              order by l.is_special, l.effective_from desc, l.id)
       from public.effective_price_lists(c.customer_type) l), '[]'::jsonb),
    'ship_tos', v_ships,
    'orderable_ship_to_count', v_n_ok,
    'default_ship_to_key', case when v_n_ok = 1 then v_default end,
    'contacts', coalesce((
       select jsonb_agg(jsonb_build_object(
                'customer_contact_key', k.customer_contact_key,
                'name',       k.name,
                'title',      k.title,
                'email',      k.email,
                'phone',      k.phone,
                'is_primary', k.is_primary)
              order by k.is_primary desc, k.name, k.customer_contact_key)
       from (
         select e.customer_contact_key,
                public.contact_display_name(e.contact_name, e.first_name, e.last_name, e.email, e.contact_id) as name,
                nullif(btrim(e.position), '') as title,
                nullif(btrim(e.email), '') as email,
                coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')) as phone,
                coalesce(e.primary_contact_flag = 'Y', false) as is_primary
         from erp.dim_customer_contact e
         where e.customer_key = c.customer_key
           and coalesce(e.contact_active_flag, 'Y') = 'Y'
         order by coalesce(e.primary_contact_flag = 'Y', false) desc, e.customer_contact_key
         limit 25) k), '[]'::jsonb),
    'recent_orders', coalesce((
       select jsonb_agg(jsonb_build_object(
                'order_id',     r.id,
                'status',       r.status,
                'po_number',    r.po_number,
                'created_at',   r.created_at,
                'total_amount', r.total_amount,
                'source',       r.source,
                'is_test',      r.is_test)
              order by r.created_at desc, r.id desc)
       from (select o.id, o.status, o.po_number, o.created_at, o.total_amount, o.source, o.is_test
             from public.orders o
             where o.customer_key = c.customer_key
             order by o.created_at desc, o.id desc
             limit 10) r), '[]'::jsonb),
    -- The last successful load, not this row's last change (a quiet
    -- account's row is not rewritten, so its loaded_at stands still).
    'data_as_of', coalesce((select f.data_loaded_at from public.v_data_freshness f), c.loaded_at),
    'account_changed_at', c.loaded_at);
end;
$$;

revoke execute on function public.order_context(text) from public, anon;
grant execute on function public.order_context(text) to authenticated;

comment on function public.order_context(text) is
  'Account context for drafting an order: customer, blockers, same-name '
  'accounts, effective price lists, ship-tos (orderable = submit_order''s '
  'rule) with FFL on file and expiry, contacts, recent portal orders, '
  'data_as_of = last ETL run. RLS-scoped (SECURITY INVOKER).';

--------------------------------------------------------------------------
-- 5. mcp_order_check_keys (restated): the new fields
--------------------------------------------------------------------------
create or replace function public.mcp_order_check_keys(p jsonb, p_update boolean)
returns void
language plpgsql immutable set search_path = public
as $$
declare
  c_top  constant text[] := array['idempotency_key','customer_key','customer_confirmed','ship_to_key',
                                  'ship_to_confirmed','po_number','requested_ship_date',
                                  'customer_contact_key','notes','allow_duplicate','source_ref',
                                  'is_test','lines'];
  c_line constant text[] := array['part_id','qty','price_list_id','part_confirmed','expected_unit_price'];
  c_price constant text[] := array['unit_price','price','prices','discount_pct','effective_unit_price',
                                   'line_total','total_amount','total'];
  c_ffl  constant text[] := array['ffl_license_number','ffl_expires_on','ffl','ffl_number'];
  k text;
  l jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_input:body: the request must be a JSON object';
  end if;
  for k in select jsonb_object_keys(p) loop
    if k = any (c_price) then
      raise exception 'invalid_input:%: prices are set by the server from the published price list', k;
    elsif k = any (c_ffl) then
      raise exception 'invalid_input:%: an FFL is never supplied here; the licence on file is used, or the person submitting enters one in the portal', k;
    elsif not (k = any (c_top)) then
      raise exception 'invalid_input:unknown_field:%: not an order field', k;
    end if;
  end loop;
  if jsonb_typeof(p -> 'lines') = 'array' then
    for l in select jsonb_array_elements(p -> 'lines') loop
      if jsonb_typeof(l) <> 'object' then
        raise exception 'invalid_input:lines: every line must be an object {part_id, qty, part_confirmed, price_list_id?, expected_unit_price?}';
      end if;
      for k in select jsonb_object_keys(l) loop
        if k = any (c_price) then
          raise exception 'invalid_input:%: prices are set by the server from the published price list; pass the price the user expects as expected_unit_price', k;
        elsif k = any (c_ffl) then
          raise exception 'invalid_input:%: an FFL is never supplied here', k;
        elsif not (k = any (c_line)) then
          raise exception 'invalid_input:unknown_field:%: not a line field (part_id, qty, part_confirmed, price_list_id, expected_unit_price)', k;
        end if;
      end loop;
    end loop;
  end if;
  foreach k in array array['customer_confirmed', 'ship_to_confirmed', 'is_test'] loop
    if p ? k and jsonb_typeof(p -> k) not in ('boolean', 'null') then
      raise exception 'invalid_input:%: must be true or false', k;
    end if;
  end loop;
end;
$$;

--------------------------------------------------------------------------
-- 6. mcp_order_apply (restated): confirmations, PO, expected price, test,
--    ERP description first
--------------------------------------------------------------------------
create or replace function public.mcp_order_apply(
  p_order_id bigint,
  p          jsonb,
  p_params   jsonb,
  p_idem_key text,
  p_hash     text
)
returns bigint
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_uid      uuid := auth.uid();
  v_guc      text := current_setting('app.mcp_order_write', true);
  v_max_lines int     := coalesce((p_params ->> 'max_lines')::int, 40);
  v_max_units int     := coalesce((p_params ->> 'max_units_per_line')::int, 200);
  v_max_value numeric := coalesce((p_params ->> 'max_order_value')::numeric, 250000);
  v_max_day   int     := coalesce((p_params ->> 'max_drafts_per_user_per_day')::int, 25);
  v_window    int     := coalesce((p_params ->> 'duplicate_window_days')::int, 14);
  v_cur      public.orders;
  v_ck       text;
  v_cust     record;
  v_ship     erp.dim_ship_to;
  v_ship_key text;
  v_n        int;
  v_po       text;
  v_date     date;
  v_contact  text;
  v_notes    text;
  v_allow    boolean := false;
  v_test     boolean := false;
  v_ref      jsonb;
  v_line     jsonb;
  v_part     text;
  v_qty      numeric;
  v_plid     bigint;
  v_exp      numeric;
  v_item     record;
  v_priced   jsonb := '[]'::jsonb;
  v_unconf   jsonb := '[]'::jsonb;
  v_ix       int := -1;
  v_choices  jsonb;
  v_total    numeric;
  v_set      jsonb;
  v_dup      bigint;
  v_tok      uuid;
  v_id       bigint;
  k          text;
begin
  if p_order_id is not null then
    select * into v_cur from public.orders where id = p_order_id;
  end if;

  -- Customer, and the caller's right to draft for it (DEFINER bypasses RLS,
  -- so the read policy is restated: admin, or the account is on my book).
  if p ? 'customer_key' and jsonb_typeof(p -> 'customer_key') <> 'null' then
    if jsonb_typeof(p -> 'customer_key') <> 'string' or btrim(p ->> 'customer_key') = '' then
      raise exception 'invalid_input:customer_key: a customer_key string is required';
    end if;
    v_ck := btrim(p ->> 'customer_key');
  else
    v_ck := v_cur.customer_key;
  end if;
  if v_ck is null then
    raise exception 'invalid_input:customer_key: a customer_key is required';
  end if;
  select dc.customer_key, dc.customer_name, dc.customer_type into v_cust
  from erp.dim_customer dc where dc.customer_key = v_ck;
  if not found
     or not (public.is_admin() or v_ck in (select public.my_customer_keys())) then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', v_ck;
  end if;

  -- Several active accounts by this name: the user picks one.
  if (p -> 'customer_confirmed') is distinct from 'true'::jsonb then
    v_choices := public.order_same_name_accounts(v_ck);
    if jsonb_array_length(v_choices) > 1 then
      raise exception using
        message = format('customer_confirmation_required:%s: %s active accounts are named like %s; show them to the user, then send customer_confirmed=true with the one they pick',
                         v_ck, jsonb_array_length(v_choices), v_cust.customer_name),
        detail  = jsonb_build_object('error', 'customer_confirmation_required', 'choices', v_choices)::text;
    end if;
  end if;

  -- Ship-to: a given one must be an orderable ship-to of this account. With
  -- more than one orderable, the user must have picked it
  -- (ship_to_confirmed); with exactly one, it is used.
  select count(*), min(s.ship_to_key) into v_n, v_ship_key
  from erp.dim_ship_to s
  where s.customer_id = v_ck and s.address_source = 'ShipTo'
    and not coalesce(s.is_unknown_ship_to, false)
    and nullif(btrim(s.ship_to_id), '') is not null
    and upper(coalesce(s.active_flag, 'Y')) <> 'N';
  if v_n <> 1 then
    v_ship_key := null;
  end if;

  if p ? 'ship_to_key' and jsonb_typeof(p -> 'ship_to_key') <> 'null' then
    if jsonb_typeof(p -> 'ship_to_key') <> 'string' then
      raise exception 'invalid_input:ship_to_key: must be a string';
    end if;
    v_ship_key := btrim(p ->> 'ship_to_key');
    select s.* into v_ship from erp.dim_ship_to s
    where s.ship_to_key = v_ship_key
      and s.customer_id = v_ck
      and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false)
      and nullif(btrim(s.ship_to_id), '') is not null;
    if not found then
      raise exception 'ship_to_invalid:%: not one of this account''s ship-to addresses', v_ship_key;
    end if;
    if upper(coalesce(v_ship.active_flag, 'Y')) = 'N' then
      raise exception 'ship_to_invalid:%: the ship-to % is inactive in the ERP; pick another', v_ship_key, v_ship.ship_to_id;
    end if;
    if v_n > 1 and (p -> 'ship_to_confirmed') is distinct from 'true'::jsonb then
      raise exception using
        message = format('ship_to_confirmation_required:%s: %s has %s orderable ship-tos; show them (with FFL number and expiry) to the user, then send ship_to_confirmed=true with the one they pick',
                         v_ck, v_ck, v_n),
        detail  = jsonb_build_object('error', 'ship_to_confirmation_required',
                                     'choices', public.order_ship_to_choices(v_ck))::text;
    end if;
  elsif v_n > 1 then
    raise exception using
      message = format('ship_to_confirmation_required:%s: %s has %s orderable ship-tos; show them (with FFL number and expiry) to the user, then send ship_to_key and ship_to_confirmed=true',
                       v_ck, v_ck, v_n),
      detail  = jsonb_build_object('error', 'ship_to_confirmation_required',
                                   'choices', public.order_ship_to_choices(v_ck))::text;
  end if;

  if p ? 'po_number' and jsonb_typeof(p -> 'po_number') <> 'null' then
    if jsonb_typeof(p -> 'po_number') not in ('string', 'number') then
      raise exception 'invalid_input:po_number: must be text';
    end if;
    v_po := nullif(btrim(p ->> 'po_number'), '');
    if length(v_po) > 40 then
      raise exception 'invalid_input:po_number: 40 characters at most';
    end if;
  end if;
  if v_po is null then
    raise exception 'po_required: the customer''s PO number is required; ask the user for it and never invent one';
  end if;

  if p ? 'requested_ship_date' and jsonb_typeof(p -> 'requested_ship_date') <> 'null' then
    begin
      if jsonb_typeof(p -> 'requested_ship_date') <> 'string'
         or (p ->> 'requested_ship_date') !~ '^\d{4}-\d{2}-\d{2}$' then
        raise exception 'bad';
      end if;
      v_date := (p ->> 'requested_ship_date')::date;
    exception when others then
      raise exception 'invalid_input:requested_ship_date: use YYYY-MM-DD';
    end;
    if v_date < current_date then
      raise exception 'invalid_input:requested_ship_date: % is in the past', v_date;
    end if;
  end if;

  if p ? 'customer_contact_key' and jsonb_typeof(p -> 'customer_contact_key') <> 'null' then
    v_contact := btrim(p ->> 'customer_contact_key');
    if jsonb_typeof(p -> 'customer_contact_key') <> 'string'
       or not exists (select 1 from erp.dim_customer_contact e
                      where e.customer_contact_key = v_contact and e.customer_key = v_ck
                        and coalesce(e.contact_active_flag, 'Y') = 'Y') then
      raise exception 'invalid_input:customer_contact_key: not an active contact on this account';
    end if;
  end if;

  if p ? 'notes' and jsonb_typeof(p -> 'notes') <> 'null' then
    if jsonb_typeof(p -> 'notes') <> 'string' then
      raise exception 'invalid_input:notes: must be text';
    end if;
    v_notes := nullif(btrim(p ->> 'notes'), '');
    if length(v_notes) > 1000 then
      raise exception 'invalid_input:notes: 1000 characters at most';
    end if;
  end if;

  if p ? 'allow_duplicate' and jsonb_typeof(p -> 'allow_duplicate') <> 'null' then
    if jsonb_typeof(p -> 'allow_duplicate') <> 'boolean' then
      raise exception 'invalid_input:allow_duplicate: must be true or false';
    end if;
    v_allow := (p -> 'allow_duplicate')::boolean;
  end if;

  v_test := coalesce((p -> 'is_test') = 'true'::jsonb, false);

  if p ? 'source_ref' and jsonb_typeof(p -> 'source_ref') <> 'null' then
    v_ref := p -> 'source_ref';
    if jsonb_typeof(v_ref) <> 'object' or v_ref ->> 'kind' is distinct from 'email' then
      raise exception 'invalid_input:source_ref: must be {kind:"email", sender, subject, received_at, excerpt}';
    end if;
    for k in select jsonb_object_keys(v_ref) loop
      if not (k = any (array['kind','sender','subject','received_at','excerpt','message_id']))
         or jsonb_typeof(v_ref -> k) not in ('string', 'null') then
        raise exception 'invalid_input:source_ref: field % is not allowed or not text', k;
      end if;
    end loop;
    if length(v_ref ->> 'excerpt') > 4000 then
      raise exception 'invalid_input:source_ref: excerpt is 4000 characters at most';
    end if;
    if greatest(length(v_ref ->> 'sender'), length(v_ref ->> 'subject'),
                length(v_ref ->> 'received_at'), length(v_ref ->> 'message_id')) > 500 then
      raise exception 'invalid_input:source_ref: sender, subject, received_at and message_id are 500 characters at most';
    end if;
  end if;

  -- Lines: price every one on the server.
  if jsonb_typeof(p -> 'lines') is distinct from 'array' or jsonb_array_length(p -> 'lines') = 0 then
    raise exception 'invalid_input:lines: at least one line {part_id, qty, part_confirmed} is required';
  end if;
  if jsonb_array_length(p -> 'lines') > v_max_lines then
    raise exception 'too_many_lines: % lines; % at most', jsonb_array_length(p -> 'lines'), v_max_lines;
  end if;

  for v_line in select jsonb_array_elements(p -> 'lines') loop
    v_ix := v_ix + 1;
    if jsonb_typeof(v_line -> 'part_id') is distinct from 'string' or btrim(v_line ->> 'part_id') = '' then
      raise exception 'invalid_input:part_id: every line needs a part_id';
    end if;
    v_part := btrim(v_line ->> 'part_id');
    if jsonb_typeof(v_line -> 'qty') is distinct from 'number' then
      raise exception 'invalid_input:qty: line % needs a whole-number qty', v_part;
    end if;
    v_qty := (v_line ->> 'qty')::numeric;
    if v_qty <> trunc(v_qty) then
      raise exception 'invalid_input:qty: line % needs a whole-number qty', v_part;
    end if;
    if v_qty < 1 or v_qty > v_max_units then
      raise exception 'qty_out_of_range:%: qty % is outside 1-%', v_part, v_qty, v_max_units;
    end if;
    v_plid := null;
    if v_line ? 'price_list_id' and jsonb_typeof(v_line -> 'price_list_id') <> 'null' then
      if jsonb_typeof(v_line -> 'price_list_id') <> 'number'
         or (v_line ->> 'price_list_id')::numeric <> trunc((v_line ->> 'price_list_id')::numeric) then
        raise exception 'invalid_input:price_list_id: line % has a price_list_id that is not a whole number', v_part;
      end if;
      v_plid := (v_line ->> 'price_list_id')::bigint;
    end if;
    v_exp := null;
    if v_line ? 'expected_unit_price' and jsonb_typeof(v_line -> 'expected_unit_price') <> 'null' then
      if jsonb_typeof(v_line -> 'expected_unit_price') <> 'number'
         or (v_line ->> 'expected_unit_price')::numeric <= 0
         or (v_line ->> 'expected_unit_price')::numeric >= 10000000000 then
        raise exception 'invalid_input:expected_unit_price: line % needs a positive number (the unit price the user said)', v_part;
      end if;
      v_exp := round((v_line ->> 'expected_unit_price')::numeric, 2);
    end if;
    if v_line ? 'part_confirmed' and jsonb_typeof(v_line -> 'part_confirmed') not in ('boolean', 'null') then
      raise exception 'invalid_input:part_confirmed: line % must send true or false', v_part;
    end if;

    if exists (select 1 from erp.dim_part dp where dp.part_id = v_part and dp.is_kit_flag = 'Y') then
      raise exception 'kit_not_supported:%: kits cannot be ordered here', v_part;
    end if;

    select l.id as list_id, l.name as list_name, i.id as item_id, i.unit_price, i.description
      into v_item
    from public.effective_price_lists(v_cust.customer_type) l
    join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_part
    where (v_plid is null and not l.is_special) or l.id = v_plid
    order by l.effective_from desc, l.id
    limit 1;
    if not found then
      if v_plid is null then
        raise exception 'part_not_orderable:%: not on this account''s price list', v_part;
      end if;
      raise exception 'part_not_orderable:%: not on price list % (or that list is not effective for this account)', v_part, v_plid;
    end if;

    if exists (select 1 from jsonb_array_elements(v_priced) e
               where e ->> 'part_id' = v_part and (e ->> 'price_list_id')::bigint = v_item.list_id) then
      raise exception 'invalid_input:duplicate_line:%: the part appears twice on the same price list; send one line with the total qty', v_part;
    end if;

    if (v_line -> 'part_confirmed') is distinct from 'true'::jsonb then
      v_unconf := v_unconf || jsonb_build_object(
        'line', v_ix, 'part_id', v_part,
        'choices', public.order_part_choices(v_cust.customer_type, v_part, 6));
    end if;

    -- The ERP part master's description first (the uploaded list's column
    -- is only a fallback: the Buy Group sheet carried the UPC there).
    v_priced := v_priced || jsonb_build_object(
      'part_id', v_part, 'qty', v_qty::int, 'price_list_id', v_item.list_id,
      'item_id', v_item.item_id, 'unit_price', v_item.unit_price,
      'expected_unit_price', v_exp,
      'description', coalesce(
         (select dp.part_description from erp.dim_part dp
           where dp.part_id = v_part and nullif(btrim(dp.part_description), '') is not null
           order by coalesce(dp.is_unknown_part, false), dp.part_key limit 1),
         v_item.description));
  end loop;

  if jsonb_array_length(v_unconf) > 0 then
    raise exception using
      message = format('part_confirmation_required:%s: %s line(s) were not confirmed by the user; show the choices, then send part_confirmed=true on every line',
                       v_unconf -> 0 ->> 'part_id', jsonb_array_length(v_unconf)),
      detail  = jsonb_build_object('error', 'part_confirmation_required', 'lines', v_unconf)::text;
  end if;

  -- The same promo formula as submit_order (which re-runs it authoritatively).
  with x as (
    select * from jsonb_to_recordset(v_priced)
      as (part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
          expected_unit_price numeric, description text)
  ),
  pct as (
    select x.price_list_id,
           case when pl.promo_buy_qty is null then 0::numeric
                else round(100 * (floor(sum(x.qty)::numeric / (pl.promo_buy_qty + pl.promo_get_qty))
                                  * pl.promo_get_qty) / sum(x.qty)::numeric, 4)
           end as discount_pct
    from x join public.price_lists pl on pl.id = x.price_list_id
    group by x.price_list_id, pl.promo_buy_qty, pl.promo_get_qty
  )
  select jsonb_agg(to_jsonb(x) || jsonb_build_object(
           'discount_pct', pct.discount_pct,
           'effective_unit_price', round(x.unit_price * (1 - pct.discount_pct / 100), 2))),
         sum(x.qty * round(x.unit_price * (1 - pct.discount_pct / 100), 2)),
         (select jsonb_agg(jsonb_build_array(s.part_id, s.q) order by s.part_id)
            from (select x2.part_id, sum(x2.qty) as q from x x2 group by x2.part_id) s)
    into v_priced, v_total, v_set
  from x join pct using (price_list_id);

  if v_total > v_max_value then
    raise exception 'order_value_cap: the order totals %; drafts over MCP are capped at %', v_total, v_max_value;
  end if;

  -- One draft write per user at a time: the cap and the duplicate probe
  -- below are check-then-insert, and models do issue parallel tool calls.
  perform pg_advisory_xact_lock(hashtextextended('mcp_order_apply|' || v_uid::text, 0));

  if p_order_id is null then
    select count(*) into v_n
    from public.orders o
    where o.created_by = v_uid and o.source <> 'portal'
      and o.created_at >= date_trunc('day', now());
    if v_n >= v_max_day then
      raise exception 'daily_draft_cap: % drafts today; % per day at most', v_n, v_max_day;
    end if;
  end if;

  -- Duplicate block: a model that retries usually invents a new key.
  if not v_allow then
    select o.id into v_dup
    from public.orders o
    where o.user_id = coalesce(v_cur.user_id, v_uid)
      and o.customer_key = v_ck
      and o.status <> 'cancelled'
      and o.created_at >= now() - make_interval(days => v_window)
      and o.id is distinct from p_order_id
      and (   (v_po is not null and upper(btrim(o.po_number)) = upper(v_po))
           or v_set = (select jsonb_agg(jsonb_build_array(s.part_id, s.q) order by s.part_id)
                       from (select l.part_id, sum(l.qty) as q from public.order_lines l
                             where l.order_id = o.id group by l.part_id) s))
    order by o.created_at desc, o.id desc
    limit 1;
    if v_dup is not null then
      raise exception 'possible_duplicate:%: order % for this account has the same PO or the same lines; ask the user, then send allow_duplicate=true to draft anyway', v_dup, v_dup;
    end if;
  end if;

  perform set_config('app.mcp_order_write', 'on', true);

  if p_order_id is null then
    if (auth.jwt() -> 'app_metadata' ->> 'mcp_token_id')
         ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_tok := (auth.jwt() -> 'app_metadata' ->> 'mcp_token_id')::uuid;
    end if;
    begin
      insert into public.orders (
        user_id, created_by, customer_key, customer_name, customer_type, status, source,
        po_number, requested_ship_date, notes, ship_to_key, customer_contact_key,
        source_ref, mcp_token_id, client_request_id, request_hash, is_test)
      values (
        v_uid, v_uid, v_ck, coalesce(v_cust.customer_name, ''), v_cust.customer_type, 'draft', 'mcp',
        v_po, v_date, v_notes, v_ship_key, v_contact,
        v_ref, v_tok, p_idem_key, p_hash, v_test)
      returning id into v_id;
    exception when unique_violation then
      raise exception 'idempotency_conflict: a request with this idempotency_key is already being processed; retry';
    end;
  else
    v_id := p_order_id;
    update public.orders
    set customer_key         = v_ck,
        customer_name        = coalesce(v_cust.customer_name, ''),
        customer_type        = v_cust.customer_type,
        po_number            = v_po,
        requested_ship_date  = v_date,
        notes                = v_notes,
        ship_to_key          = v_ship_key,
        customer_contact_key = v_contact,
        source_ref           = coalesce(v_ref, source_ref),
        is_test              = v_test
    where id = v_id;
    delete from public.order_lines where order_id = v_id;
  end if;

  insert into public.order_lines (order_id, price_list_id, price_list_item_id, part_id, description,
                                  qty, unit_price, discount_pct, effective_unit_price,
                                  mcp_expected_unit_price)
  select v_id, x.price_list_id, x.item_id, x.part_id, x.description,
         x.qty, x.unit_price, x.discount_pct, x.effective_unit_price, x.expected_unit_price
  from jsonb_to_recordset(v_priced)
    as x(part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
         description text, discount_pct numeric, effective_unit_price numeric,
         expected_unit_price numeric);

  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);
  return v_id;
end;
$$;

--------------------------------------------------------------------------
-- 7. mcp_order_preview (restated): alerts (price_mismatch, ffl_not_current,
--    test_order), expected prices on lines, contact name fallback
--------------------------------------------------------------------------
create or replace function public.mcp_order_preview(p_order_id bigint, p_replayed boolean)
returns jsonb
language plpgsql security definer set search_path = public, erp
as $$
declare
  c_ok    constant text := '__mcp_dry_run_ok__';
  o       public.orders;
  v_ok    boolean := false;
  v_err   text;
  v_lines jsonb;
  v_total numeric;
  v_ship  erp.dim_ship_to;
  v_has_ship boolean := false;
  v_cust  record;
  v_needs boolean;
  v_cur   boolean := false;
  v_onf   boolean := false;
  v_contact jsonb;
  v_warn  text[] := '{}';
  v_alerts jsonb := '[]'::jsonb;
  v_n_ok  int;
  v_dry   text;
  r       record;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    raise exception 'order_not_found: order % not found', p_order_id;
  end if;

  if o.status = 'draft' then
    -- submit_order refuses an MCP session unless this dry-run flag is on.
    -- Set OUTSIDE the subtransaction (so the sentinel rollback cannot undo
    -- it) and put back right after it.
    v_dry := current_setting('app.mcp_dry_run', true);
    perform set_config('app.mcp_dry_run', 'on', true);
    begin
      perform public.submit_order(p_order_id, true);
      select jsonb_agg(jsonb_build_object(
               'part_id', l.part_id, 'description', l.description, 'qty', l.qty,
               'price_list_id', l.price_list_id, 'price_list_name', pl.name,
               'unit_price', l.unit_price, 'discount_pct', l.discount_pct,
               'effective_unit_price', l.effective_unit_price, 'line_total', l.line_total,
               'expected_unit_price', l.mcp_expected_unit_price)
               order by l.id),
             sum(l.line_total)
        into v_lines, v_total
      from public.order_lines l join public.price_lists pl on pl.id = l.price_list_id
      where l.order_id = p_order_id;
      raise exception using message = c_ok;
    exception when others then
      if sqlerrm = c_ok then
        v_ok := true;
      else
        v_ok := false;
        v_err := sqlerrm;
        v_lines := null;
        v_total := null;
      end if;
    end;
    perform set_config('app.mcp_dry_run', coalesce(v_dry, ''), true);
  else
    v_err := format('order %s is %s; only drafts can be submitted', p_order_id, o.status);
  end if;

  if v_lines is null then
    select jsonb_agg(jsonb_build_object(
             'part_id', l.part_id, 'description', l.description, 'qty', l.qty,
             'price_list_id', l.price_list_id, 'price_list_name', pl.name,
             'unit_price', l.unit_price, 'discount_pct', l.discount_pct,
             'effective_unit_price', l.effective_unit_price, 'line_total', l.line_total,
             'expected_unit_price', l.mcp_expected_unit_price)
             order by l.id),
           sum(l.line_total)
      into v_lines, v_total
    from public.order_lines l join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = p_order_id;
  end if;

  -- Stock never blocks; it is reported per line.
  select coalesce(jsonb_agg(x.line || jsonb_build_object('ats_qty', x.ats) order by x.ord), '[]'::jsonb)
    into v_lines
  from (
    select e.line, e.ord,
           (select sum(a.available_to_sell_qty)
              from erp.fact_available_to_sell a
              join erp.dim_part dp on dp.part_key = a.part_key
             where dp.part_id = e.line ->> 'part_id') as ats
    from jsonb_array_elements(coalesce(v_lines, '[]'::jsonb)) with ordinality as e(line, ord)
  ) x;

  if o.is_test then
    v_alerts := v_alerts || jsonb_build_object('type', 'test_order', 'severity', 'hard',
      'message', 'Test draft: it is labelled TEST in the portal and can never be submitted.');
    v_warn := v_warn || 'TEST ORDER: this draft was made as a test and cannot be submitted.'::text;
  end if;

  for r in
    select e.line ->> 'part_id' as part_id, (e.line ->> 'qty')::int as qty,
           (e.line ->> 'ats_qty')::numeric as ats,
           (e.line ->> 'unit_price')::numeric as list_price,
           (e.line ->> 'effective_unit_price')::numeric as eff_price,
           (e.line ->> 'expected_unit_price')::numeric as expected,
           e.line ->> 'price_list_name' as list_name,
           (select min(dp.status) from erp.dim_part dp where dp.part_id = e.line ->> 'part_id') as status
    from jsonb_array_elements(v_lines) as e(line)
  loop
    if r.expected is not null and r.expected is distinct from r.eff_price then
      v_alerts := v_alerts || jsonb_build_object(
        'type', 'price_mismatch', 'severity', 'warning', 'part_id', r.part_id,
        'expected', r.expected, 'list', r.list_price, 'effective', r.eff_price,
        'difference', r.eff_price - r.expected, 'price_list', r.list_name);
      v_warn := v_warn || format('Price: the user expected $%s for %s; %s prices it at $%s (%s$%s each). The draft keeps the list price: a different price is agreed outside the portal.',
                                 to_char(r.expected, 'FM999,999,990.00'), r.part_id, r.list_name,
                                 to_char(r.eff_price, 'FM999,999,990.00'),
                                 case when r.eff_price > r.expected then '+' else '-' end,
                                 to_char(abs(r.eff_price - r.expected), 'FM999,999,990.00'));
    end if;
    if r.ats is null or r.ats < r.qty then
      v_warn := v_warn || format('Stock: %s has %s available to sell; %s ordered. Stock does not block the order.',
                                 r.part_id, coalesce(trim_scale(r.ats)::text, 'no'), r.qty);
    end if;
    if r.status is distinct from 'A' then
      v_warn := v_warn || format('%s is not an active part in the ERP (status %s).', r.part_id, coalesce(r.status, 'unknown'));
    end if;
  end loop;

  select dc.customer_name, dc.credit_status, dc.active_flag into v_cust
  from erp.dim_customer dc where dc.customer_key = o.customer_key;
  if upper(coalesce(v_cust.active_flag, 'Y')) = 'N' then
    v_warn := v_warn || 'The account is inactive in the ERP.'::text;
  end if;
  if upper(coalesce(v_cust.credit_status, '')) like 'HOLD%' then
    v_warn := v_warn || format('The account is on credit hold in the ERP (%s).', v_cust.credit_status);
  end if;

  v_needs := exists (select 1 from public.order_lines l
                     where l.order_id = p_order_id and public.part_requires_ffl(l.part_id));

  -- DEFINER: read only this account's own ship-to and contact, whatever key
  -- the row carries (a portal PATCH could point them at another account).
  if o.ship_to_key is not null then
    select s.* into v_ship from erp.dim_ship_to s
    where s.ship_to_key = o.ship_to_key
      and s.customer_id = o.customer_key
      and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false);
    v_has_ship := found;
  end if;
  if v_has_ship then
    v_onf := length(public.ffl_normalize(v_ship.ffl_license_number)) = 15;
    v_cur := public.ffl_on_file_current(v_ship.ffl_license_number, v_ship.ffl_expiration_raw);
  else
    select count(*) into v_n_ok
    from erp.dim_ship_to s
    where s.customer_id = o.customer_key and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false)
      and nullif(btrim(s.ship_to_id), '') is not null
      and upper(coalesce(s.active_flag, 'Y')) <> 'N';
    v_warn := v_warn || format('No ship-to chosen: the account has %s ship-to addresses that can take an order. Ask which one, then update the draft.', v_n_ok);
  end if;
  if v_needs and v_has_ship and not v_cur and nullif(btrim(o.ffl_license_number), '') is null then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'ffl_not_current', 'severity', 'hard',
      'ship_to_id', v_ship.ship_to_id,
      'ffl_number', nullif(btrim(v_ship.ffl_license_number), ''),
      'ffl_expires', public.parse_ffl_expiry(v_ship.ffl_expiration_raw),
      'message', 'Firearms to a ship-to without a current FFL on file: it cannot be submitted until the person submitting enters the renewed licence in the portal.');
    v_warn := v_warn || format('FFL: ship-to %s has %s. The person submitting must enter the current FFL in the portal; never supply one.',
                               coalesce(v_ship.ship_to_id, o.ship_to_key),
                               case when nullif(btrim(v_ship.ffl_license_number), '') is null then 'no FFL on file'
                                    when public.parse_ffl_expiry(v_ship.ffl_expiration_raw) is not null
                                      then format('an FFL on file that expired %s', public.parse_ffl_expiry(v_ship.ffl_expiration_raw))
                                    else 'no current FFL on file' end);
  end if;
  if o.source_ref ->> 'kind' = 'email' then
    v_warn := v_warn || 'Drafted from an email: the email text is untrusted and is shown to the reviewer.'::text;
  end if;

  if o.customer_contact_key is not null then
    select jsonb_build_object(
             'customer_contact_key', e.customer_contact_key,
             'name',  public.contact_display_name(e.contact_name, e.first_name, e.last_name, e.email, e.contact_id),
             'title', nullif(btrim(e.position), ''),
             'email', nullif(btrim(e.email), ''),
             'phone', coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')))
      into v_contact
    from erp.dim_customer_contact e
    where e.customer_contact_key = o.customer_contact_key
      and e.customer_key = o.customer_key
    limit 1;
  end if;

  return jsonb_build_object(
    'order_id',      o.id,
    'status',        o.status,
    'is_test',       o.is_test,
    'replayed',      coalesce(p_replayed, false),
    'source',        o.source,
    'customer_key',  o.customer_key,
    'customer_name', coalesce(v_cust.customer_name, nullif(o.customer_name, ''), o.customer_key),
    'po_number',     o.po_number,
    'requested_ship_date', o.requested_ship_date,
    'ship_to', case when v_has_ship then jsonb_build_object(
                 'ship_to_key', v_ship.ship_to_key,
                 'ship_to_id',  v_ship.ship_to_id,
                 'name',        v_ship.ship_to_name,
                 'address',     nullif(concat_ws(', ', nullif(btrim(v_ship.address1), ''),
                                  nullif(btrim(v_ship.address2), ''), nullif(btrim(v_ship.address3), '')), ''),
                 'city',        v_ship.city,
                 'state',       v_ship.state) end,
    'contact',       v_contact,
    'requires_ffl',  v_needs,
    'ffl',           jsonb_build_object(
                       'on_file', v_onf, 'current', v_cur,
                       'number',  case when v_has_ship then nullif(btrim(v_ship.ffl_license_number), '') end,
                       'expires', case when v_has_ship then public.parse_ffl_expiry(v_ship.ffl_expiration_raw) end),
    'lines',         v_lines,
    'total_amount',  coalesce(v_total, 0),
    'would_submit',  jsonb_build_object('ok', v_ok, 'error', v_err),
    'alerts',        v_alerts,
    'warnings',      to_jsonb(v_warn),
    'portal_path',   '/orders/' || o.id);
end;
$$;

revoke execute on function public.mcp_order_check_keys(jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.mcp_order_preview(bigint, boolean) from public, anon, authenticated;
revoke execute on function public.mcp_order_apply(bigint, jsonb, jsonb, text, text) from public, anon, authenticated;

comment on function public.mcp_create_order_draft(jsonb) is
  'MCP only (mcp_orders_gate). Creates a DRAFT from {idempotency_key, customer_key, '
  'customer_confirmed?, ship_to_key, ship_to_confirmed, po_number, requested_ship_date?, '
  'customer_contact_key?, notes?, allow_duplicate?, is_test?, source_ref?, '
  'lines:[{part_id, qty, part_confirmed, price_list_id?, expected_unit_price?}]}; '
  'confirmations enforced (20261112090000); prices on the server; dry-runs '
  'submit_order; returns the preview with alerts. Never submits.';

--------------------------------------------------------------------------
-- 8. Repair lines that stored the Buy Group sheet's UPC as the description
--------------------------------------------------------------------------
update public.order_lines l
set description = p.part_description
from (select distinct on (dp.part_id) dp.part_id, dp.part_description
        from erp.dim_part dp
       where nullif(btrim(dp.part_description), '') is not null
       order by dp.part_id, coalesce(dp.is_unknown_part, false), dp.part_key) p
where p.part_id = l.part_id
  and l.description ~ '^\s*\d{8,14}\s*$';
