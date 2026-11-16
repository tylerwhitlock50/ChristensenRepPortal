/*============================================================================
  20261116110000_rep_confidentiality_tightening.sql — four places where a rep
  or principal could read a little more than their own book.

  Found in the 2026-11-16 confidentiality review. None exposed another rep's
  accounts, dollars, contacts or notes; each is a narrower leak. Admins and
  inside sales (order_entry) read exactly what they read before.

  1. Deactivated users kept explicit account grants.
       my_customer_keys() required an active profile for the own-book, agency
       and inside-sales branches, but not for the account_assignments 'grant'
       branch. Now every branch does.

  2. The rep roster was open.
       erp.dim_sales_rep had `using (true)` (007): any signed-in user could
       list every rep's name, code, agency (vendor_id) and territory. Now a
       user reads only the reps they have a reason to see:
         * their own rep row,
         * a principal: every rep in their agency,
         * the rep assigned to any account on their book (which is what the
           account pages, agency views and v_user_accounts join for).
       The column grants from 20260901190300 are unchanged.

  3. A rep kept reading portal orders they drafted after the account moved.
       my_order_ids() and the "read orders" policy each had a bare
       `user_id = auth.uid()` branch. Order lines, QC results, order
       documents and order_owner_names all follow my_order_ids(), so a
       reassigned or revoked rep still read the order, its prices, and
       documents added later. Own orders now also need the account to be on
       the caller's book today. mcp_create_order_draft's idempotent replay
       (which returns a preview built with definer rights) gets the same
       check.
       Not covered here: submit_order() still checks only ownership, so the
       owner of a draft on an account that has since left their book can
       still submit it by id (they can no longer read it). It is ~200 lines
       restated across several migrations; tightening it is its own change.

  4. Company-wide unit counts had no minimum dealer count.
       report_global_product_sales returned SKUs bought by one to three
       dealers (the "4+ dealers" filter was a checkbox in the browser), and
       report_account_sku_gaps accepted p_min_dealers below 4. For a
       one-dealer SKU the units are that dealer's. Reps and principals now
       get only SKUs at least four dealers bought; admins and inside sales
       are unchanged.

  Safe to re-run.
============================================================================*/

--------------------------------------------------------------------------
-- 1. my_customer_keys(): the explicit-grant branch needs an active profile
--    too. Identical to 20261113090000 otherwise.
--------------------------------------------------------------------------
create or replace function public.my_customer_keys()
 RETURNS SETOF text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
  with me as (
    select p.sales_rep_key, p.rep_group_vendor_id, p.role
    from public.profiles p
    where p.user_id = public.effective_user_id()
      and p.active
  ),
  derived as (
    -- own book
    select c.customer_key
    from me
    join erp.dim_customer c
      on c.assigned_sales_rep_id = me.sales_rep_key
    where me.sales_rep_key is not null
      and not (me.sales_rep_key = any (public.placeholder_rep_keys()))

    union

    -- group book: principal over every rep in their agency (vendor)
    select c.customer_key
    from me
    join erp.dim_sales_rep sr
      on sr.vendor_id = me.rep_group_vendor_id
    join erp.dim_customer c
      on c.assigned_sales_rep_id = sr.sales_rep_key
    where me.rep_group_vendor_id is not null
      and sr.vendor_id is not null
      and not (sr.sales_rep_key = any (public.placeholder_rep_keys()))

    union

    -- inside sales (order_entry): every account, to read and to order for.
    -- What they may CHANGE is the read-only trigger's business, not this.
    select c.customer_key
    from me
    cross join erp.dim_customer c
    where me.role = 'order_entry'

    union

    -- explicit grant (house accounts, temporary coverage). `me` is one row
    -- for an active profile and none for a deactivated one, so a
    -- deactivated user's grants stop with the rest of their book.
    select aa.customer_key
    from me
    join public.account_assignments aa
      on aa.user_id = public.effective_user_id()
    where aa.access = 'grant'
  )
  select d.customer_key
  from derived d
  where not exists (
    select 1
    from public.account_assignments r
    where r.user_id = public.effective_user_id()
      and r.customer_key = d.customer_key
      and r.access = 'revoke'
  );
$$;

