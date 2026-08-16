/*============================================================================
  036_account_sku_gaps.sql
  Purpose: Turn ATS from a catalog into "what should I be selling THIS dealer".

  The gap
  -------
  v_ats_list is a flat, territory-agnostic parts list. It has no idea which
  dealer the rep is standing in, and the account page never mentions
  availability at all. To answer "what should I put in this store today" a rep
  has to hold three screens in their head — what is in stock (ATS), what this
  dealer already buys (AccountSkuSalesCard), and what sells everywhere
  (GlobalIntel) — and do the cross-reference themselves, on a phone, in a shop.

  All three inputs already exist. This joins them once, in Postgres, and
  returns the answer:

      v_ats_list                  ats_qty > 0        in stock today
      v_sku_sales_by_account      exclude            what they already buy
      erp.fact_invoice_line       count(distinct)    how many dealers stock it

  ── Why SECURITY DEFINER, and how it is contained ──────────────────────────
  Dealer breadth is the whole point of the ranking: "14 available, stocked by
  61 dealers, this account has never bought one" is an argument a rep can make
  in a store. A COMPANY-WIDE dealer count is by definition a number no rep's
  RLS would return — the same reason report_global_product_sales is DEFINER
  (026/033).

  So this follows that function's contract exactly, plus one addition it does
  not need:

    1. It takes a customer_key, so it MUST prove the caller owns that account
       before returning anything. The first thing the body does is
       has_account_access(p_customer_key) — evaluated as the CALLER's access
       even inside a definer function, because has_account_access reads
       auth.uid(). Without that check this function would hand any rep any
       dealer's purchase history, which is PRD acceptance criterion #1
       failing completely.
    2. Output is part-grain, units-and-counts only. NEVER add customer keys or
       company-wide dollars — same standing rule as 033's header.

  The account's own side of the join (what they have bought) is genuinely
  theirs to see, and the guard above is what establishes that.

  ── One deliberate omission ────────────────────────────────────────────────
  This does not tell a rep WHEN an out-of-stock SKU comes back:
  v_ats_list.inbound_qty and next_avail_date are hardcoded NULL placeholders
  (027) because the upstream model does not certify inbound supply. Rather
  than imply we know, the function simply does not return unavailable SKUs.
  If inbound is ever certified upstream, that is the moment to add a
  "returning on" column here — not before.
============================================================================*/

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
    /* What we could ship today. */
    ats_qty            numeric,
    /* How many distinct dealers bought it company-wide in the window — the
       "everyone else stocks this" argument, and the ranking key. */
    dealer_count       int,
    /* Company-wide units in the window. Units only, never dollars. */
    units_sold         numeric,
    /* Has this account EVER bought it in the SKU view's window (4 years)?
       False is the headline case; true with a stale date is the "they used to
       carry this" case, which is a different and equally useful conversation. */
    bought_before      boolean,
    last_bought_date   date
)
language sql
stable
security definer
-- Hardening per 017: search_path pinned to '', body fully schema-qualified.
set search_path = ''
as $$
    with guard as (
        -- Evaluated as the CALLER despite SECURITY DEFINER: has_account_access
        -- resolves through auth.uid(). Everything below is gated on this
        -- returning true, so a rep passing someone else's customer_key gets
        -- an empty result rather than that dealer's buying history.
        select public.has_account_access(p_customer_key) as ok
    ),
    -- Company-wide breadth. This is the number that requires DEFINER.
    global as (
        select
            f.part_key,
            count(distinct f.customer_key)::int        as dealer_count,
            coalesce(sum(f.invoice_qty), 0)::numeric   as units_sold
        from erp.fact_invoice_line f, guard
        where guard.ok
          and f.is_memo is not true          -- NULL-safe; see 011 header
          and f.invoice_date is not null
          and f.invoice_date >= (date_trunc('month', current_date)
                                 - make_interval(months => greatest(1, least(coalesce(p_months, 12), 36))))::date
        group by f.part_key
    ),
    -- What this ACCOUNT has bought, over the SKU view's own 4-year window.
    mine as (
        select
            f.part_key,
            max(f.invoice_date) as last_bought_date
        from erp.fact_invoice_line f, guard
        where guard.ok
          and f.customer_key = p_customer_key
          and f.is_memo is not true
          and f.invoice_date is not null
          and f.invoice_date >= (date_trunc('year', current_date)
                                 - interval '3 years')::date
        group by f.part_key
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
    left join mine m         on m.part_key = a.part_key
    left join erp.dim_part p on p.part_key = a.part_key
    where a.available_to_sell_qty >= 1          -- sellable today; see 027
      and g.dealer_count >= greatest(1, coalesce(p_min_dealers, 4))
      -- Finished firearms only. Mirrors isGunRow() in useIntel.ts: component
      -- SKUs (OEM barrels) dominate raw units and would crowd out every gun.
      and coalesce(p.product_code, '') !~* 'component'
      and (
            coalesce(nullif(btrim(p.product_family), ''), 'N/A') <> 'N/A'
         or coalesce(nullif(btrim(p.chambering), ''), 'N/A')     <> 'N/A'
      )
    -- Never bought first, then by how many other dealers stock it. That is
    -- the order the rep would argue it in.
    order by (m.part_key is not null), g.dealer_count desc, g.units_sold desc
    limit greatest(1, least(coalesce(p_limit, 25), 100));
$$;

comment on function public.report_account_sku_gaps(text, int, int, int) is
  'SKUs available to ship today that this account does not buy, ranked by how '
  'many dealers company-wide do. SECURITY DEFINER because dealer breadth is a '
  'company-wide aggregate no rep''s RLS would return; gated on '
  'has_account_access(p_customer_key) as the FIRST thing it evaluates, so a '
  'rep cannot pass another rep''s account. Part-grain, units and counts only '
  '- never add customer keys or company-wide dollars (see 033).';

revoke execute on function public.report_account_sku_gaps(text, int, int, int)
  from public, anon;
grant execute on function public.report_account_sku_gaps(text, int, int, int)
  to authenticated;

--------------------------------------------------------------------------
-- Supporting index: the `mine` CTE filters one customer's invoice lines.
-- idx_fil_customer already covers customer_key; this pairs it with the date
-- so the 4-year window is a range scan rather than a filter over the whole
-- account history.
--------------------------------------------------------------------------
create index if not exists idx_fil_customer_date
  on erp.fact_invoice_line (customer_key, invoice_date);

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. RLS drill: rep A calling report_account_sku_gaps() with rep B's
     customer_key must get ZERO rows -- see supabase/tests/036_sku_gaps.sql.
     This is the assertion that matters; the function is DEFINER and the
     guard is the only thing standing in for RLS.
  2. If bi ever certifies inbound supply, revisit the "one deliberate
     omission" note in the header before adding a restock date.
----------------------------------------------------------------------------*/
