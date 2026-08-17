/*============================================================================
  20260817000200_orders.sql
  Purpose: The order writer's app-owned order store, its transition RPCs,
           and the ERP QC comparison.

  The hard rule (README / PRD §4) stands: NOTHING here writes to the ERP.
  A portal order terminates in these tables; the order_entry user keys it
  into the ERP by hand and records the ERP order number; the nightly ETL
  later lands the ERP's copy in erp.fact_order_line and run_order_qc()
  compares the two — read-only — and flags discrepancies.

  Status lifecycle
  ----------------
    draft ──submit──▶ submitted ──mark entered──▶ entered ──QC──▶ verified
      ▲                  │  ▲                        │              ▲
      └────recall────────┘  └─────reopen (typo)──────┘              │
    draft/submitted ──cancel──▶ cancelled        entered ──QC──▶ discrepancy
                                                     (admin resolve ─▶ verified)

  Who writes what — the column-level problem, solved structurally:
  Postgres RLS cannot grant "may update erp_order_number but not lines", so
  DIRECT table writes exist only for the one state where free editing is
  correct: a rep's own DRAFT (policies pin USING and WITH CHECK to
  status='draft', so a rep physically cannot flip status via PostgREST).
  Every other transition is a SECURITY DEFINER RPC that checks role and
  current status itself. order_entry has zero direct write policies.

  Reading: my_order_ids() mirrors the my_customer_keys() hashed-subplan
  pattern (010) — own orders, plus orders on the caller's book (a principal
  sees their agency's orders), plus everything post-draft for order_entry.
============================================================================*/

--------------------------------------------------------------------------
-- orders — one row per portal order
--------------------------------------------------------------------------
create table if not exists public.orders (
    id                  bigint generated always as identity primary key,
    user_id             uuid not null references public.profiles (user_id),
    customer_key        text not null,          -- erp.dim_customer.customer_key
    -- Snapshots stamped by submit_order(): order_entry has no ERP read
    -- access (empty book), so the queue must not depend on erp.dim_customer.
    customer_name       text not null default '',
    customer_type       text,
    status              text not null default 'draft'
                        check (status in ('draft','submitted','entered',
                                          'verified','discrepancy','cancelled')),
    po_number           text,
    requested_ship_date date,
    notes               text,
    total_amount        numeric(14,2),
    submitted_at        timestamptz,
    entered_at          timestamptz,
    entered_by          uuid references public.profiles (user_id),
    erp_order_number    text,
    qc_checked_at       timestamptz,
    verified_at         timestamptz,
    resolution_note     text,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);
alter table public.orders enable row level security;

-- One portal order per ERP order — a duplicate ERP number is either a typo
-- or the same order entered twice; both must fail loudly at entry time.
create unique index if not exists uq_orders_erp_number
  on public.orders (erp_order_number) where erp_order_number is not null;
create index if not exists idx_orders_user     on public.orders (user_id);
create index if not exists idx_orders_customer on public.orders (customer_key);
create index if not exists idx_orders_status   on public.orders (status);

drop trigger if exists trg_orders_touch on public.orders;
create trigger trg_orders_touch before update on public.orders
  for each row execute function public.touch_updated_at();

--------------------------------------------------------------------------
-- order_lines — captured pricing, not references. unit_price is the list
-- price at write time; discount_pct/effective_unit_price are recomputed
-- server-side at submit. price_list_item_id is advisory (set null when an
-- admin re-uploads items) — part_id + captured prices are the record.
--------------------------------------------------------------------------
create table if not exists public.order_lines (
    id                   bigint generated always as identity primary key,
    order_id             bigint not null references public.orders (id) on delete cascade,
    price_list_id        bigint not null references public.price_lists (id),
    price_list_item_id   bigint references public.price_list_items (id) on delete set null,
    part_id              text not null,
    description          text,
    qty                  int not null check (qty > 0),
    unit_price           numeric(12,2) not null check (unit_price >= 0),
    discount_pct         numeric(7,4) not null default 0
                         check (discount_pct >= 0 and discount_pct < 100),
    effective_unit_price numeric(12,2) not null check (effective_unit_price >= 0),
    line_total           numeric(14,2) generated always as
                         ((qty)::numeric * effective_unit_price) stored,
    unique (order_id, price_list_id, part_id)
);
alter table public.order_lines enable row level security;

