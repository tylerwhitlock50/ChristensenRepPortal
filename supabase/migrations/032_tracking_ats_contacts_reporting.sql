/*============================================================================
  032_tracking_ats_contacts_reporting.sql

  Catch the erp landing tables up to the governed BI layer deployed to SQL
  Server on Aug 4–6 2026 (power-bi-model commits d9ba789, 994a90c, e21f641).
  The ETL COPYs every column the source view emits, so each new view column
  must exist here BEFORE the next load or the whole table's truncate+COPY
  fails — and a single failed table skips post_load_sql (rollups, signals,
  scores), which is exactly what happened on Aug 4 when bi.vw_FactATS turned
  out not to exist. Four changes:

  1. erp.dim_customer         + carms_customer_name and the three governed
                                CustomerReporting* hierarchy columns.
  2. erp.fact_shipment_line   + tracking_number (line-level UDF-0000028,
                                distinct from the header waybill_number).
                                v_account_recent_shipment_headers now prefers
                                it and falls back to waybill_number.
  3. erp.fact_available_to_sell  NEW landing table matching
                                bi.vw_FactAvailableToSell (grain: part+site).
                                Replaces erp.fact_ats, which was built for a
                                bi.vw_FactATS that was never created upstream
                                and has never held a row — dropped below.
                                public.v_ats_list is recreated on top with
                                its column contract preserved.
  4. erp.dim_customer_contact NEW landing table for bi.vw_DimCustomerContact,
                                plus public.v_account_contacts merging ERP
                                contacts with rep-entered public.contacts.
============================================================================*/

--------------------------------------------------------------------------
-- 1. dim_customer: governed reporting hierarchy
--------------------------------------------------------------------------
alter table erp.dim_customer
  add column if not exists carms_customer_name          text,
  add column if not exists customer_reporting_group     text,
  add column if not exists customer_reporting_sub_group text,
  add column if not exists customer_reporting_name      text;

--------------------------------------------------------------------------
-- 2. fact_shipment_line: line-level tracking number
--------------------------------------------------------------------------
alter table erp.fact_shipment_line
  add column if not exists tracking_number text;

-- Same view as 018, one change: tracking_number now prefers the line-level
-- UDF value and only falls back to the packlist header's waybill_number.
-- The source already NULLs blanks and the '0' placeholder.
create or replace view public.v_account_recent_shipment_headers
with (security_invoker = true)
as
select *
from (
    select
        h.*,
        row_number() over (
            partition by h.customer_key
            order by h.ship_date desc nulls last, h.packlist_id desc
        ) as rn
    from (
        select
            s.customer_key,
            s.packlist_id,
            max(s.ship_date)                                    as ship_date,
            max(s.actual_delivery_date)                         as actual_delivery_date,
            max(s.shipment_state)                               as shipment_state,
            max(s.shipper_status_desc)                          as shipper_status_desc,
            coalesce(max(s.tracking_number), max(s.waybill_number))
                                                                as tracking_number,
            max(s.ship_via)                                     as ship_via,
            -- A packlist almost always ships one order; distinct keeps the
            -- rare multi-order packlist readable instead of "51234, 51234…".
            string_agg(distinct s.order_id, ', ')               as order_ids,
            count(*)::int                                       as line_count,
            coalesce(sum(s.shipped_qty), 0)::numeric            as shipped_qty,
            coalesce(sum(s.shipped_revenue), 0)::numeric        as shipped_revenue
        from erp.fact_shipment_line s
        group by s.customer_key, s.packlist_id
    ) h
) r
where r.rn <= 20;

comment on view public.v_account_recent_shipment_headers is
  'Most recent 20 packlists per account at header grain. tracking_number is '
  'the line-level shipper UDF when present, else the header waybill_number. '
  'security_invoker. Always query with .eq(customer_key). Lines for one '
  'packlist come from v_account_shipment_lines.';

