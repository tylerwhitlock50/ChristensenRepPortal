/*============================================================================
  002_erp_read_tables.sql
  Purpose: Landing tables for the SQL Server bi.vw_* views. Column-for-column
           mirrors (snake_cased) so the ETL is a straight SELECT * push.
           Load pattern: truncate-and-load inside one transaction per table.

  v1 scope (portal needs):
    erp.dim_customer, erp.dim_ship_to, erp.dim_sales_rep, erp.dim_part,
    erp.fact_order_line, erp.fact_invoice_line, erp.fact_shipment_line,
    erp.fact_inventory_on_hand
  Deliberately NOT landed in v1: dim_site, dim_warehouse, dim_date (single
  site; dates handled via generated date columns), fact_inventory_location.

  Date keys arrive as int yyyymmdd with sentinel 19000101 for NULL (matching
  the bi views). Each important key gets a generated `*_date` column (NULL
  when sentinel) so the app queries real dates without ETL transformation.

  RLS is enabled here; policies live in 007_rls_policies.sql.
============================================================================*/

-- Helper: immutable yyyymmdd-int → date (NULL on sentinel / null)
create or replace function erp.key_to_date(k int)
returns date
language sql immutable
as $$
  select case
           when k is null or k = 19000101 then null
           else make_date(k / 10000, (k / 100) % 100, k % 100)
         end;
$$;

--------------------------------------------------------------------------
-- erp.dim_customer  ←  bi.vw_DimCustomer  (grain: one row per customer)
--------------------------------------------------------------------------
create table if not exists erp.dim_customer (
    customer_key                text primary key,
    customer_id                 text not null,
    customer_name               text,
    sold_to_address1            text,
    sold_to_address2            text,
    sold_to_address3            text,
    sold_to_city                text,
    sold_to_state               text,
    sold_to_zip_code            text,
    sold_to_country             text,
    bill_to_name                text,
    bill_to_address1            text,
    bill_to_address2            text,
    bill_to_address3            text,
    bill_to_city                text,
    bill_to_state               text,
    bill_to_zip_code            text,
    bill_to_country             text,
    assigned_sales_rep_id       text,
    assigned_sales_rep_name     text,
    territory                   text,
    sales_region                text,
    customer_group_id           text,
    carms_customer_group        text,
    carms_customer_sub_group    text,
    price_group                 text,
    priority                    text,
    market_id                   text,
    sic_code                    text,
    industry_code               text,
    internal_customer_flag      text,
    customer_type               text,
    site_priority_code          text,
    order_fill_rate_target      numeric,
    discount_code               text,
    currency_id                 text,
    default_sales_tax_group_id  text,
    tax_exempt_flag             text,
    tax_id_number               text,
    finance_charge_flag         text,
    dunning_letters_flag        text,
    active_flag                 text,
    account_open_date           date,
    last_order_date             date,
    yearly_sales_goal_raw       text,
    yearly_sales_goal           numeric(18,2),
    credit_status               text,
    credit_limit_amount         numeric,
    finance_charge_exempt_flag  text,
    finance_charge_pct          numeric,
    ar_terms_rule_id            text,
    ar_payment_method_id        text,
    ar_active_flag              int,
    receivables_account_id      text,
    bill_to_parent_flag         text,
    email_invoices_flag         text,
    invoice_email               text,
    email_statements_flag       text,
    statement_email             text,
    ffl_license_number          text,
    ffl_expiration_raw          text,
    loaded_at                   timestamptz not null default now()
);
alter table erp.dim_customer enable row level security;
-- Ownership is derived from this column (has_account_access) — every RLS
-- check on every customer-scoped table resolves through it.
create index if not exists idx_dim_customer_assigned_rep
  on erp.dim_customer (assigned_sales_rep_id);

