/*============================================================================
  014_erp_column_drift.sql

  Historical drift repair for columns the ETL added to the erp landing tables
  after the original 002_erp_read_tables.sql deployment. The current repository
  baseline now includes these columns in 002 so a brand-new environment starts
  with the intended schema. This migration remains in forward history for
  environments that applied the older 002 definition before the baseline was
  reconciled.

  Every statement is `add column if not exists`, so it is a no-op against a
  fresh build or a repaired database and still fixes an older environment that
  does not have the columns.
  Types match what the ETL actually created — verified against
  information_schema before writing this.
============================================================================*/

-- dim_part
alter table erp.dim_part
  add column if not exists status  text,
  add column if not exists weight  numeric;

-- dim_sales_rep
-- The ETL grew its own placeholder flag. Today exactly one rep carries it
-- (WEB), which agrees with public.placeholder_rep_keys() from
-- 010_access_performance.sql. See the note at the bottom of this file.
alter table erp.dim_sales_rep
  add column if not exists is_placeholder_rep boolean;

-- fact_inventory_on_hand
alter table erp.fact_inventory_on_hand
  add column if not exists standard_unit_cost      numeric,
  add column if not exists on_hand_value_material  numeric;

-- fact_order_line
-- backlog_amount is the money behind is_backlog_line; v_account_summary's
-- open_order_value is built on it, so a fresh environment without it breaks
-- the account mini-dashboard rather than just losing a column.
alter table erp.fact_order_line
  add column if not exists is_service_line        boolean,
  add column if not exists has_linked_work_order  boolean,
  add column if not exists desired_ship_date_key  integer,
  add column if not exists backlog_amount         numeric;

-- Generated, like the other date columns in 002. Added separately because
-- `add column if not exists` cannot carry a GENERATED clause in the same
-- statement as plain columns on every supported version.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'erp'
      and table_name   = 'fact_order_line'
      and column_name  = 'desired_ship_date'
  ) then
    alter table erp.fact_order_line
      add column desired_ship_date date
      generated always as (erp.key_to_date(desired_ship_date_key)) stored;
  end if;
end
$$;

-- fact_shipment_line
alter table erp.fact_shipment_line
  add column if not exists shipment_state text;

/*----------------------------------------------------------------------------
  Follow-up worth a decision, deliberately not made here
  -----------------------------------------------------
  erp.dim_sales_rep.is_placeholder_rep now exists and flags WEB — the same rep
  code that public.placeholder_rep_keys() hardcodes. TECH_STACK §3.4 predates
  the column and says not to add one.

  Having both is fine but redundant: a NEW placeholder added in the ERP would
  be flagged by the ETL and still grant access, because my_customer_keys()
  only consults the static array. Teaching it to honour the flag as well would
  make new placeholders fail closed automatically. That is an access-model
  change and belongs in its own migration with its own test, not bundled into
  a column-drift repair.
----------------------------------------------------------------------------*/