comment on function public.my_customer_keys() is
  'The customer keys the effective user may see: own book, agency book, '
  'explicit grants minus revokes; every customer for inside sales '
  '(order_entry, 20261113090000). Every branch needs an active profile '
  '(20261116110000).';

--------------------------------------------------------------------------
-- 2. erp.dim_sales_rep: readable rows follow the caller's book.
--
--    SECURITY DEFINER on purpose: the helper reads erp.dim_sales_rep and
--    public.profiles itself, and a plain subquery on dim_sales_rep inside
--    its own policy would recurse. Keyed on effective_user_id() so an admin
--    viewing as a rep is scoped like that rep. Called as
--    `in (select public.my_visible_rep_keys())` so it is one hashed subplan
--    per query, not a call per row (the 010 lesson).
--------------------------------------------------------------------------
create or replace function public.my_visible_rep_keys()
returns setof text
language sql stable security definer set search_path = public, erp
as $$
  with me as (
    select p.sales_rep_key, p.rep_group_vendor_id
    from public.profiles p
    where p.user_id = public.effective_user_id()
      and p.active
  )
  -- my own rep row
  select me.sales_rep_key
  from me
  where me.sales_rep_key is not null

  union

  -- a principal: every rep in the agency
  select sr.sales_rep_key
  from me
  join erp.dim_sales_rep sr on sr.vendor_id = me.rep_group_vendor_id
  where me.rep_group_vendor_id is not null
    and sr.vendor_id is not null

  union

  -- the rep assigned to any account on my book (covers explicit grants,
  -- and every rep for inside sales, whose book is every account)
  select c.assigned_sales_rep_id
  from erp.dim_customer c
  where c.assigned_sales_rep_id is not null
    and c.customer_key in (select public.my_customer_keys());
$$;

revoke execute on function public.my_visible_rep_keys() from public, anon;
grant execute on function public.my_visible_rep_keys() to authenticated;

comment on function public.my_visible_rep_keys() is
  'Rep codes the effective user may read from erp.dim_sales_rep: their own, '
  'their agency''s (principal), and the rep assigned to any account on their '
  'book. Use as `sales_rep_key in (select public.my_visible_rep_keys())`.';

drop policy if exists "read dim_sales_rep" on erp.dim_sales_rep;
create policy "read dim_sales_rep" on erp.dim_sales_rep
  for select to authenticated
  using (
    (select public.is_admin())
    or (select public.is_order_entry())
    or sales_rep_key in (select public.my_visible_rep_keys())
  );

--------------------------------------------------------------------------
-- 3. Orders: "my own order" also needs the account on my book today.
--
--    my_order_ids(): the old first branch (o.user_id = auth.uid()) is gone.
--    With the book condition added it would be a subset of the second
--    branch, so the second branch alone says it.
--------------------------------------------------------------------------
create or replace function public.my_order_ids()
returns setof bigint
language sql stable security definer set search_path = public
as $$
  select o.id
  from public.orders o
  where o.customer_key in (select public.my_customer_keys())
     or ((select public.is_order_entry()) and o.status <> 'draft');
$$;

revoke execute on function public.my_order_ids() from public, anon;
grant execute on function public.my_order_ids() to authenticated;

comment on function public.my_order_ids() is
  'Orders the caller may read: any on their resolved book today (their own '
  'included; a principal sees agency orders), and — for order_entry — every '
  'post-draft order. An order the caller created on an account that has '
  'since left their book is not theirs to read (20261116110000). Use as '
  '`id in (select public.my_order_ids())` in policies.';

