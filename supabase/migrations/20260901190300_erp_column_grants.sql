/*============================================================================
  20260901190300_erp_column_grants.sql — cost, margin and commission
  columns are not for reps.

  Why
  ---
  007 granted SELECT on every erp table to authenticated with using(true)
  policies on the dimensions, and `erp` is an exposed PostgREST schema. So
  GET /rest/v1/dim_part?select=part_id,standard_unit_cost worked with any
  rep JWT — including the non-employee rep groups' — and so did
  dim_sales_rep's commission percentages and contact details, the shipment
  fact's COGS and gross margin, the invoice fact's commission amounts, and
  the inventory fact's unit costs and on-hand values. Nothing in the app
  reads any of those columns; they were simply never fenced.

  What
  ----
  1. The two views that expanded `*` over these tables are restated with
     explicit column lists (a security_invoker view needs the caller to hold
     SELECT on every column it references, not just the ones it outputs).
  2. Table-level SELECT is replaced with column-level SELECT on every
     column except a deny list, computed from the live catalog so the ETL's
     column drift (014) can never silently re-expose something. Table-level
     RLS policies are untouched: they still decide WHICH ROWS; grants now
     also decide WHICH COLUMNS.
  3. anon's leftover DML grants on public tables (from Supabase's default
     privileges, pre-011) are revoked, and the default privilege is turned
     off so new tables don't get them either. Every policy is already
     `to authenticated`, so this changes nothing observable today; it
     removes the one-mis-scoped-policy-from-a-leak.

  Consequence for callers: `select=*` on these four erp tables now fails
  for authenticated with "permission denied" — name your columns. Every
  existing caller already does (grep for .from('dim_part') etc.).
============================================================================*/

--------------------------------------------------------------------------
-- 1. Views that reached the fenced columns through `*`.
--------------------------------------------------------------------------

create or replace view public.v_price_list_items
with (security_invoker = true) as
select
  i.id,
  i.price_list_id,
  i.part_id,
  coalesce(p.part_description, i.description) as description,
  i.unit_price,
  (p.part_key is not null)                    as in_erp,
  p.product_family,
  p.chambering,
  p.action_type,
  p.barrel_length,
  p.finish
from public.price_list_items i
left join lateral (
  select dp.part_key, dp.part_description, dp.product_family, dp.chambering,
         dp.action_type, dp.barrel_length, dp.finish
  from erp.dim_part dp
  where dp.part_id = i.part_id
  order by coalesce(dp.is_unknown_part, false), dp.part_key
  limit 1
) p on true;

create or replace view public.v_account_recent_shipments
with (security_invoker = true)
as
select
    r.customer_key,
    r.packlist_id,
    r.line_num,
    r.order_id,
    r.invoice_id,
    r.ship_date,
    r.promise_date,
    r.actual_delivery_date,
    r.shipment_state,
    r.shipper_status_desc,
    r.part_key,
    p.part_id,
    p.part_description,
    r.shipped_qty,
    r.shipped_revenue
from (
    select
        s.customer_key, s.packlist_id, s.line_num, s.order_id, s.invoice_id,
        s.ship_date, s.promise_date, s.actual_delivery_date, s.shipment_state,
        s.shipper_status_desc, s.part_key, s.shipped_qty, s.shipped_revenue,
        row_number() over (
            partition by s.customer_key
            order by s.ship_date desc nulls last, s.packlist_id desc, s.line_num
        ) as rn
    from erp.fact_shipment_line s
) r
left join erp.dim_part p on p.part_key = r.part_key
where r.rn <= 20;

--------------------------------------------------------------------------
-- 2. Column-level SELECT. Deny lists are the sensitive columns; everything
--    else on the table stays readable exactly as before.
--------------------------------------------------------------------------

do $$
declare
  t    record;
  cols text;
begin
  for t in
    select *
    from (values
      ('dim_part', array[
         'wholesale_unit_cost', 'unit_material_cost', 'unit_labor_cost',
         'unit_burden_cost', 'unit_service_cost', 'fixed_cost',
         'burden_percent', 'standard_unit_cost']),
      ('dim_sales_rep', array[
         'employee_id', 'pay_method', 'default_commission_pct',
         'earning_code_id', 'sales_rep_email', 'sales_rep_phone',
         'entity_commission_pct', 'pct_paid_at_order', 'pct_paid_at_shipment',
         'pct_paid_at_collect', 'entity_employee_id', 'entity_supplier_id',
         'commission_accrual_account_id', 'commission_expense_account_id']),
      ('fact_shipment_line', array[
         'cogs_amount', 'gross_margin_amount', 'cogs_material', 'cogs_labor',
         'cogs_burden', 'cogs_service', 'commission_pct']),
      ('fact_invoice_line', array[
         'commission_amount', 'commission_pct']),
      ('fact_inventory_on_hand', array[
         'unit_material_cost', 'unit_labor_cost', 'unit_burden_cost',
         'unit_service_cost', 'on_hand_value_material', 'on_hand_value_labor',
         'on_hand_value_burden', 'on_hand_value_service', 'on_hand_value',
         'standard_unit_cost'])
    ) as v(tbl, deny)
  loop
    select string_agg(quote_ident(c.column_name), ', ' order by c.ordinal_position)
      into cols
    from information_schema.columns c
    where c.table_schema = 'erp'
      and c.table_name   = t.tbl
      and c.column_name <> all (t.deny);

    if cols is null then
      raise exception 'erp_column_grants: erp.% has no columns?', t.tbl;
    end if;

    execute format('revoke select on erp.%I from authenticated', t.tbl);
    execute format('grant select (%s) on erp.%I to authenticated', cols, t.tbl);
  end loop;
end;
$$;

comment on table erp.dim_part is
  'ERP part master (bi.vw_DimPart). Cost columns are column-revoked from '
  'authenticated (20260901190300) — name your columns; select=* is denied.';
comment on table erp.dim_sales_rep is
  'ERP sales reps (bi.vw_DimSalesRep). Commission, pay and contact columns '
  'are column-revoked from authenticated (20260901190300).';

--------------------------------------------------------------------------
-- 3. anon holds nothing in public, now or later.
--------------------------------------------------------------------------

revoke all on all tables in schema public from anon;
alter default privileges for role postgres in schema public
  revoke all on tables from anon;
