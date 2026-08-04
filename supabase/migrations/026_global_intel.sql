/*============================================================================
  026_global_intel.sql
  Purpose: Company-wide product intelligence for the reps — best sellers,
           top chamberings, family mix — WITHOUT exposing anyone else's
           accounts. Decided with the CEO: reps may see global AGGREGATES,
           never other reps' customer names or account-level detail.

  ── Why a SECURITY DEFINER function and not a view ─────────────────────────
  A security_invoker view cannot do this job: RLS strips other reps' rows,
  so a rep's "global" numbers would just be their territory again. An
  owner-rights VIEW over the fact table would work but is an always-on RLS
  bypass across the whole relation — anything joined to it later inherits
  the hole. A definer FUNCTION confines the bypass to one hand-audited
  query whose output shape structurally cannot leak account identity:
  part-grain aggregates plus a bare count of distinct accounts.

  THE RULE FOR FUTURE EDITS: this function may aggregate customer_key; it
  must NEVER return one, nor any column from dim_customer. If a future
  report needs account detail, it is not global — build it as a
  security_invoker view in 020's family instead.

  Hardening per 017: search_path pinned to '', body fully schema-qualified,
  EXECUTE stripped from public/anon.
============================================================================*/

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
    revenue          numeric,
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
      f.part_key,
      p.part_id,
      p.part_description,
      p.product_code,
      p.product_family,
      p.chambering,
      p.barrel_length,
      coalesce(sum(f.revenue), 0)::numeric        as revenue,
      coalesce(sum(f.invoice_qty), 0)::numeric    as qty,
      count(distinct f.invoice_id)::int           as invoice_count,
      -- A COUNT of accounts is safe; the keys themselves must never leave
      -- this function (see header).
      count(distinct f.customer_key)::int         as account_count
  from erp.fact_invoice_line f
  left join erp.dim_part p on p.part_key = f.part_key
  where f.is_memo is not true          -- NULL-safe; see 011 header
    and f.invoice_date is not null
    and f.invoice_date >= (date_trunc('month', current_date)
                           - make_interval(months => greatest(1, least(coalesce(p_months, 12), 36))))::date
  group by
      f.part_key, p.part_id, p.part_description, p.product_code,
      p.product_family, p.chambering, p.barrel_length
  order by coalesce(sum(f.revenue), 0) desc
  limit greatest(1, least(coalesce(p_limit, 500), 2000));
$$;

comment on function public.report_global_product_sales(int, int) is
  'Company-wide sales by SKU for the last p_months whole months (clamped '
  '1–36) plus the current partial month, top p_limit by revenue (clamped '
  '1–2000). SECURITY DEFINER on purpose: reps see global aggregates. '
  'Output is part-grain only — never add customer columns (see file header).';

-- Signed-in users only; anon has no business here.
revoke execute on function public.report_global_product_sales(int, int) from public, anon;
grant execute on function public.report_global_product_sales(int, int) to authenticated;