-- The direct branch stays for INSERT ... RETURNING (see 20260817000200: the
-- new row is not visible to my_order_ids()'s snapshot). It still passes for
-- a fresh insert, because the insert policy already requires the account to
-- be on the caller's book.
drop policy if exists "read orders" on public.orders;
create policy "read orders" on public.orders
  for select to authenticated
  using (
    (select public.is_admin())
    or (user_id = (select auth.uid())
        and customer_key in (select public.my_customer_keys()))
    or id in (select public.my_order_ids())
  );

-- mcp_create_order_draft: the replay of an earlier idempotency key returns
-- mcp_order_preview(), which reads the customer, ship-to and contact with
-- definer rights. Same book check as mcp_order_apply (same error text, so
-- "not on your book" and "does not exist" stay indistinguishable).
-- Identical to 20261111100100 otherwise.
create or replace function public.mcp_create_order_draft(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public, erp
as $$
declare
  v_params  jsonb;
  v_key     text;
  v_hash    text;
  v_old     record;
  v_id      bigint;
  v_preview jsonb;
begin
  v_params := public.mcp_orders_gate();
  perform public.mcp_order_check_keys(p, false);

  if jsonb_typeof(p -> 'idempotency_key') is distinct from 'string'
     or (p ->> 'idempotency_key') !~ '^[!-~]{8,100}$' then
    raise exception 'invalid_input:idempotency_key: 8-100 printable characters, no spaces; reuse it when retrying the same request';
  end if;
  v_key  := p ->> 'idempotency_key';
  v_hash := encode(sha256(convert_to((p - 'idempotency_key')::text, 'UTF8')), 'hex');

  select o.id, o.request_hash, o.customer_key into v_old
  from public.orders o
  where o.user_id = auth.uid() and o.client_request_id = v_key;
  if found then
    if v_old.request_hash is distinct from v_hash then
      raise exception 'idempotency_conflict: idempotency_key % was already used for a different request (order %); use a new key for a new order', v_key, v_old.id;
    end if;
    if not (public.is_admin()
            or v_old.customer_key in (select public.my_customer_keys())) then
      raise exception 'customer_not_in_book: % is not on your book (or does not exist)', v_old.customer_key;
    end if;
    return public.mcp_order_preview(v_old.id, true);
  end if;

  v_id := public.mcp_order_apply(null, p, v_params, v_key, v_hash);
  v_preview := public.mcp_order_preview(v_id, false);
  perform public.mcp_order_store_warnings(v_id, v_preview);
  return v_preview;
end;
$$;

--------------------------------------------------------------------------
-- 4. Company-wide unit counts: at least four dealers for reps.
--
--    Both functions keep their signature, OUT columns, clamps and grants
--    from 20260818212142; only the minimum changes. is_admin() follows
--    view-as, so an admin viewing as a rep gets the rep's result.
--------------------------------------------------------------------------
create or replace function public.report_global_product_sales(
    p_months int default 12,
    p_limit  int default 500
)
returns table (
    part_key         text,
    part_id          text,
    part_description text,
    product_code     text,
    product_family   text,
    chambering       text,
    barrel_length    text,
    qty              numeric,
    invoice_count    int,
    account_count    int
)
language sql
stable
security definer
set search_path = ''
as $$
  select
      s.part_key,
      p.part_id,
      p.part_description,
      p.product_code,
      p.product_family,
      p.chambering,
      p.barrel_length,
      s.qty,
      s.invoice_count,
      s.account_count
  from (
      select
          m.part_key,
          coalesce(sum(m.qty), 0)::numeric      as qty,
          -- Month cells partition invoices per part (one invoice = one
          -- customer, one date), so these per-cell distinct counts SUM
          -- exactly — see erp.agg_sku_month's comment.
          coalesce(sum(m.invoice_count), 0)::int as invoice_count,
          count(distinct m.customer_key)::int    as account_count
      from erp.agg_sku_month m
      where m.sales_month >= (date_trunc('month', current_date)
                              - make_interval(months => greatest(1, least(coalesce(p_months, 12), 36))))::date
      group by m.part_key
      -- A SKU fewer than four dealers bought is close to one dealer's own
      -- volume, so reps and principals do not get it (20261116110000).
      having count(distinct m.customer_key) >= 4
          or (select public.is_admin())
          or (select public.is_order_entry())
  ) s
  left join erp.dim_part p on p.part_key = s.part_key
  order by s.qty desc
  limit greatest(1, least(coalesce(p_limit, 500), 2000));
$$;

comment on function public.report_global_product_sales(int, int) is
  'Company-wide sales by SKU for the last p_months whole months (clamped '
  '1-36) plus the current partial month, top p_limit by units (clamped '
  '1-2000), read from erp.agg_sku_month (nightly rollup — 20260818120000). '
  'SECURITY DEFINER on purpose: reps see global aggregates. Output is '
  'part-grain, units-and-counts only - never add customer or dollar '
  'columns (see 033). Reps and principals get only SKUs at least four '
  'dealers bought; admins and inside sales get all (20261116110000).';

revoke execute on function public.report_global_product_sales(int, int) from public, anon;
grant execute on function public.report_global_product_sales(int, int) to authenticated;

create or replace function public.report_account_sku_gaps(
    p_customer_key  text,
    p_months        int default 12,
    p_min_dealers   int default 4,
    p_limit         int default 25
)
returns table (
    part_key           text,
    part_id            text,
    part_description   text,
    product_code       text,
    product_family     text,
    chambering         text,
    barrel_length      text,
    upc                text,
    ats_qty            numeric,
    dealer_count       int,
    units_sold         numeric,
    bought_before      boolean,
    last_bought_date   date
)
language sql
stable
security definer
set search_path = ''
as $$
    with guard as (
        -- Evaluated as the CALLER despite SECURITY DEFINER — see 036.
        select public.has_account_access(p_customer_key) as ok,
               -- Reps and principals cannot ask below four dealers
               -- (20261116110000); admins and inside sales can.
               case when public.is_admin() or public.is_order_entry()
                    then 1 else 4 end as floor_dealers
    ),
    -- Company-wide breadth, now a rollup group-by. Memo lines and null
    -- part keys are already excluded by the refresh.
    global as (
        select
            m.part_key,
            count(distinct m.customer_key)::int      as dealer_count,
            coalesce(sum(m.qty), 0)::numeric         as units_sold
        from erp.agg_sku_month m, guard
        where guard.ok
          and m.sales_month >= (date_trunc('month', current_date)
                                - make_interval(months => greatest(1, least(coalesce(p_months, 12), 36))))::date
        group by m.part_key
    ),
    -- What this ACCOUNT has bought, over the SKU rollup's 4-year window.
    mine as (
        select
            s.part_key,
            max(s.last_invoice_date) as last_bought_date
        from erp.agg_sku_year s, guard
        where guard.ok
          and s.customer_key = p_customer_key
        group by s.part_key
    )
    select
        a.part_key,
        p.part_id,
        p.part_description,
        p.product_code,
        p.product_family,
        p.chambering,
        p.barrel_length,
        p.upc,
        a.available_to_sell_qty::numeric                    as ats_qty,
        g.dealer_count,
        g.units_sold,
        (m.part_key is not null)                            as bought_before,
        m.last_bought_date
    from erp.fact_available_to_sell a
    join global g            on g.part_key = a.part_key
    cross join guard
    left join mine m         on m.part_key = a.part_key
    left join erp.dim_part p on p.part_key = a.part_key
    where a.available_to_sell_qty >= 1          -- sellable today; see 027
      and g.dealer_count >= greatest(guard.floor_dealers, coalesce(p_min_dealers, 4))
      -- Finished firearms only. Mirrors isGunRow() in useIntel.ts (036).
      and coalesce(p.product_code, '') !~* 'component'
      and (
            coalesce(nullif(btrim(p.product_family), ''), 'N/A') <> 'N/A'
         or coalesce(nullif(btrim(p.chambering), ''), 'N/A')     <> 'N/A'
      )
    order by (m.part_key is not null), g.dealer_count desc, g.units_sold desc
    limit greatest(1, least(coalesce(p_limit, 25), 100));
$$;

comment on function public.report_account_sku_gaps(text, int, int, int) is
  'SKUs available to ship today that this account does not buy, ranked by '
  'how many dealers company-wide do — read from erp.agg_sku_month / '
  'agg_sku_year (nightly rollups, 20260818120000). SECURITY DEFINER, gated '
  'on has_account_access(p_customer_key) as the FIRST thing it evaluates. '
  'Part-grain, units and counts only - never add customer keys or '
  'company-wide dollars (see 033/036). p_min_dealers cannot go below 4 for '
  'reps and principals (20261116110000).';

revoke execute on function public.report_account_sku_gaps(text, int, int, int)
  from public, anon;
grant execute on function public.report_account_sku_gaps(text, int, int, int)
  to authenticated;
