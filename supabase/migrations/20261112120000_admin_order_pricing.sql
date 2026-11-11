/*============================================================================
  20261112120000_admin_order_pricing.sql
  Purpose: let an ADMIN's Claude stage a customer PO as it was sent - parts
           that are on no price list (ATS, SMUs, new SKUs), prices that are
           not the published price, even item numbers that match no part -
           as a heavily flagged DRAFT that only an admin can submit, after
           reviewing every flagged line.

  The rep path does not change: a non-admin still cannot send a price, and
  every line of theirs is priced from the published list.

  1. A reserved "Admin price (off list)" price list. Every admin-priced line
     points at it, so order_lines.price_list_id stays NOT NULL and everything
     that joins a line to its list (the ERP order loader included, whose code
     is not in this repo) keeps working. It is never active (CHECK), never
     effective for anyone, holds no items (trigger) and cannot be deleted.

  2. order_lines gains
       price_source         'list' (the published price) | 'admin'
       list_unit_price      the published price for the account when drafted
                            (null = on no list), for the reviewer
       customer_part_ref    the item number exactly as the PO had it
       customer_description the PO's description of the line
       part_unresolved      the item matched no ERP part; staged as sent
     orders gains price_override_reason (required with any admin line).

  3. A trigger on order_lines: a portal session cannot create an admin-priced
     or unmatched line, nor change one (only the RPCs below and
     admin_set_order_line_price can); an MCP session cannot write lines at all
     outside the mcp_* RPCs. It may still DELETE a line in its own draft.

  4. order_resolve_parts(customer, items): a PO's item numbers and
     descriptions -> candidate parts (exact id, same digits, this customer's
     own item number on past ERP orders, description), each with its list
     price and the last price the customer paid.

  5. Restated (bodies copied from 20261112090000 / 20261111100000, then
     changed): mcp_order_check_keys, mcp_order_apply, mcp_order_preview,
     submit_order.
       * an admin may send unit_price, customer_part_ref, customer_description
         per line and price_override_reason; admin caps are larger
         (feature.mcp_orders params admin_max_lines / admin_max_units_per_line
         / admin_max_order_value, defaults 500 / 5000 / 5,000,000);
       * a line whose price differs from the list, or whose part is on no
         list, goes on the admin list with price_source 'admin';
       * an unknown item number with a price is staged with
         part_unresolved = true;
       * the preview puts ADMIN PRICING / UNMATCHED PARTS warnings first;
       * submit_order refuses unmatched lines, and an order with admin lines
         unless the submitter is an admin AND acknowledges it.

  6. admin_set_order_line_price(line, price, reason): an admin changes a
     line's price in the portal, or resets it to the list (price null).
============================================================================*/

--------------------------------------------------------------------------
-- 1. The reserved admin price list
--------------------------------------------------------------------------
alter table public.price_lists
  add column if not exists is_admin_override boolean not null default false;

alter table public.price_lists drop constraint if exists admin_override_never_active;
alter table public.price_lists
  add constraint admin_override_never_active check (not is_admin_override or not active);

create unique index if not exists uq_price_lists_admin_override
  on public.price_lists (is_admin_override) where is_admin_override;

insert into public.price_lists (name, customer_type, is_special, effective_from, active, notes, is_admin_override)
select 'Admin price (off list)', null, true, date '2000-01-01', false,
       'Reserved. Order lines an admin priced by hand (special pricing, ATS, SMUs, parts on no list) '
       'point here. Never active, holds no items; do not edit or delete.', true
where not exists (select 1 from public.price_lists where is_admin_override);

comment on column public.price_lists.is_admin_override is
  'The one reserved list admin-priced order lines point at (20261112120000). Never active, no items.';

create or replace function public.admin_price_list_id()
returns bigint
language sql stable security definer set search_path = public
as $$
  select id from public.price_lists where is_admin_override;
$$;

revoke execute on function public.admin_price_list_id() from public, anon;
grant execute on function public.admin_price_list_id() to authenticated;

create or replace function public.price_lists_protect_admin_override()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_table_name = 'price_list_items' then
    if new.price_list_id = public.admin_price_list_id() then
      raise exception 'admin_price_list: the reserved admin price list holds no items';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' and old.is_admin_override then
    raise exception 'admin_price_list: the reserved admin price list cannot be deleted';
  end if;
  if tg_op = 'UPDATE' and (old.is_admin_override or new.is_admin_override)
     and (new.is_admin_override, new.customer_type, new.is_special, new.promo_buy_qty, new.promo_get_qty)
         is distinct from (old.is_admin_override, old.customer_type, old.is_special, old.promo_buy_qty, old.promo_get_qty) then
    raise exception 'admin_price_list: the reserved admin price list cannot be changed';
  end if;
  if tg_op = 'INSERT' and new.is_admin_override
     and exists (select 1 from public.price_lists where is_admin_override) then
    raise exception 'admin_price_list: there is already a reserved admin price list';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke execute on function public.price_lists_protect_admin_override() from public, anon, authenticated;

drop trigger if exists trg_price_lists_protect_admin_override on public.price_lists;
create trigger trg_price_lists_protect_admin_override
  before insert or update or delete on public.price_lists
  for each row execute function public.price_lists_protect_admin_override();

drop trigger if exists trg_price_list_items_protect_admin_override on public.price_list_items;
create trigger trg_price_list_items_protect_admin_override
  before insert or update on public.price_list_items
  for each row execute function public.price_lists_protect_admin_override();

--------------------------------------------------------------------------
-- 2. Columns
--------------------------------------------------------------------------
alter table public.order_lines
  add column if not exists price_source         text not null default 'list',
  add column if not exists list_unit_price      numeric(12,2),
  add column if not exists customer_part_ref    text,
  add column if not exists customer_description text,
  add column if not exists part_unresolved      boolean not null default false,
  add column if not exists last_paid_price      numeric(12,2),
  add column if not exists last_paid_date       date,
  add column if not exists description_mismatch boolean;

alter table public.order_lines drop constraint if exists order_lines_price_source_check;
alter table public.order_lines
  add constraint order_lines_price_source_check check (price_source in ('list', 'admin'));
alter table public.order_lines drop constraint if exists order_lines_unresolved_is_admin;
alter table public.order_lines
  add constraint order_lines_unresolved_is_admin check (not part_unresolved or price_source = 'admin');