--------------------------------------------------------------------------
-- erp.dim_ship_to  ←  bi.vw_DimShipTo  (grain: one row per ship-to key)
--------------------------------------------------------------------------
create table if not exists erp.dim_ship_to (
    ship_to_key                 text primary key,
    customer_id                 text,
    addr_no                     int,
    ship_to_id                  text,
    ship_to_name                text,
    address1                    text,
    address2                    text,
    address3                    text,
    city                        text,
    state                       text,
    zip_code                    text,
    country                     text,
    ship_via                    text,
    free_on_board               text,
    carrier_id                  text,
    warehouse_id                text,
    discount_code               text,
    default_sales_tax_group_id  text,
    ship_to_sales_rep_id        text,
    territory                   text,
    active_flag                 text,
    ffl_license_number          text,
    ffl_expiration_raw          text,
    address_source              text,
    is_unknown_ship_to          boolean,
    loaded_at                   timestamptz not null default now()
);
alter table erp.dim_ship_to enable row level security;
create index if not exists idx_dim_ship_to_customer on erp.dim_ship_to (customer_id);

--------------------------------------------------------------------------
-- erp.dim_sales_rep  ←  bi.vw_DimSalesRep
--------------------------------------------------------------------------
create table if not exists erp.dim_sales_rep (
    sales_rep_key               text primary key,
    sales_rep_id                text,
    sales_rep_name              text,
    employee_id                 text,
    vendor_id                   text,
    pay_method                  text,
    default_commission_pct      numeric,
    earning_code_id             text,
    sales_rep_email             text,
    sales_rep_phone             text,
    territory_id                text,
    sales_rep_type              text,
    entity_commission_pct       numeric,
    pct_paid_at_order           numeric,
    pct_paid_at_shipment        numeric,
    pct_paid_at_collect         numeric,
    entity_employee_id          text,
    entity_supplier_id          text,
    commission_accrual_account_id text,
    commission_expense_account_id text,
    is_placeholder_rep          boolean,
    is_unknown_sales_rep        boolean,
    loaded_at                   timestamptz not null default now()
);
alter table erp.dim_sales_rep enable row level security;
-- Principal (rep-group) access derives through vendor_id
create index if not exists idx_dim_sales_rep_vendor
  on erp.dim_sales_rep (vendor_id);

--------------------------------------------------------------------------
-- erp.dim_part  ←  bi.vw_DimPart
--------------------------------------------------------------------------
create table if not exists erp.dim_part (
    part_key                    text primary key,
    part_id                     text,
    part_description            text,
    product_code                text,
    product_code_description    text,
    commodity_code              text,
    commodity_code_description  text,
    stock_um                    text,
    abc_code                    text,
    fabricated_flag             text,
    purchased_flag              text,
    stocked_flag                text,
    detail_only_flag            text,
    is_kit_flag                 text,
    inspection_required_flag    text,
    planning_lead_time_days     numeric,
    preferred_vendor_id         text,
    buyer_user_id               text,
    planner_user_id             text,
    weight_um                   text,
    drawing_id                  text,
    revision_id                 text,
    manufacturer_name           text,
    manufacturer_part_id        text,
    product_family              text,
    chambering                  text,
    barrel_length               text,
    twist                       text,
    finish                      text,
    handedness                  text,
    action_type                 text,
    handguard                   text,
    stock_color                 text,
    stock_style                 text,
    upc                         text,
    order_policy                text,
    order_point                 numeric,
    order_up_to_qty             numeric,
    safety_stock_qty            numeric,
    fixed_order_qty             numeric,
    minimum_order_qty           numeric,
    maximum_order_qty           numeric,
    multiple_order_qty          numeric,
    days_of_supply              numeric,
    minimum_lead_time_days      numeric,
    mrp_required_flag           text,
    primary_warehouse_id        text,
    primary_location_id         text,
    standard_unit_price         numeric,
    wholesale_unit_cost         numeric,
    unit_material_cost          numeric,
    unit_labor_cost             numeric,
    unit_burden_cost            numeric,
    unit_service_cost           numeric,
    fixed_cost                  numeric,
    burden_percent              numeric,
    standard_unit_cost          numeric,
    status                      text,
    weight                      numeric,
    is_unknown_part             boolean,
    loaded_at                   timestamptz not null default now()
);
alter table erp.dim_part enable row level security;

