/*============================================================================
  20260818000100_price_list_item_lookup.sql
  Purpose: price-list items describe themselves from the ERP part master.

  The CSV upload used to be the source of an item's description, which meant
  admins cramming family/caliber into free text and the portal having no way
  to filter by either. The part master (erp.dim_part) already publishes all
  of that nightly, keyed by the same human part_id the spreadsheets carry —
  so read it from there instead.

  public.v_price_list_items is what the app reads (the order writer's SKU
  picker, the admin items panel). Writes still go to price_list_items, and
  its description column stays as the FALLBACK for the one legitimate case
  the price-lists design calls out: a sheet can carry a new SKU before the
  ERP part master knows it. When dim_part has the part, its description and
  attributes win; when it doesn't, the uploaded text is all we have.

  part_id is unique in dim_part today (verified: 21,328 of 21,328 distinct),
  but nothing constrains it — dim_part is a nightly-replaced ERP mirror. The
  lateral `limit 1` keeps a future duplicate from fanning items out into
  duplicate picker rows, preferring a non-unknown live row.

  security_invoker per the 011 contract; both underlying tables are readable
  by every signed-in user (007 for dim_part, 20260817000100 for the items),
  so the view leaks nothing new.
============================================================================*/

-- Joins here (and the upload's advisory part check) hit dim_part by part_id,
-- which only had the part_key PK.
create index if not exists idx_dim_part_part_id on erp.dim_part (part_id);

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
  select dp.*
  from erp.dim_part dp
  where dp.part_id = i.part_id
  order by coalesce(dp.is_unknown_part, false), dp.part_key
  limit 1
) p on true;

revoke all on public.v_price_list_items from anon, public;
grant select on public.v_price_list_items to authenticated;

comment on view public.v_price_list_items is
  'Price-list items with the ERP part master looked up by part_id: '
  'description and family/caliber attributes come from erp.dim_part when the '
  'part is known (in_erp), falling back to the uploaded CSV description when '
  'it is not. What the order writer and admin items panel read.';