create index if not exists idx_order_lines_order on public.order_lines (order_id);

--------------------------------------------------------------------------
-- order_qc_results — CURRENT findings only; each QC run deletes and
-- rewrites an order's rows. History lives in the ERP and in the status
-- timestamps, not here.
--------------------------------------------------------------------------
create table if not exists public.order_qc_results (
    id             bigint generated always as identity primary key,
    order_id       bigint not null references public.orders (id) on delete cascade,
    run_at         timestamptz not null default now(),
    result         text not null check (result in
                     ('customer_mismatch','price_mismatch','qty_mismatch',
                      'missing_in_erp','extra_in_erp','order_not_found')),
    part_id        text,                        -- null on order-level findings
    app_qty        numeric,
    erp_qty        numeric,
    app_unit_price numeric,
    erp_unit_price numeric,
    detail         text
);
alter table public.order_qc_results enable row level security;

create index if not exists idx_qc_order on public.order_qc_results (order_id);

--------------------------------------------------------------------------
-- my_order_ids() — the caller's readable order set, evaluated once per
-- query as a hashed subplan (`id in (select public.my_order_ids())`).
--------------------------------------------------------------------------
create or replace function public.my_order_ids()
returns setof bigint
language sql stable security definer set search_path = public
as $$
  select o.id
  from public.orders o
  where o.user_id = auth.uid()
     or o.customer_key in (select public.my_customer_keys())
     or ((select public.is_order_entry()) and o.status <> 'draft');
$$;

revoke execute on function public.my_order_ids() from public, anon;
grant execute on function public.my_order_ids() to authenticated;

comment on function public.my_order_ids() is
  'Orders the caller may read: their own, any on their resolved book (a '
  'principal sees agency orders), and — for order_entry — every post-draft '
  'order. Use as `id in (select public.my_order_ids())` in policies.';

--------------------------------------------------------------------------
-- RLS
--------------------------------------------------------------------------
-- The direct user_id branch is not redundant with my_order_ids(): an
-- INSERT ... RETURNING (what supabase-js .insert().select() sends) checks
-- the new row against this policy, and my_order_ids() reads orders with
-- the statement's snapshot — which cannot see the row being inserted.
-- The direct comparison evaluates on the new row itself and passes.
create policy "read orders" on public.orders
  for select to authenticated
  using (
    (select public.is_admin())
    or user_id = (select auth.uid())
    or id in (select public.my_order_ids())
  );

create policy "rep creates draft orders" on public.orders
  for insert to authenticated
  with check (
    (select public.is_admin())
    or (user_id = (select auth.uid())
        and status = 'draft'
        and customer_key in (select public.my_customer_keys()))
  );

-- USING and WITH CHECK both pin status='draft': a rep can edit only their
-- own drafts and cannot move one out of draft (or re-point it off-book)
-- with a direct update. submit_order() is the only exit.
create policy "rep updates own draft orders" on public.orders
  for update to authenticated
  using (
    (select public.is_admin())
    or (user_id = (select auth.uid()) and status = 'draft')
  )
  with check (
    (select public.is_admin())
    or (user_id = (select auth.uid())
        and status = 'draft'
        and customer_key in (select public.my_customer_keys()))
  );

create policy "rep deletes own draft orders" on public.orders
  for delete to authenticated
  using (
    (select public.is_admin())
    or (user_id = (select auth.uid()) and status = 'draft')
  );

create policy "read order lines" on public.order_lines
  for select to authenticated
  using ((select public.is_admin()) or order_id in (select public.my_order_ids()));

