/*============================================================================
  027_ats.sql
  Purpose: Landing table + read view for the ATS (available-to-sell) list.

  The ERP is the system of record for the ATS calculation: bi.vw_FactATS
  computes AtsQty there (on hand minus commitments plus whatever policy the
  business certifies) and this side NEVER re-derives it — same rule as the
  certified measures in 002. fact_inventory_on_hand stays as-is; ATS is a
  distinct calculation, not a rename of qty_available_issue.

  Expected source view (Tyler builds in SQL Server), grain ONE ROW PER PART
  (single-site install — 002 deliberately landed no dim_site):

      bi.vw_FactATS:
        PartKey            varchar   join key to bi.vw_DimPart.PartKey
        OnHandQty          numeric   physical on hand
        CommittedQty       numeric   allocated/committed to orders
        BacklogQty         numeric   open customer demand
        InboundQty         numeric   open POs / WOs due in
        AtsQty             numeric   THE certified ATS number
        NextAvailDateKey   int       yyyymmdd; sentinel 19000101 = null

  Column names use AtsQty (not ATSQty) so the ETL's naive PascalCase
  splitter lands them without a column_map entry. The generated
  next_avail_date column must be EXCLUDED from the ETL column list
  (etl/views.yml documents this pattern).

  SEQUENCING: apply this migration to prod BEFORE the views.yml entry
  deploys — the truncate+COPY load fails on a missing table.
============================================================================*/

create table if not exists erp.fact_ats (
    part_key            text primary key,
    on_hand_qty         numeric,
    committed_qty       numeric,
    backlog_qty         numeric,
    inbound_qty         numeric,
    ats_qty             numeric,
    next_avail_date_key int,
    next_avail_date     date generated always as (erp.key_to_date(next_avail_date_key)) stored,
    loaded_at           timestamptz not null default now()
);
alter table erp.fact_ats enable row level security;

-- Product availability is not customer-scoped — same reasoning as
-- dim_part: every signed-in rep may see what the company can sell.
create policy "authenticated reads ats" on erp.fact_ats
  for select to authenticated using (true);

revoke all on erp.fact_ats from anon, public;
grant select on erp.fact_ats to authenticated;

comment on table erp.fact_ats is
  'ATS (available-to-sell) per part, computed in the ERP (bi.vw_FactATS) '
  'and landed by the ETL. One row per part; sites collapsed upstream. '
  'ats_qty is certified upstream — never re-derive it here.';

--------------------------------------------------------------------------
-- v_ats_list — the Sales Intel ATS page: fact + part attributes in one
-- round trip. security_invoker per the 011 contract (both sources are
-- readable by all authenticated users anyway, but the contract is the
-- contract).
--------------------------------------------------------------------------
create or replace view public.v_ats_list
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
    a.on_hand_qty,
    a.committed_qty,
    a.backlog_qty,
    a.inbound_qty,
    a.ats_qty,
    a.next_avail_date,
    a.loaded_at
from erp.fact_ats a
left join erp.dim_part p on p.part_key = a.part_key;

comment on view public.v_ats_list is
  'ATS list: per-part availability with catalog attributes. '
  'security_invoker; readable by all authenticated users.';

revoke all on public.v_ats_list from anon, public;
grant select on public.v_ats_list to authenticated;