--------------------------------------------------------------------------
-- 3. ATS: land bi.vw_FactAvailableToSell, retire erp.fact_ats
--------------------------------------------------------------------------
-- v_ats_list depends on fact_ats; drop both, rebuild the view on the new
-- table below. fact_ats has never held a row (job_runs shows every load of
-- it failed on the missing source view), so no data is lost.
drop view if exists public.v_ats_list;
drop table if exists erp.fact_ats;

create table if not exists erp.fact_available_to_sell (
    part_key                               text not null,
    site_key                               text not null,
    -- Governed scope, constant across a snapshot (degenerate context)
    shippable_warehouse_id                 text,
    excluded_location_pattern              text,
    -- Physical stock in SHIPPING
    shipping_on_hand_before_exclusions_qty numeric,
    excluded_staging_qty                   numeric,
    shipping_on_hand_qty                   numeric,
    -- Open-order demand (the paired columns partition open_order_qty)
    open_order_qty                         numeric,
    allocated_open_order_qty               numeric,
    unallocated_open_order_qty             numeric,
    credit_approved_open_order_qty         numeric,
    credit_restricted_open_order_qty       numeric,
    demand_with_linked_supply_qty          numeric,
    demand_without_linked_supply_qty       numeric,
    linked_supply_allocated_qty            numeric,
    linked_supply_remaining_qty            numeric,
    open_order_line_count                  bigint,
    linked_supply_line_count               bigint,
    max_linked_supply_count                bigint,
    -- Headline measures — certified upstream, never re-derived here
    available_to_sell_qty                  numeric,
    available_to_sell_positive_qty         numeric,
    is_available_to_sell                   boolean,
    is_oversold                            boolean,
    availability_status                    text,
    loaded_at                              timestamptz not null default now(),
    primary key (part_key, site_key)
);
alter table erp.fact_available_to_sell enable row level security;

-- Product availability is not customer-scoped — same reasoning as dim_part:
-- every signed-in rep may see what the company can sell.
create policy "authenticated reads ats" on erp.fact_available_to_sell
  for select to authenticated using (true);

revoke all on erp.fact_available_to_sell from anon, public;
grant select on erp.fact_available_to_sell to authenticated;

comment on table erp.fact_available_to_sell is
  'ATS snapshot per (part, site), landed nightly from '
  'bi.vw_FactAvailableToSell — SHIPPING warehouse on hand (R10% staging '
  'excluded) minus open credit-approved-and-restricted order demand. All '
  'measures are certified upstream; never re-derive them here.';

-- Same column contract the AtsIntel page already reads. inbound_qty and
-- next_avail_date were designed for the never-built vw_FactATS feed; the
-- certified ATS model does not carry them, so they are NULL placeholders
-- until (if ever) the upstream model certifies inbound supply.
-- Single-site install: (part_key, site_key) is one row per part in practice.
create view public.v_ats_list
with (security_invoker = true)
as
select
    a.part_key,
    p.part_id,
    p.part_description,
    p.product_family,
    p.chambering,
    p.barrel_length,
    p.upc,
    a.shipping_on_hand_qty          as on_hand_qty,
    a.allocated_open_order_qty      as committed_qty,
    a.open_order_qty                as backlog_qty,
    null::numeric                   as inbound_qty,
    a.available_to_sell_qty         as ats_qty,
    null::date                      as next_avail_date,
    a.availability_status,
    a.is_oversold,
    a.loaded_at
from erp.fact_available_to_sell a
left join erp.dim_part p on p.part_key = a.part_key;

comment on view public.v_ats_list is
  'ATS list: per-part availability with catalog attributes, read from '
  'erp.fact_available_to_sell. on_hand = SHIPPING net of staging; committed '
  '= allocated open orders; backlog = all open order demand; ats = certified '
  'available-to-sell (signed, negatives = oversold). inbound_qty / '
  'next_avail_date are NULL until the upstream model certifies them. '
  'security_invoker; readable by all authenticated users.';

