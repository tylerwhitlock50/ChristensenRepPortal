/*============================================================================
  033_global_intel_units_only.sql
  Purpose: Strip dollars from the global report. Decision: reps may see
  company-wide UNITS and mix proportions, never company-level revenue.
  The 026 version of report_global_product_sales() returned a revenue
  column to every authenticated caller — even with the UI hiding it, the
  dollars rode along in the RPC payload. Redefine the function without it
  and rank by units instead.

  Same rules as 026 (see that header for the definer-function rationale):
  aggregates only, and the function must NEVER return a customer column.
  NEW RULE AS OF THIS FILE: it must never return a dollar column either —
  no revenue, amounts, or prices. Units, counts, and part attributes only.
  The structural guard in supabase/tests/024_intel_views.sql enforces both.

  DROP first: the OUT-column list is changing, which CREATE OR REPLACE
  cannot do.

  Hardening per 017: search_path pinned to '', body fully schema-qualified,
  EXECUTE stripped from public/anon.
============================================================================*/

drop function if exists public.report_global_product_sales(int, int);

create function public.report_global_product_sales(
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
      f.part_key,
      p.part_id,
      p.part_description,
      p.product_code,
      p.product_family,
      p.chambering,
      p.barrel_length,
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
  order by coalesce(sum(f.invoice_qty), 0) desc
  limit greatest(1, least(coalesce(p_limit, 500), 2000));
$$;

comment on function public.report_global_product_sales(int, int) is
  'Company-wide sales by SKU for the last p_months whole months (clamped '
  '1-36) plus the current partial month, top p_limit by units (clamped '
  '1-2000). SECURITY DEFINER on purpose: reps see global aggregates. '
  'Output is part-grain, units-and-counts only - never add customer or '
  'dollar columns (see file header).';

-- Signed-in users only; anon has no business here.
revoke execute on function public.report_global_product_sales(int, int) from public, anon;
grant execute on function public.report_global_product_sales(int, int) to authenticated;