--------------------------------------------------------------------------
-- erp.fact_order_line  ←  bi.vw_FactOrderLine  (grain: order line)
--------------------------------------------------------------------------
create table if not exists erp.fact_order_line (
    order_id                    text not null,
    line_num                    int  not null,
    customer_po_number          text,
    line_status                 text,
    order_status                text,
    order_type                  text,
    order_status_desc           text,
    line_status_desc            text,
    order_state                 text,
    backorder_flag              text,
    customer_part_id            text,
    product_code                text,
    selling_um                  text,
    warehouse_id                text,
    currency_id                 text,
    service_charge_id           text,
    linked_work_order_id        text,
    linked_work_order_count     int,
    customer_key                text not null,
    ship_to_key                 text,
    sales_rep_key               text,
    part_key                    text,
    site_key                    text,
    order_date_key              int,
    promise_date_key            int,
    last_shipped_date_key       int,
    order_date                  date generated always as (erp.key_to_date(order_date_key)) stored,
    promise_date                date generated always as (erp.key_to_date(promise_date_key)) stored,
    last_shipped_date           date generated always as (erp.key_to_date(last_shipped_date_key)) stored,
    order_qty                   numeric,
    order_qty_selling_um        numeric,
    bookings                    numeric,   -- booked order value ($) — ORDER-side headline measure
    total_shipped_qty_to_date   numeric,   -- semi-additive (cumulative on line)
    total_amount_shipped_to_date numeric,  -- semi-additive (cumulative on line)
    allocated_qty               numeric,
    fulfilled_qty               numeric,
    backlog_qty                 numeric,
    backlog_amount              numeric,
    is_backlog_line             boolean,
    is_service_line             boolean,
    has_linked_work_order       boolean,
    desired_ship_date_key       int,
    desired_ship_date           date generated always as (erp.key_to_date(desired_ship_date_key)) stored,
    unit_price                  numeric,   -- non-additive (rate)
    trade_discount_pct          numeric,   -- non-additive (rate)
    loaded_at                   timestamptz not null default now(),
    primary key (order_id, line_num)
);
alter table erp.fact_order_line enable row level security;
create index if not exists idx_fol_customer on erp.fact_order_line (customer_key);
create index if not exists idx_fol_order_date on erp.fact_order_line (order_date);
create index if not exists idx_fol_backlog on erp.fact_order_line (customer_key) where is_backlog_line;

--------------------------------------------------------------------------
-- erp.fact_invoice_line  ←  bi.vw_FactInvoiceLine  (grain: AR invoice line)
-- Revenue = the single certified revenue measure. Memos are NOT negative in
-- this install — include/exclude via is_memo explicitly (see view header).
--------------------------------------------------------------------------
create table if not exists erp.fact_invoice_line (
    invoice_id                  text not null,
    invoice_line_no             int  not null,
    invoice_entity_id           text not null,
    invoice_status              text,
    invoice_type                text,
    document_type_id            text,
    is_memo                     boolean,
    invoice_status_desc         text,
    invoice_type_desc           text,
    invoice_state               text,
    posted_flag                 text,
    shipper_generated_flag      text,
    freight_line_flag           text,
    order_id                    text,
    order_line_no               int,
    packlist_id                 text,
    customer_po_number          text,
    revenue_account_id          text,
    currency_id                 text,
    bill_to_customer_id         text,
    customer_key                text not null,
    ship_to_key                 text,
    sales_rep_key               text,
    part_key                    text,
    site_key                    text,
    invoice_date_key            int,
    last_paid_date_key          int,
    invoice_date                date generated always as (erp.key_to_date(invoice_date_key)) stored,
    last_paid_date              date generated always as (erp.key_to_date(last_paid_date_key)) stored,
    invoice_qty                 numeric,
    revenue                     numeric,   -- net AR line revenue — REVENUE headline measure
    commission_amount           numeric,
    unit_price                  numeric,   -- non-additive
    commission_pct              numeric,   -- non-additive
    loaded_at                   timestamptz not null default now(),
    primary key (invoice_entity_id, invoice_id, invoice_line_no)
);
alter table erp.fact_invoice_line enable row level security;
create index if not exists idx_fil_customer on erp.fact_invoice_line (customer_key);
create index if not exists idx_fil_invoice_date on erp.fact_invoice_line (invoice_date);

