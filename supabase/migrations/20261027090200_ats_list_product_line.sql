/*============================================================================
  20261027090200_ats_list_product_line.sql — In stock gets a product line,
  and never shows a blank part number.

  Why
  ---
  Two things the Tableau rep list does that v_ats_list (032) cannot:

  - Filter by product line. Tableau's "Family" filter is the ERP part's
    PRODUCT_CODE (RIDGELINE, MESA FFT, FG-BARACT …), not the portal's
    product_family attribute. The In stock page needs it both for the
    "Product line" select (G13) and to hide barreled actions
    (product_code = 'FG-BARACT') under the "Guns only" default (G07).
  - Show every row with an id. Under the new cadence the ATS snapshot
    loads every 15 minutes and dim_part hourly, so a part created in VISUAL
    can be in stock before its catalog row lands; it rendered as a blank
    part number. part_key IS the VISUAL part id (part_key = part_id for all
    21,614 parts on 2026-10-26), so falling back to it is honest.

  What
  ----
  public.v_ats_list restated from LIVE (pg_get_viewdef, identical to
  032_tracking_ats_contacts_reporting.sql on 2026-10-26):
    part_id                   coalesce(p.part_id, a.part_key) — same name,
                              type and position; never null now
    product_code              NEW, appended: dim_part.product_code
    product_code_description  NEW, appended: dim_part.product_code_description
  Every other column verbatim. Both new columns are outside dim_part's
  revoked cost columns (20260901190300), so security_invoker reads work.
============================================================================*/

create or replace view public.v_ats_list
with (security_invoker = true)
as
select
    a.part_key,
    coalesce(p.part_id, a.part_key) as part_id,
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
    a.loaded_at,
    p.product_code,
    p.product_code_description
from erp.fact_available_to_sell a
left join erp.dim_part p on p.part_key = a.part_key;

comment on view public.v_ats_list is
  'ATS list: per-part availability with catalog attributes, read from '
  'erp.fact_available_to_sell. on_hand = SHIPPING net of staging; committed '
  '= allocated open orders; backlog = all open order demand; ats = certified '
  'available-to-sell (signed, negatives = oversold). inbound_qty / '
  'next_avail_date are NULL until the upstream model certifies them. '
  'part_id falls back to part_key when the part is not in dim_part; '
  'product_code (+ _description) is the ERP product line — Tableau''s '
  '"Family" (20261027090200). security_invoker; readable by all '
  'authenticated users.';

revoke all on public.v_ats_list from anon, public;
grant select on public.v_ats_list to authenticated;