revoke all on public.v_ats_list from anon, public;
grant select on public.v_ats_list to authenticated;

--------------------------------------------------------------------------
-- 4. ERP customer contacts + merged read
--------------------------------------------------------------------------
create table if not exists erp.dim_customer_contact (
    customer_contact_key          text primary key,
    customer_key                  text not null,
    contact_id                    text,
    contact_number                int,
    primary_contact_flag          text,
    first_name                    text,
    last_name                     text,
    contact_name                  text,
    middle_name                   text,
    middle_initial                text,
    position                      text,
    salutation                    text,
    honorific                     text,
    country_dial_code             text,
    phone                         text,
    phone_extension               text,
    fax                           text,
    mobile                        text,
    email                         text,
    preferred_contact_method_code text,
    do_not_call_phone_flag        text,
    do_not_call_mobile_flag       text,
    do_not_email_flag             text,
    address1                      text,
    address2                      text,
    address3                      text,
    city                          text,
    state                         text,
    zip_code                      text,
    country                       text,
    contact_country_id            text,
    linkedin_url                  text,
    twitter_url                   text,
    facebook_url                  text,
    contact_active_flag           text,
    loaded_at                     timestamptz not null default now()
);
alter table erp.dim_customer_contact enable row level security;
create index if not exists idx_dcc_customer
  on erp.dim_customer_contact (customer_key);

-- Contact details are PII scoped to the account, so the read policy is the
-- book policy from 010 — same as dim_customer itself.
create policy "read own dim_customer_contact" on erp.dim_customer_contact
  for select to authenticated
  using ((select public.is_admin())
         or customer_key in (select public.my_customer_keys()));

revoke all on erp.dim_customer_contact from anon, public;
grant select on erp.dim_customer_contact to authenticated;

comment on table erp.dim_customer_contact is
  'ERP customer/contact assignments (bi.vw_DimCustomerContact), landed '
  'nightly. One row per (customer, contact) assignment; a contact can be '
  'assigned to several customers. Read-only in the CRM — rep-entered '
  'contacts live in public.contacts and the two are merged by '
  'public.v_account_contacts.';

-- The ContactsCard read: ERP system-of-record contacts alongside whatever
-- the reps have captured. contact_key is unique per row across both arms
-- (rep ids and ERP assignment keys cannot collide because of the prefix)
-- so the UI can key on it; id is non-null ONLY for rep rows, and only rep
-- rows are editable. security_invoker: each arm is filtered by its own RLS
-- (public.contacts by has_account_access, the ERP arm by the book policy
-- above), so the union leaks nothing either table would not.
create view public.v_account_contacts
with (security_invoker = true)
as
select
    'rep-' || c.id::text  as contact_key,
    'rep'::text           as source,
    c.id,
    c.customer_key,
    c.name,
    c.title,
    c.phone,
    c.email,
    c.is_primary,
    c.notes,
    c.updated_at
from public.contacts c
union all
select
    'erp-' || e.customer_contact_key,
    'erp',
    null::bigint,
    e.customer_key,
    coalesce(e.contact_name, e.contact_id),
    nullif(e.position, ''),
    coalesce(nullif(e.phone, ''), nullif(e.mobile, '')),
    nullif(e.email, ''),
    e.primary_contact_flag = 'Y',
    null::text,
    null::timestamptz
from erp.dim_customer_contact e
-- Source keeps inactive assignments; the CRM shows active people only.
where e.contact_active_flag = 'Y';

comment on view public.v_account_contacts is
  'Merged contacts for one account: rep-entered rows (source=rep, editable, '
  'id set) plus active ERP contacts (source=erp, read-only). Always query '
  'with .eq(customer_key). security_invoker — RLS of both source tables '
  'applies.';

revoke all on public.v_account_contacts from anon, public;
grant select on public.v_account_contacts to authenticated;