-- Line writes: only inside the caller's own draft. Uncorrelated subquery →
-- one hashed subplan; orders RLS applies inside it and passes for the owner.
create policy "rep writes own draft lines" on public.order_lines
  for insert to authenticated
  with check (
    (select public.is_admin())
    or order_id in (select o.id from public.orders o
                    where o.user_id = (select auth.uid()) and o.status = 'draft')
  );

create policy "rep updates own draft lines" on public.order_lines
  for update to authenticated
  using (
    (select public.is_admin())
    or order_id in (select o.id from public.orders o
                    where o.user_id = (select auth.uid()) and o.status = 'draft')
  )
  with check (
    (select public.is_admin())
    or order_id in (select o.id from public.orders o
                    where o.user_id = (select auth.uid()) and o.status = 'draft')
  );

create policy "rep deletes own draft lines" on public.order_lines
  for delete to authenticated
  using (
    (select public.is_admin())
    or order_id in (select o.id from public.orders o
                    where o.user_id = (select auth.uid()) and o.status = 'draft')
  );

-- QC results: read-only to clients; written only by run_order_qc()
-- (SECURITY DEFINER). No insert/update/delete policies on purpose.
create policy "read qc results" on public.order_qc_results
  for select to authenticated
  using ((select public.is_admin()) or order_id in (select public.my_order_ids()));

revoke all on public.orders          from anon, public;
revoke all on public.order_lines     from anon, public;
revoke all on public.order_qc_results from anon, public;
grant select, insert, update, delete on public.orders      to authenticated;
grant select, insert, update, delete on public.order_lines to authenticated;
grant select on public.order_qc_results to authenticated;

comment on table public.orders is
  'Portal-written orders. Never touches the ERP: order_entry keys them in '
  'by hand and records erp_order_number; run_order_qc() compares afterwards.';
comment on table public.order_lines is
  'Captured line pricing. discount_pct/effective_unit_price are recomputed '
  'authoritatively by submit_order(); the frontend engine is preview-only.';
comment on table public.order_qc_results is
  'Current ERP-vs-portal findings per order, rewritten on every QC run.';

--------------------------------------------------------------------------
-- Transition RPCs. All SECURITY DEFINER: they re-check role and current
-- status themselves, then write states the table policies deliberately
-- do not allow directly.
--------------------------------------------------------------------------

/*
  submit_order — draft → submitted, and the authoritative pricing pass.

  Validates every line against effective_price_lists() *today* (list still
  effective for the order's customer type, item still on the list, captured
  unit_price still the published price), then recomputes the promo discount
  per price list:

      multiples = floor(total_qty / (buy+get))
      pct       = round(100 * multiples * get / total_qty, 4)

  — the exact economic value of the earned free units, prorated across every
  qualifying unit. Below one full block: 0%. At exact multiples this equals
  get/(buy+get); remainder units dilute it. Never a free line.
*/
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

-- recall_order — submitted → draft, only while nobody has entered it.
create or replace function public.recall_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
begin
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

-- cancel_order — draft/submitted → cancelled. After entry the ERP copy
-- exists; cancelling THAT is an ERP-side act, out of scope by the hard rule.
create or replace function public.cancel_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
begin
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

-- mark_order_entered — submitted → entered, with the ERP order number.
create or replace function public.mark_order_entered(
  p_order_id bigint,
  p_erp_order_number text
)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_num   text := upper(trim(p_erp_order_number));
  v_order public.orders;
begin
  if not (public.is_order_entry() or public.is_admin()) then
    raise exception 'only order entry or an admin may mark orders entered';
  end if;
  if v_num is null or v_num = '' then
    raise exception 'an ERP order number is required';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if v_order.status <> 'submitted' then
    raise exception 'order % is %, only submitted orders can be marked entered',
      p_order_id, v_order.status;
  end if;

  update public.orders
  set status = 'entered',
      erp_order_number = v_num,
      entered_at = now(),
      entered_by = v_uid
  where id = p_order_id
  returning * into v_order;
  return v_order;
exception
  when unique_violation then
    raise exception 'ERP order number % is already recorded on another order', v_num;
end;
$$;