--------------------------------------------------------------------------
-- erp.fact_shipment_line  ←  bi.vw_FactShipmentLine  (grain: packlist line)
--------------------------------------------------------------------------
create table if not exists erp.fact_shipment_line (
    packlist_id                 text not null,
    line_num                    int  not null,
    order_id                    text,
    order_line_no               int,
    shipper_status              text,
    shipper_status_desc         text,
    shipment_state              text,
    revenue_status              text,
    no_invoice_flag             text,
    invoice_id                  text,
    bill_of_lading_id           text,
    waybill_number              text,
    ship_via                    text,
    free_on_board               text,
    misc_reference              text,
    rma_id                      text,
    customer_key                text not null,
    ship_to_key                 text,
    sales_rep_key               text,
    part_key                    text,
    site_key                    text,
    ship_date_key               int,
    invoiced_date_key           int,
    actual_delivery_date_key    int,
    promise_date_key            int,
    ship_date                   date generated always as (erp.key_to_date(ship_date_key)) stored,
    invoiced_date               date generated always as (erp.key_to_date(invoiced_date_key)) stored,
    actual_delivery_date        date generated always as (erp.key_to_date(actual_delivery_date_key)) stored,
    promise_date                date generated always as (erp.key_to_date(promise_date_key)) stored,
    shipped_qty                 numeric,
    shipped_qty_selling_um      numeric,
    shipped_revenue             numeric,   -- SHIPPED headline measure
    actual_freight              numeric,
    shipping_weight             numeric,
    cogs_amount                 numeric,
    gross_margin_amount         numeric,
    cogs_material               numeric,
    cogs_labor                  numeric,
    cogs_burden                 numeric,
    cogs_service                numeric,
    inventory_trans_id          text,
    unit_price                  numeric,   -- non-additive
    trade_discount_pct          numeric,   -- non-additive
    commission_pct              numeric,   -- non-additive
    loaded_at                   timestamptz not null default now(),
    primary key (packlist_id, line_num)
);
alter table erp.fact_shipment_line enable row level security;
create index if not exists idx_fsl_customer on erp.fact_shipment_line (customer_key);
create index if not exists idx_fsl_ship_date on erp.fact_shipment_line (ship_date);

--------------------------------------------------------------------------
-- erp.fact_inventory_on_hand  ←  bi.vw_FactInventoryOnHand (grain: part x site)
--------------------------------------------------------------------------
create table if not exists erp.fact_inventory_on_hand (
    part_key                    text not null,
    site_key                    text not null,
    part_site_status            text,
    abc_code                    text,
    on_hand_qty                 numeric,
    qty_available_issue         numeric,
    qty_available_mrp           numeric,
    qty_on_order                numeric,
    qty_in_demand               numeric,
    qty_committed               numeric,
    annual_usage_qty            numeric,
    unit_material_cost          numeric,
    unit_labor_cost             numeric,
    unit_burden_cost            numeric,
    unit_service_cost           numeric,
    on_hand_value_material      numeric,
    on_hand_value_labor         numeric,
    on_hand_value_burden        numeric,
    on_hand_value_service       numeric,
    on_hand_value               numeric,
    standard_unit_cost          numeric,
    loaded_at                   timestamptz not null default now(),
    primary key (part_key, site_key)
);
alter table erp.fact_inventory_on_hand enable row level security;