alter table public.order_lines drop constraint if exists order_lines_customer_text_len;
alter table public.order_lines
  add constraint order_lines_customer_text_len
  check (length(customer_part_ref) <= 100 and length(customer_description) <= 300);

comment on column public.order_lines.price_source is
  '''list'' = the published price; ''admin'' = priced by an admin (off list or a different price). '
  'Admin lines sit on the reserved admin price list and need an admin to submit.';
comment on column public.order_lines.list_unit_price is
  'The published price for this account when the line was drafted; null = the part is on no list for it.';
comment on column public.order_lines.customer_part_ref is
  'The item number as the customer''s PO had it (e.g. CHR801-15025-01), for the reviewer.';
comment on column public.order_lines.customer_description is
  'The PO''s description of the line, for the reviewer to compare with the part.';
comment on column public.order_lines.part_unresolved is
  'The PO item matched no ERP part; part_id holds the item number as sent. Blocks submit.';
comment on column public.order_lines.last_paid_price is
  'Net price this customer last paid for the part on an ERP order, when drafted (with last_paid_date).';
comment on column public.order_lines.description_mismatch is
  'The PO''s description does not look like the part (a chambering it names is missing, or under a third of '
  'its words match). Null = no PO description to compare.';

alter table public.orders
  add column if not exists price_override_reason text;
alter table public.orders drop constraint if exists orders_price_override_reason_len;
alter table public.orders
  add constraint orders_price_override_reason_len check (length(price_override_reason) <= 500);
comment on column public.orders.price_override_reason is
  'Why lines are admin-priced (e.g. "excess stock buy-in, approved by TW"). Required with any admin line.';

--------------------------------------------------------------------------
-- 3. order_lines: who may write pricing
--------------------------------------------------------------------------
create or replace function public.order_lines_protect_pricing()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_admin_list bigint := public.admin_price_list_id();
begin
  if coalesce(current_setting('app.mcp_order_write', true), '') = 'on'
     or auth.uid() is null then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp' then
    raise exception 'mcp_direct_write: an MCP session changes order lines only through the order-drafting tools'
      using errcode = '42501';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  if tg_op = 'INSERT' then
    if new.price_source <> 'list' or new.part_unresolved
       or new.price_list_id = v_admin_list
       or new.list_unit_price is not null
       or new.customer_part_ref is not null or new.customer_description is not null
       or new.last_paid_price is not null or new.last_paid_date is not null
       or new.description_mismatch is not null then
      raise exception 'protected_line: admin prices are set with the admin price controls, not written directly'
        using errcode = '42501';
    end if;
    return new;
  end if;

  if old.price_source <> 'list' or old.part_unresolved then
    raise exception 'protected_line: an admin-priced or unmatched line changes only through the admin price controls (or remove it)'
      using errcode = '42501';
  end if;
  if new.price_list_id = v_admin_list
     or (new.price_source, new.part_unresolved, new.list_unit_price, new.customer_part_ref, new.customer_description,
         new.last_paid_price, new.last_paid_date, new.description_mismatch)
        is distinct from
        (old.price_source, old.part_unresolved, old.list_unit_price, old.customer_part_ref, old.customer_description,
         old.last_paid_price, old.last_paid_date, old.description_mismatch) then
    raise exception 'protected_line: admin prices are set with the admin price controls, not written directly'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

revoke execute on function public.order_lines_protect_pricing() from public, anon, authenticated;

drop trigger if exists trg_order_lines_protect_pricing on public.order_lines;
create trigger trg_order_lines_protect_pricing
  before insert or update or delete on public.order_lines
  for each row execute function public.order_lines_protect_pricing();

--------------------------------------------------------------------------
-- 4. order_resolve_parts: PO item numbers / descriptions -> parts
--------------------------------------------------------------------------

-- A description as distinct normalised words (order_search_normalize), less
-- words every Christensen line carries and round counts ("5RD"), with the
-- distributors' run-together chamberings folded the way the ERP reads:
-- 22CREED / 6MMCREED / 6.5CRD -> 22cm / 6cm / 6.5cm, 7MMBC / 6MMARC / 7MMPRC
-- -> 7bc / 6arc / 7prc, 7MMREM -> 7rm.
create or replace function public.order_desc_tokens(p text)
returns text[]
language sql stable set search_path = public
as $$
  select coalesce(array_agg(distinct x), '{}')
  from (
    select regexp_replace(regexp_replace(regexp_replace(regexp_replace(t,
             '^(\d+(\.\d+)?)(mm)?(creedmoor|creed|crd|cm)$', '\1cm'),
             '^(\d+)mm(prc|bc|arc)$', '\1\2'),
             '^(\d+)(mm)?(rem|rm)$', '\1rm'),
             '^300(win|winmag|wm)$', '300wm') as x
    from unnest(string_to_array(public.order_search_normalize(p), ' ')) t
    where t <> '' and not (t = any (array['christensen','chris','arms','ca','rifle','rifles','rd','rnd',
                                          'round','rounds','in','inch','the','and','with','w','each','ea']))
  ) s
  where x !~ '^\d+(rd|rds|rnd|rnds)$';
$$;

-- A part's text to compare with: description, family, chambering, length,
-- finish, stock colour.
create or replace function public.order_part_doc(p_part_id text)
returns text
language sql stable set search_path = public, erp
as $$
  select concat_ws(' ', p.part_description, nullif(upper(btrim(p.product_family)), 'N/A'),
                   nullif(upper(btrim(p.chambering)), 'N/A'), nullif(upper(btrim(p.barrel_length)), 'N/A'),
                   nullif(upper(btrim(p.finish)), 'N/A'), nullif(upper(btrim(p.stock_color)), 'N/A'))
  from erp.dim_part p where p.part_id = p_part_id order by p.part_key limit 1;
$$;

-- How well a PO description agrees with a part: the share of its words the
-- part has (a word of 4+ letters may be a prefix), and 0 when the PO names a
-- chambering ("270win", "6.5prc", "556", "3006" - a word that starts with a
-- digit and is not a bare length) the part does not have.
create or replace function public.order_desc_score(p_po text[], p_part text[])
returns numeric
language sql immutable
as $$
  select case
    when cardinality(p_po) = 0 then null
    when exists (select 1 from unnest(p_po) t
                 where (t ~ '^\d+(\.\d+)?[a-z]' or t in ('556', '3006', '308win', '223rem'))
                   and not (t = any (p_part))) then 0
    else round((select count(*) from unnest(p_po) t
                 where exists (select 1 from unnest(p_part) u
                               where u = t or (length(t) >= 4 and starts_with(u, t))))::numeric
               / cardinality(p_po), 3)
  end;
$$;

revoke execute on function public.order_desc_tokens(text) from public, anon;
revoke execute on function public.order_part_doc(text) from public, anon;
revoke execute on function public.order_desc_score(text[], text[]) from public, anon;
grant execute on function public.order_desc_tokens(text) to authenticated;
grant execute on function public.order_part_doc(text) to authenticated;
grant execute on function public.order_desc_score(text[], text[]) to authenticated;

create or replace function public.order_resolve_parts(p_customer_key text, p_items jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = public, erp
as $$
declare
  c_stop constant text[] := array['christensen','chris','arms','ca','rifle','rifles','rd','rnd',
                                  'round','rounds','in','inch','the','and','with','w','each','ea'];
  v_type  text;
  v_its   jsonb;   -- [{idx, ref, uref, digits, descr}]
  v_cand  jsonb;   -- [{idx, part_id, how, score}]
  v_more  jsonb;
  v_items jsonb;
begin
  select dc.customer_type into v_type
  from erp.dim_customer dc where dc.customer_key = p_customer_key;
  if not found then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', p_customer_key;
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'invalid_input:items: a non-empty list of {ref, description?}';
  end if;
  if jsonb_array_length(p_items) > 300 then
    raise exception 'invalid_input:items: 300 items at most per call';
  end if;

  select jsonb_agg(jsonb_build_object(
           'idx', (e.n - 1)::int,
           'ref', left(nullif(btrim(e.v ->> 'ref'), ''), 100),
           'uref', upper(nullif(btrim(e.v ->> 'ref'), '')),
           'digits', regexp_replace(coalesce(e.v ->> 'ref', ''), '\D', '', 'g'),
           'descr', left(nullif(btrim(e.v ->> 'description'), ''), 300)) order by e.n)
    into v_its
  from jsonb_array_elements(p_items) with ordinality as e(v, n)
  where jsonb_typeof(e.v) = 'object';

  -- Exact part id; the customer's own item number on their past ERP orders;
  -- the same digits ("CHR801-15025-01", "8011502501" -> 801-15025-01; six
  -- digits at least, so a stray "22" never matches). Best kind per part wins.
  with it as (
    select * from jsonb_to_recordset(coalesce(v_its, '[]'::jsonb))
      as (idx int, ref text, uref text, digits text, descr text)
  ),
  raw as (
    select it.idx, p.part_id, 'exact'::text as how, 1.0::numeric as score
    from it join erp.dim_part p on upper(p.part_id) = it.uref
    union all
    select it.idx, p.part_id, 'customer_history', 0.95
    from it
    join erp.fact_order_line f
      on f.customer_key = p_customer_key and upper(btrim(f.customer_part_id)) = it.uref
    join erp.dim_part p on p.part_key = f.part_key
    union all
    select it.idx, p.part_id, 'digits', 0.9
    from it
    join (select distinct dp.part_id, regexp_replace(dp.part_id, '\D', '', 'g') as d from erp.dim_part dp) p
      on p.d = it.digits
    where length(it.digits) >= 6
  ),
  best as (
    select distinct on (idx, part_id) idx, part_id, how, score
    from raw order by idx, part_id, score desc
  )
  select coalesce(jsonb_agg(to_jsonb(best)), '[]'::jsonb) into v_cand from best;

  -- Description, only for items nothing above matched: the share of the PO
  -- description's words (normalised like order_product_search) found in an
  -- active firearm's description / family / chambering. Top 3, >= 0.5.
  if exists (select 1 from jsonb_array_elements(coalesce(v_its, '[]'::jsonb)) i
             where i ->> 'descr' is not null
               and not exists (select 1 from jsonb_array_elements(v_cand) c
                               where (c ->> 'idx')::int = (i ->> 'idx')::int)) then
    with q as (
      select (i ->> 'idx')::int as idx, public.order_desc_tokens(i ->> 'descr') as toks
      from jsonb_array_elements(v_its) i
      where i ->> 'descr' is not null
        and not exists (select 1 from jsonb_array_elements(v_cand) c
                        where (c ->> 'idx')::int = (i ->> 'idx')::int)
    ),
    docs as materialized (
      select x.part_id,
             public.order_desc_tokens(concat_ws(' ',
               x.part_description, nullif(upper(btrim(x.product_family)), 'N/A'),
               nullif(upper(btrim(x.chambering)), 'N/A'), nullif(upper(btrim(x.barrel_length)), 'N/A'),
               nullif(upper(btrim(x.finish)), 'N/A'), nullif(upper(btrim(x.stock_color)), 'N/A'))) as toks
      from (select distinct on (dp.part_id) dp.*
              from erp.dim_part dp
             where dp.status = 'A' and dp.part_id ~ '^8\d\d-' and dp.part_id !~ '-M$'
             order by dp.part_id, dp.part_key) x
    ),
    scored as (
      select q.idx, d.part_id, public.order_desc_score(q.toks, d.toks) as score
      from q cross join docs d
      where cardinality(q.toks) > 0
    ),
    ranked as (
      select s.*, row_number() over (partition by s.idx order by s.score desc, s.part_id) as rn
      from scored s where s.score >= 0.5
    )
    select coalesce(jsonb_agg(jsonb_build_object('idx', idx, 'part_id', part_id,
                                                 'how', 'description', 'score', score)), '[]'::jsonb)
      into v_more
    from ranked where rn <= 3;
    v_cand := v_cand || v_more;
  end if;

  with it as (
    select * from jsonb_to_recordset(coalesce(v_its, '[]'::jsonb))
      as (idx int, ref text, uref text, digits text, descr text)
  ),
  c0 as (
    select * from jsonb_to_recordset(v_cand) as (idx int, part_id text, how text, score numeric)
  ),
  cand as (
    select c.idx, c.part_id, c.how, c.score,
           dp.part_description, dp.status, coalesce(dp.is_kit_flag = 'Y', false) as is_kit,
           lp.unit_price as list_price,
           hist.net_price as last_paid_price, hist.order_date as last_paid_date,
           case when c.how = 'description' then c.score
                else public.order_desc_score(public.order_desc_tokens(it.descr),
                                             public.order_desc_tokens(public.order_part_doc(c.part_id))) end
             as agreement,
           row_number() over (partition by c.idx
                              order by c.score desc, (dp.status = 'A') desc, (c.part_id ~ '-M$'), c.part_id) as rn
    from c0 c
    join it on it.idx = c.idx
    left join lateral (
      select p.part_description, p.status, p.is_kit_flag
      from erp.dim_part p where p.part_id = c.part_id order by p.part_key limit 1) dp on true
    left join lateral (
      select i.unit_price
      from public.effective_price_lists(v_type) l
      join public.price_list_items i on i.price_list_id = l.id and i.part_id = c.part_id
      where not l.is_special
      order by l.effective_from desc, l.id limit 1) lp on true
    left join lateral (
      select round(f.unit_price * (1 - coalesce(f.trade_discount_pct, 0) / 100), 2) as net_price, f.order_date
      from erp.fact_order_line f
      join erp.dim_part p on p.part_key = f.part_key
      where f.customer_key = p_customer_key and p.part_id = c.part_id and f.unit_price is not null
      order by f.order_date desc nulls last, f.order_id desc limit 1) hist on true
  ),
  per_item as (
    select it.idx, it.ref, it.descr,
           coalesce(jsonb_agg(jsonb_build_object(
             'part_id',         c.part_id,
             'erp_description', c.part_description,
             'part_status',     c.status,
             'match',           c.how,
             'score',           c.score,
             'description_agreement', c.agreement,
             'is_kit',          c.is_kit,
             'requires_ffl',    public.part_requires_ffl(c.part_id),
             'on_price_list',   c.list_price is not null,
             'list_price',      c.list_price,
             'last_paid_price', c.last_paid_price,
             'last_paid_date',  c.last_paid_date)
             order by c.rn) filter (where c.part_id is not null and c.rn <= 5), '[]'::jsonb) as cands,
           count(*) filter (where c.how <> 'description' and c.status = 'A' and c.part_id !~ '-M$') as strong_active,
           count(*) filter (where c.how <> 'description') as strong,
           count(c.part_id) as any_cand,
           bool_or(c.rn = 1 and c.how <> 'description' and c.agreement < 0.3) as top_disagrees
    from it
    left join cand c on c.idx = it.idx
    group by it.idx, it.ref, it.descr
  )
  select jsonb_agg(jsonb_build_object(
           'index', p.idx,
           'ref', p.ref,
           'description', p.descr,
           'status', case
              when (p.strong_active = 1 or p.strong = 1) and coalesce(p.top_disagrees, false) then 'check_description'
              when p.strong_active = 1 or p.strong = 1 then 'matched'
              when p.strong > 1 then 'ambiguous'
              when p.any_cand > 0 then 'description_only'
              else 'unmatched' end,
           'candidates', p.cands)
           order by p.idx)
    into v_items
  from per_item p;

  return jsonb_build_object(
    'customer_type', v_type,
    'items', coalesce(v_items, '[]'::jsonb),
    'note', 'matched = one strong match (exact id, this customer''s own item number, or the same digits) '
            'whose ERP description agrees with the PO''s. check_description = the number matched but '
            'the descriptions disagree (a chambering missing, or under a third of the words): likely a typo '
            'on the PO; show the user both. description_only and ambiguous need a person''s choice; '
            'unmatched items can be staged only by an admin, with a price.');
end;
$$;

revoke execute on function public.order_resolve_parts(text, jsonb) from public, anon;
grant execute on function public.order_resolve_parts(text, jsonb) to authenticated;

comment on function public.order_resolve_parts(text, jsonb) is
  'Resolve a PO''s lines [{ref, description}] to ERP parts across the whole catalog: exact id, '
  'the customer''s own item number on past ERP orders, same digits, then description. Each '
  'candidate carries its list price for the account and the last price the customer paid. '
  'RLS-scoped (SECURITY INVOKER).';

--------------------------------------------------------------------------
-- 5a. mcp_order_check_keys: admin pricing keys exist (apply decides who).
--     Body from 20261112090000 §5.
--------------------------------------------------------------------------
create or replace function public.mcp_order_check_keys(p jsonb, p_update boolean)
returns void
language plpgsql immutable set search_path = public
as $$
declare
  c_top  constant text[] := array['idempotency_key','customer_key','customer_confirmed','ship_to_key',
                                  'ship_to_confirmed','po_number','requested_ship_date',
                                  'customer_contact_key','notes','allow_duplicate','source_ref',
                                  'is_test','lines','price_override_reason'];
  c_line constant text[] := array['part_id','qty','price_list_id','part_confirmed','expected_unit_price',
                                  'unit_price','customer_part_ref','customer_description'];
  c_price constant text[] := array['price','prices','discount_pct','effective_unit_price',
                                   'line_total','total_amount','total'];
  c_ffl  constant text[] := array['ffl_license_number','ffl_expires_on','ffl','ffl_number'];
  k text;
  l jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_input:body: the request must be a JSON object';
  end if;
  for k in select jsonb_object_keys(p) loop
    if k = any (c_price) or k = 'unit_price' then
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
          raise exception 'invalid_input:unknown_field:%: not a line field (part_id, qty, part_confirmed, price_list_id, expected_unit_price, unit_price, customer_part_ref, customer_description)', k;
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
-- 5b. mcp_order_apply: the admin path. Body from 20261112090000 §6.
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
  v_admin    boolean := public.is_admin();
  v_admin_list bigint := public.admin_price_list_id();
  v_max_lines int;
  v_max_units int;
  v_max_value numeric;
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
  v_reason   text;
  v_price    numeric;
  v_cref     text;
  v_cdesc    text;
  v_known    boolean;
  v_has_item boolean;
  v_n_admin  int := 0;
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
  -- An admin stages distributor POs (20261112120000): larger caps.
  if v_admin then
    v_max_lines := coalesce((p_params ->> 'admin_max_lines')::int, 500);
    v_max_units := coalesce((p_params ->> 'admin_max_units_per_line')::int, 5000);
    v_max_value := coalesce((p_params ->> 'admin_max_order_value')::numeric, 5000000);
  else
    v_max_lines := coalesce((p_params ->> 'max_lines')::int, 40);
    v_max_units := coalesce((p_params ->> 'max_units_per_line')::int, 200);
    v_max_value := coalesce((p_params ->> 'max_order_value')::numeric, 250000);
  end if;

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
     or not (v_admin or v_ck in (select public.my_customer_keys())) then
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

  if p ? 'price_override_reason' and jsonb_typeof(p -> 'price_override_reason') <> 'null' then
    if not v_admin then
      raise exception 'price_not_allowed:price_override_reason: only an admin can price an order by hand; the server prices it from the published list';
    end if;
    if jsonb_typeof(p -> 'price_override_reason') <> 'string' then
      raise exception 'invalid_input:price_override_reason: must be text';
    end if;
    v_reason := nullif(btrim(p ->> 'price_override_reason'), '');
    if length(v_reason) > 500 then
      raise exception 'invalid_input:price_override_reason: 500 characters at most';
    end if;
  end if;

  if p ? 'allow_duplicate' and jsonb_typeof(p -> 'allow_duplicate') <> 'null' then
    if jsonb_typeof(p -> 'allow_duplicate') <> 'boolean' then
      raise exception 'invalid_input:allow_duplicate: must be true or false';
    end if;
    v_allow := (p -> 'allow_duplicate')::boolean;
  end if;

  -- Once a test, always a test: an update can mark a draft as a test but
  -- never clear it (omitted or false keeps it), so a real order needs a new
  -- draft, as the test_order refusal says.
  v_test := coalesce(v_cur.is_test, false)
            or coalesce((p -> 'is_test') = 'true'::jsonb, false);

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
    if length(v_part) > 100 then
      raise exception 'invalid_input:part_id: 100 characters at most';
    end if;
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

    -- Admin pricing (20261112120000): the PO's price, and the PO's own item
    -- number and description for the reviewer.
    v_price := null;
    if v_line ? 'unit_price' and jsonb_typeof(v_line -> 'unit_price') <> 'null' then
      if not v_admin then
        raise exception 'price_not_allowed:%: only an admin can set a price; the server prices the order from the published list (send the user''s price as expected_unit_price)', v_part;
      end if;
      if jsonb_typeof(v_line -> 'unit_price') <> 'number' then
        raise exception 'invalid_input:unit_price: line % needs a number', v_part;
      end if;
      v_price := (v_line ->> 'unit_price')::numeric;
      if v_price < 0 or v_price > 1000000 or v_price <> round(v_price, 2) then
        raise exception 'invalid_input:unit_price: line % has %; use 0-1,000,000 with at most 2 decimals', v_part, v_price;
      end if;
    end if;
    v_cref := null;
    if v_line ? 'customer_part_ref' and jsonb_typeof(v_line -> 'customer_part_ref') <> 'null' then
      if jsonb_typeof(v_line -> 'customer_part_ref') not in ('string', 'number') then
        raise exception 'invalid_input:customer_part_ref: line % must be text', v_part;
      end if;
      v_cref := nullif(btrim(v_line ->> 'customer_part_ref'), '');
      if length(v_cref) > 100 then
        raise exception 'invalid_input:customer_part_ref: 100 characters at most';
      end if;
    end if;
    v_cdesc := null;
    if v_line ? 'customer_description' and jsonb_typeof(v_line -> 'customer_description') <> 'null' then
      if jsonb_typeof(v_line -> 'customer_description') <> 'string' then
        raise exception 'invalid_input:customer_description: line % must be text', v_part;
      end if;
      v_cdesc := left(nullif(btrim(v_line ->> 'customer_description'), ''), 300);
    end if;

    v_known := exists (select 1 from erp.dim_part dp where dp.part_id = v_part);

    if exists (select 1 from erp.dim_part dp where dp.part_id = v_part and dp.is_kit_flag = 'Y') then
      raise exception 'kit_not_supported:%: kits cannot be ordered here', v_part;
    end if;

    v_has_item := false;
    if v_known then
      select l.id as list_id, l.name as list_name, i.id as item_id, i.unit_price, i.description
        into v_item
      from public.effective_price_lists(v_cust.customer_type) l
      join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_part
      where (v_plid is null and not l.is_special) or l.id = v_plid
      order by l.effective_from desc, l.id
      limit 1;
      v_has_item := found;
    end if;

    if (v_line -> 'part_confirmed') is distinct from 'true'::jsonb then
      v_unconf := v_unconf || jsonb_build_object(
        'line', v_ix, 'part_id', v_part,
        'choices', public.order_part_choices(v_cust.customer_type, v_part, 6));
    end if;

    if v_has_item and (v_price is null or v_price = v_item.unit_price) then
      -- The published price. The ERP part master's description first (the
      -- uploaded list's column is only a fallback: the Buy Group sheet
      -- carried the UPC there).
      v_priced := v_priced || jsonb_build_object(
        'part_id', v_part, 'qty', v_qty::int, 'price_list_id', v_item.list_id,
        'item_id', v_item.item_id, 'unit_price', v_item.unit_price,
        'expected_unit_price', v_exp,
        'description', coalesce(
           (select dp.part_description from erp.dim_part dp
             where dp.part_id = v_part and nullif(btrim(dp.part_description), '') is not null
             order by coalesce(dp.is_unknown_part, false), dp.part_key limit 1),
           v_item.description, v_cdesc),
        'price_source', 'list', 'list_unit_price', v_item.unit_price,
        'customer_part_ref', v_cref, 'customer_description', v_cdesc, 'part_unresolved', false);
    elsif v_price is null then
      if not v_known and v_admin then
        raise exception 'part_unknown:%: no ERP part has this id. Resolve it with resolve_order_parts, or send unit_price to stage it unmatched', v_part;
      end if;
      if v_plid is null then
        raise exception 'part_not_orderable:%: not on this account''s price list%', v_part,
          case when v_admin then '; as an admin, send unit_price to order it off list' else '' end;
      end if;
      raise exception 'part_not_orderable:%: not on price list % (or that list is not effective for this account)', v_part, v_plid;
    else
      -- Admin price: off list, a different price, or an unmatched item.
      if v_admin_list is null then
        raise exception 'admin_price_list: the reserved admin price list is missing';
      end if;
      v_n_admin := v_n_admin + 1;
      v_priced := v_priced || jsonb_build_object(
        'part_id', v_part, 'qty', v_qty::int, 'price_list_id', v_admin_list,
        'item_id', null, 'unit_price', v_price,
        'expected_unit_price', v_exp,
        'description', coalesce(
           (select dp.part_description from erp.dim_part dp
             where dp.part_id = v_part and nullif(btrim(dp.part_description), '') is not null
             order by coalesce(dp.is_unknown_part, false), dp.part_key limit 1),
           case when v_has_item then v_item.description end, v_cdesc),
        'price_source', 'admin',
        'list_unit_price', case when v_has_item then v_item.unit_price
                                else (select i.unit_price
                                        from public.effective_price_lists(v_cust.customer_type) l
                                        join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_part
                                       where not l.is_special
                                       order by l.effective_from desc, l.id limit 1) end,
        'customer_part_ref', coalesce(v_cref, case when not v_known then v_part end),
        'customer_description', v_cdesc, 'part_unresolved', not v_known);
    end if;

    if (select count(*) from jsonb_array_elements(v_priced) e
         where e ->> 'part_id' = v_part
           and (e ->> 'price_list_id')::bigint = (v_priced -> -1 ->> 'price_list_id')::bigint) > 1 then
      raise exception 'invalid_input:duplicate_line:%: the part appears twice at the same price list; send one line with the total qty', v_part;
    end if;
  end loop;

  if jsonb_array_length(v_unconf) > 0 then
    raise exception using
      message = format('part_confirmation_required:%s: %s line(s) were not confirmed by the user; show the choices, then send part_confirmed=true on every line',
                       v_unconf -> 0 ->> 'part_id', jsonb_array_length(v_unconf)),
      detail  = jsonb_build_object('error', 'part_confirmation_required', 'lines', v_unconf)::text;
  end if;

  if v_n_admin > 0 and v_reason is null then
    raise exception 'invalid_input:price_override_reason: % line(s) are admin-priced or unmatched; say why in price_override_reason (e.g. "excess stock buy-in, approved by ...")', v_n_admin;
  end if;
  if v_n_admin = 0 then
    v_reason := null;
  end if;

  -- The same promo formula as submit_order (which re-runs it authoritatively).
  -- The admin list has no promo, so admin lines keep their price.
  with x as (
    select * from jsonb_to_recordset(v_priced)
      as (part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
          expected_unit_price numeric, description text,
          price_source text, list_unit_price numeric, customer_part_ref text, customer_description text,
          part_unresolved boolean)
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
        source_ref, mcp_token_id, client_request_id, request_hash, is_test, price_override_reason)
      values (
        v_uid, v_uid, v_ck, coalesce(v_cust.customer_name, ''), v_cust.customer_type, 'draft', 'mcp',
        v_po, v_date, v_notes, v_ship_key, v_contact,
        v_ref, v_tok, p_idem_key, p_hash, v_test, v_reason)
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
        is_test              = v_test,
        price_override_reason = v_reason
    where id = v_id;
    delete from public.order_lines where order_id = v_id;
  end if;

  insert into public.order_lines (order_id, price_list_id, price_list_item_id, part_id, description,
                                  qty, unit_price, discount_pct, effective_unit_price,
                                  mcp_expected_unit_price,
                                  price_source, list_unit_price, customer_part_ref, customer_description,
                                  part_unresolved)
  select v_id, x.price_list_id, x.item_id, x.part_id, x.description,
         x.qty, x.unit_price, x.discount_pct, x.effective_unit_price, x.expected_unit_price,
         x.price_source, x.list_unit_price, x.customer_part_ref, x.customer_description,
         coalesce(x.part_unresolved, false)
  from jsonb_to_recordset(v_priced)
    as x(part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
         description text, discount_pct numeric, effective_unit_price numeric,
         expected_unit_price numeric,
         price_source text, list_unit_price numeric, customer_part_ref text, customer_description text,
         part_unresolved boolean);

  -- For the reviewer: what this customer last paid for each part, and
  -- whether the PO's description looks like the part it was matched to.
  update public.order_lines l
  set last_paid_price = h.net_price,
      last_paid_date  = h.order_date
  from (
    select distinct on (p.part_id) p.part_id,
           round(f.unit_price * (1 - coalesce(f.trade_discount_pct, 0) / 100), 2) as net_price, f.order_date
    from erp.fact_order_line f
    join erp.dim_part p on p.part_key = f.part_key
    where f.customer_key = v_ck and f.unit_price is not null
      and p.part_id in (select ol.part_id from public.order_lines ol where ol.order_id = v_id)
    order by p.part_id, f.order_date desc nulls last, f.order_id desc
  ) h
  where l.order_id = v_id and l.part_id = h.part_id;

  update public.order_lines l
  set description_mismatch = coalesce(public.order_desc_score(
        public.order_desc_tokens(l.customer_description),
        public.order_desc_tokens(public.order_part_doc(l.part_id))), 1) < 0.3
  where l.order_id = v_id and l.customer_description is not null and not l.part_unresolved;

  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);
  return v_id;
end;
$$;

--------------------------------------------------------------------------
-- 5c. mcp_order_preview: admin / unmatched / description warnings and
--     alerts first. Body from 20261112090000 §7.
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
  v_head  text[] := '{}';
  v_adm   record;
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
               'expected_unit_price', l.mcp_expected_unit_price,
               'price_source', l.price_source, 'list_unit_price', l.list_unit_price,
               'customer_part_ref', l.customer_part_ref, 'customer_description', l.customer_description,
               'part_unresolved', l.part_unresolved,
               'last_paid_price', l.last_paid_price, 'last_paid_date', l.last_paid_date,
               'description_mismatch', l.description_mismatch)
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
             'expected_unit_price', l.mcp_expected_unit_price,
               'price_source', l.price_source, 'list_unit_price', l.list_unit_price,
               'customer_part_ref', l.customer_part_ref, 'customer_description', l.customer_description,
               'part_unresolved', l.part_unresolved,
               'last_paid_price', l.last_paid_price, 'last_paid_date', l.last_paid_date,
               'description_mismatch', l.description_mismatch)
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

  -- Admin pricing and unmatched parts (20261112120000): these lead the
  -- warnings, in capitals, and carry alerts of their own.
  select count(*) as n,
         count(*) filter (where l.price_source = 'admin') as n_admin,
         count(*) filter (where l.price_source = 'admin' and l.list_unit_price is null and not l.part_unresolved) as n_off,
         count(*) filter (where l.price_source = 'admin' and l.list_unit_price is not null) as n_diff,
         count(*) filter (where l.part_unresolved) as n_unres,
         coalesce(sum(l.qty * l.unit_price) filter (where l.price_source = 'admin'), 0) as admin_value,
         coalesce(sum(l.qty * (l.list_unit_price - l.unit_price))
                    filter (where l.price_source = 'admin' and l.list_unit_price is not null), 0) as under_list,
         string_agg(coalesce(l.customer_part_ref, l.part_id), ', ' order by l.id)
           filter (where l.part_unresolved) as unres_refs,
         count(*) filter (where l.description_mismatch) as n_desc,
         string_agg(format('%s matched to %s', coalesce(l.customer_part_ref, l.part_id), l.part_id), '; ' order by l.id)
           filter (where l.description_mismatch) as desc_refs,
         count(*) filter (where l.price_source = 'admin' and l.last_paid_price is not null
                            and l.last_paid_price <> l.unit_price) as n_vs_paid
    into v_adm
  from public.order_lines l where l.order_id = p_order_id;
  if v_adm.n_unres > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'unmatched_parts', 'severity', 'hard',
      'count', v_adm.n_unres, 'refs', v_adm.unres_refs,
      'message', 'Lines that match no ERP part: the order cannot be submitted until each is corrected or removed.');
    v_head := v_head || format(
      'UNMATCHED PARTS: %s line(s) match no part in the ERP (%s). They are staged as sent; the order '
      'cannot be submitted until each is corrected (update_order_draft with the right part_id) or removed.',
      v_adm.n_unres, left(v_adm.unres_refs, 400));
  end if;
  if v_adm.n_desc > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'description_check', 'severity', 'warning',
      'count', v_adm.n_desc, 'lines', v_adm.desc_refs);
    v_head := v_head || format(
      'DESCRIPTION CHECK: on %s line(s) the PO''s description does not look like the part it was matched to '
      '(%s). Likely a typo in the PO''s item number: confirm each with the user.',
      v_adm.n_desc, left(v_adm.desc_refs, 600));
  end if;
  if v_adm.n_admin > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'admin_pricing', 'severity', 'warning',
      'lines', v_adm.n_admin, 'off_list', v_adm.n_off, 'differs_from_list', v_adm.n_diff,
      'unmatched', v_adm.n_unres, 'admin_value', v_adm.admin_value, 'below_list', v_adm.under_list,
      'reason', o.price_override_reason,
      'message', 'Admin-priced lines: only an admin can submit, after reviewing each flagged line.');
    v_head := v_head || format(
      'ADMIN PRICING - CHECK EVERY FLAGGED LINE: %s of %s lines are not at the published price '
      '(%s on no price list for this account, %s priced differently from the list, %s unmatched). '
      'Admin-priced value %s; %s below list on the lines that have a list price. Reason: "%s". '
      'Only an admin can submit this order, after reviewing each flagged line.',
      v_adm.n_admin, v_adm.n, v_adm.n_off, v_adm.n_diff, v_adm.n_unres,
      '$' || to_char(v_adm.admin_value, 'FM999,999,990.00'), '$' || to_char(v_adm.under_list, 'FM999,999,990.00'),
      coalesce(o.price_override_reason, 'none given'));
    if v_adm.n_vs_paid > 0 then
      v_head := v_head || format(
        'PRICE VS LAST PAID: %s admin-priced line(s) differ from what this customer last paid for the part (see last_paid_price per line).',
        v_adm.n_vs_paid);
    end if;
  end if;

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
           coalesce((e.line ->> 'part_unresolved')::boolean, false) as unres,
           (select min(dp.status) from erp.dim_part dp where dp.part_id = e.line ->> 'part_id') as status
    from jsonb_array_elements(v_lines) as e(line)
  loop
    continue when r.unres;
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
    'admin_pricing', case when v_adm.n_admin > 0 then jsonb_build_object(
                       'lines', v_adm.n_admin, 'off_list', v_adm.n_off, 'differs_from_list', v_adm.n_diff,
                       'unmatched', v_adm.n_unres, 'admin_value', v_adm.admin_value,
                       'below_list', v_adm.under_list, 'reason', o.price_override_reason) end,
    'would_submit',  jsonb_build_object('ok', v_ok, 'error', v_err),
    'alerts',        v_alerts,
    'warnings',      to_jsonb(v_head || v_warn),
    'portal_path',   '/orders/' || o.id);
end;
$$;

revoke execute on function public.mcp_order_check_keys(jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.mcp_order_preview(bigint, boolean) from public, anon, authenticated;
revoke execute on function public.mcp_order_apply(bigint, jsonb, jsonb, text, text) from public, anon, authenticated;

--------------------------------------------------------------------------
-- 5d. submit_order: admin lines need an admin and the acknowledgement;
--     unmatched lines never submit. (Body from 20261111100000 §4.)
--------------------------------------------------------------------------
create or replace function public.submit_order(p_order_id bigint, p_acknowledged boolean default false)
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
  v_ack   boolean := coalesce(p_acknowledged, false);
  v_guc   text := current_setting('app.mcp_order_write', true);
  v_n_admin int;
begin
  -- A JWT outlives deactivation; the profile is the cutoff, not the token.
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;
  -- Claude never submits. An MCP session reaches this only through the
  -- draft preview's dry run (mcp_order_preview sets app.mcp_dry_run and
  -- always rolls the subtransaction back).
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp'
     and coalesce(current_setting('app.mcp_dry_run', true), '') <> 'on' then
    raise exception 'mcp_cannot_submit: Claude drafts orders; a person submits them in the portal'
      using errcode = '42501';
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
  -- Claude (or any non-portal source) drafted it: a person must confirm it.
  if v_order.source <> 'portal' and not v_ack then
    raise exception 'acknowledge_required: order % was drafted by %; confirm you have reviewed it before submitting',
      p_order_id, case v_order.source when 'mcp' then 'Claude' else v_order.source end;
  end if;
  if not exists (select 1 from public.order_lines where order_id = p_order_id) then
    raise exception 'order % has no lines', p_order_id;
  end if;

  -- Unmatched items never leave draft.
  select string_agg(coalesce(l.customer_part_ref, l.part_id), ', ' order by l.id) into v_bad
  from public.order_lines l
  where l.order_id = p_order_id
    and (l.part_unresolved or not exists (select 1 from erp.dim_part dp where dp.part_id = l.part_id));
  if v_bad is not null then
    raise exception 'unmatched_parts: order % has lines that match no ERP part (%). Correct or remove them before submitting.',
      p_order_id, left(v_bad, 400);
  end if;

  -- Admin prices: an admin submits, and only having acknowledged them.
  select count(*) into v_n_admin
  from public.order_lines l where l.order_id = p_order_id and l.price_source = 'admin';
  if v_n_admin > 0 then
    if not public.is_admin() then
      raise exception 'admin_price_requires_admin: order % has % line(s) at admin prices; only an admin can submit it',
        p_order_id, v_n_admin;
    end if;
    if not v_ack then
      raise exception 'acknowledge_required: order % has % line(s) at admin prices; confirm you have reviewed every flagged line before submitting',
        p_order_id, v_n_admin;
    end if;
    if exists (select 1 from public.order_lines l
               where l.order_id = p_order_id and l.price_source = 'admin'
                 and l.price_list_id is distinct from public.admin_price_list_id()) then
      raise exception 'order % has an admin-priced line that is not on the admin price list', p_order_id;
    end if;
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

  -- Every LIST-priced line must sit on a list effective today for this
  -- customer type, and its captured price must still be the published price.
  -- Admin lines were checked above.
  select string_agg(distinct l.part_id, ', ') into v_bad
  from public.order_lines l
  where l.order_id = p_order_id
    and l.price_source = 'list'
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

  -- From here the server writes lines and protected columns: open the write
  -- window (order_lines_protect_pricing, orders_protect_provenance), then put
  -- the GUC back as it was.
  perform set_config('app.mcp_order_write', 'on', true);

  -- Authoritative promo pass (overwrites whatever the client previewed).
  -- The admin list has no promo: its lines keep their price.
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
      submitted_at  = now(),
      acknowledged_at = case when v_ack then now() else o.acknowledged_at end,
      acknowledged_by = case when v_ack then v_uid else o.acknowledged_by end
  where o.id = p_order_id
  returning * into v_order;
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);

  return v_order;
end;
$$;

revoke execute on function public.submit_order(bigint, boolean) from public, anon;
grant execute on function public.submit_order(bigint, boolean) to authenticated, service_role;

comment on function public.submit_order(bigint, boolean) is
  'draft -> submitted, with the authoritative pricing/ship-to/FFL pass. An '
  'order with source <> ''portal'' needs p_acknowledged => true '
  '(acknowledge_required otherwise); an acknowledgement stamps acknowledged_at/by. '
  'Lines matching no ERP part never submit; admin-priced lines need an admin '
  'submitter and the acknowledgement (20261112120000).';

--------------------------------------------------------------------------
-- 6. admin_set_order_line_price: the portal's edit / reset
--------------------------------------------------------------------------
create or replace function public.admin_set_order_line_price(
  p_line_id    bigint,
  p_unit_price numeric,
  p_reason     text default null
)
returns jsonb
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_guc   text := current_setting('app.mcp_order_write', true);
  v_line  public.order_lines;
  v_order public.orders;
  v_type  text;
  v_item  record;
  v_has   boolean;
  v_reason text := nullif(btrim(p_reason), '');
  v_admin_list bigint := public.admin_price_list_id();
begin
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp' then
    raise exception 'mcp_direct_write: prices are set in the portal by an admin' using errcode = '42501';
  end if;
  if not public.is_admin() then
    raise exception 'not_admin: only an admin can set a line''s price' using errcode = '42501';
  end if;

  select * into v_line from public.order_lines where id = p_line_id;
  if not found then
    raise exception 'line_not_found: order line % not found', p_line_id;
  end if;
  select * into v_order from public.orders where id = v_line.order_id for update;
  if v_order.status <> 'draft' then
    raise exception 'order_not_draft: order % is %; recall it to draft first', v_order.id, v_order.status;
  end if;
  if v_order.source = 'portal' then
    raise exception 'order_portal: hand-typed orders are priced from the price list';
  end if;
  if v_line.part_unresolved then
    raise exception 'unmatched_part: line % matches no ERP part; ask Claude to correct it, or remove the line', v_line.part_id;
  end if;
  if length(v_reason) > 500 then
    raise exception 'invalid_input:reason: 500 characters at most';
  end if;

  select dc.customer_type into v_type from erp.dim_customer dc where dc.customer_key = v_order.customer_key;
  select l.id as list_id, i.id as item_id, i.unit_price, i.description into v_item
  from public.effective_price_lists(v_type) l
  join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_line.part_id
  where not l.is_special
  order by l.effective_from desc, l.id
  limit 1;
  v_has := found;

  if p_unit_price is not null
     and (p_unit_price < 0 or p_unit_price > 1000000 or p_unit_price <> round(p_unit_price, 2)) then
    raise exception 'invalid_input:unit_price: use 0-1,000,000 with at most 2 decimals';
  end if;
  if p_unit_price is null and not v_has then
    raise exception 'no_list_price: % is on no price list for this account; set a price instead', v_line.part_id;
  end if;

  perform set_config('app.mcp_order_write', 'on', true);
  begin
    if p_unit_price is null or (v_has and p_unit_price = v_item.unit_price) then
      update public.order_lines
      set price_list_id = v_item.list_id, price_list_item_id = v_item.item_id,
          unit_price = v_item.unit_price, discount_pct = 0, effective_unit_price = v_item.unit_price,
          price_source = 'list', list_unit_price = v_item.unit_price
      where id = p_line_id;
    else
      if v_reason is null and v_order.price_override_reason is null then
        raise exception 'reason_required: say why this order is priced by hand';
      end if;
      update public.order_lines
      set price_list_id = v_admin_list, price_list_item_id = null,
          unit_price = p_unit_price, discount_pct = 0, effective_unit_price = p_unit_price,
          price_source = 'admin', list_unit_price = case when v_has then v_item.unit_price end
      where id = p_line_id;
    end if;
  exception when unique_violation then
    raise exception 'duplicate_line: % is already on this order at that price list; remove one of the lines first', v_line.part_id;
  end;
  if v_reason is not null then
    update public.orders set price_override_reason = v_reason where id = v_order.id;
  end if;
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);

  select * into v_line from public.order_lines where id = p_line_id;
  return to_jsonb(v_line);
end;
$$;

revoke execute on function public.admin_set_order_line_price(bigint, numeric, text) from public, anon;
grant execute on function public.admin_set_order_line_price(bigint, numeric, text) to authenticated;

comment on function public.admin_set_order_line_price(bigint, numeric, text) is
  'Admin only, drafts from Claude only: set a line''s unit price (it moves to the admin price list '
  'unless it equals the published price) or, with p_unit_price null, reset it to the published '
  'price. p_reason sets orders.price_override_reason (required if none is on the order yet).';