-- reopen_entered_order — entered → submitted: the wrong-ERP-number escape
-- hatch. Blocked once verified (the numbers matched; reopening would only
-- detach a proven pairing).
create or replace function public.reopen_entered_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not (public.is_order_entry() or public.is_admin()) then
    raise exception 'only order entry or an admin may reopen an entered order';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if v_order.status not in ('entered', 'discrepancy') then
    raise exception 'order % is %, only entered/discrepancy orders can be reopened',
      p_order_id, v_order.status;
  end if;

  delete from public.order_qc_results where order_id = p_order_id;
  update public.orders
  set status = 'submitted',
      erp_order_number = null,
      entered_at = null,
      entered_by = null,
      qc_checked_at = null
  where id = p_order_id
  returning * into v_order;
  return v_order;
end;
$$;

-- resolve_discrepancy — discrepancy → verified, admin judgment call after
-- investigating (e.g. an agreed price change the portal order predates).
create or replace function public.resolve_discrepancy(
  p_order_id bigint,
  p_note text default null
)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_admin() then
    raise exception 'only an admin may resolve a discrepancy';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if v_order.status <> 'discrepancy' then
    raise exception 'order % is %, only discrepancy orders can be resolved',
      p_order_id, v_order.status;
  end if;

  delete from public.order_qc_results where order_id = p_order_id;
  update public.orders
  set status = 'verified',
      verified_at = now(),
      resolution_note = p_note
  where id = p_order_id
  returning * into v_order;
  return v_order;
end;
$$;

--------------------------------------------------------------------------
-- run_order_qc — the read-only ERP comparison.
--
-- Called nightly from etl/views.yml post_load_sql (as postgres; auth.uid()
-- is null) and on demand from the app ("Re-check now": admin/order_entry).
--
-- Per order in entered/discrepancy (an explicit p_order_id also re-checks
-- verified — the ERP can drift after the fact):
--   · no ERP rows within 3 days of entry  → ETL lag, leave untouched
--   · no ERP rows after 3 days            → order_not_found
--   · ERP line on another customer        → customer_mismatch
--   · aggregate both sides by part_id     → missing_in_erp / extra_in_erp /
--                                           qty_mismatch / price_mismatch
-- ERP effective price = unit_price * (1 - trade_discount_pct/100), weighted
-- by qty — comparing raw unit_price would flag every promo order. Tolerance
-- $0.011 absorbs cent-rounding of the prorated percent.
-- Service lines and cancelled lines (VISUAL line_status 'X') are excluded.
--------------------------------------------------------------------------
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

--------------------------------------------------------------------------
-- Function exposure: signed-in users call these on /rest/v1/rpc; each one
-- enforces its own role/status rules internally.
--------------------------------------------------------------------------
revoke execute on function public.submit_order(bigint)                from public, anon;
revoke execute on function public.recall_order(bigint)                from public, anon;
revoke execute on function public.cancel_order(bigint)                from public, anon;
revoke execute on function public.mark_order_entered(bigint, text)    from public, anon;
revoke execute on function public.reopen_entered_order(bigint)        from public, anon;
revoke execute on function public.resolve_discrepancy(bigint, text)   from public, anon;
revoke execute on function public.run_order_qc(bigint)                from public, anon;
grant execute on function public.submit_order(bigint)              to authenticated;
grant execute on function public.recall_order(bigint)              to authenticated;
grant execute on function public.cancel_order(bigint)              to authenticated;
grant execute on function public.mark_order_entered(bigint, text)  to authenticated;
grant execute on function public.reopen_entered_order(bigint)      to authenticated;
grant execute on function public.resolve_discrepancy(bigint, text) to authenticated;
grant execute on function public.run_order_qc(bigint)              to authenticated;

--------------------------------------------------------------------------
-- Feature flag: the order writer ships dark, like every capture feature.
--------------------------------------------------------------------------
insert into public.app_settings (setting_key, enabled, description) values
  ('feature.orders', false,
   'Order writer: write orders against published price lists, entry queue, ERP QC comparison')
on conflict (setting_key) do nothing;
