import { computed, unref, type MaybeRef } from 'vue'
import { keepPreviousData, useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/fetchAll'
import { qk } from '@/lib/queryClient'
import { isViewMissing } from '@/composables/useOverview'

/**
 * The Sales Intel read path (migrations 025–027).
 *
 * Territory-wide queries are UNFILTERED on purpose — RLS is the territory
 * filter (020 header). The per-account SKU/backlog queries carry .eq and are
 * keyed under qk.account.* so the account page's invalidation sweep covers
 * them. Global numbers come from the report_global_product_sales() RPC —
 * SECURITY DEFINER, aggregates only (021).
 */

/** Views land after database.types.ts was last generated — same untyped-handle
 *  convention as useAccountMetrics.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

function asDisplayError(error: unknown, _migration: string): unknown {
  if (isViewMissing(error)) {
    return Object.assign(
      // The text is shown to reps, so it does not name the file. For whoever
      // is fixing it: the missing view comes from supabase/migrations/<migration>.
      new Error(
        'This report is not set up yet. Ask an admin, then reload.',
      ),
      { code: 'PGRST205' },
    )
  }
  return error
}

function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isViewMissing(error) && failureCount < 1
}

import { ATS_STALE_TIME, ERP_STALE_TIME } from '@/lib/queryClient' // the load-driven cache policy

/* ------------------------------------------------------------- SKU sales */

export interface SkuYearRow {
  customer_key?: string
  part_key: string
  part_id: string | null
  part_description: string | null
  product_family: string | null
  /**
   * dim_part.product_code — the ERP product line ("Family" in Tableau,
   * "Product line" here). Null on a database without 20261027090500: the
   * read is select('*'), so a missing column just leaves this empty and the
   * page hides the filter.
   */
  product_code: string | null
  chambering: string | null
  upc: string | null
  sales_year: number
  revenue: number
  qty: number
  invoice_count: number
  last_invoice_date: string | null
}

function mapSkuRow(r: Record<string, unknown>): SkuYearRow {
  return {
    customer_key: r.customer_key ? String(r.customer_key) : undefined,
    part_key: String(r.part_key),
    part_id: (r.part_id as string | null) ?? null,
    part_description: (r.part_description as string | null) ?? null,
    product_family: (r.product_family as string | null) ?? null,
    product_code: (r.product_code as string | null) ?? null,
    chambering: (r.chambering as string | null) ?? null,
    upc: (r.upc as string | null) ?? null,
    sales_year: num(r.sales_year),
    revenue: num(r.revenue),
    qty: num(r.qty),
    invoice_count: num(r.invoice_count),
    last_invoice_date: (r.last_invoice_date as string | null) ?? null,
  }
}

/** SKU × year across the caller's whole book. */
export function useTerritorySkuSales() {
  return useQuery({
    queryKey: qk.intel.territorySku(),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<SkuYearRow[]> => {
      // SKU × year over the whole book blows past PostgREST's 1,000-row cap
      // for a large territory or an admin — page it. (part_key, sales_year)
      // is the view's grain, so ordering by both is a total order.
      try {
        const data = await fetchAllRows<Record<string, unknown>>((from, to) =>
          db
            .from('v_territory_sku_sales')
            .select('*', { count: 'exact' }) // unfiltered on purpose — RLS is the territory filter
            .order('part_key')
            .order('sales_year')
            .range(from, to),
        )
        return data.map(mapSkuRow)
      } catch (error) {
        throw asDisplayError(error, '025_intel_views.sql')
      }
    },
  })
}

/** SKU × year for ONE account. The .eq is required — see 020. */
export function useSkuSalesByAccount(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.skuSales(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<SkuYearRow[]> => {
      // A big dealer's SKU × year history exceeds PostgREST's 1,000-row cap
      // (the largest: 1,692 rows) — unpaged, the grid AND the header totals were
      // silently truncated. (part_key, sales_year) is the view's grain per
      // customer, so ordering by both is a total order.
      try {
        const data = await fetchAllRows<Record<string, unknown>>((from, to) =>
          db
            .from('v_sku_sales_by_account')
            .select('*', { count: 'exact' })
            .eq('customer_key', key.value) // required — see 020's header
            .order('part_key')
            .order('sales_year')
            .range(from, to),
        )
        return data.map(mapSkuRow)
      } catch (error) {
        throw asDisplayError(error, '025_intel_views.sql')
      }
    },
  })
}

/* One grid row per SKU, years pivoted into columns. */
export interface SkuPivotRow {
  part_key: string
  part_id: string | null
  part_description: string | null
  product_family: string | null
  product_code: string | null
  chambering: string | null
  upc: string | null
  /** qty / revenue by calendar year, newest years first in `years`. */
  byYear: Record<number, { qty: number; revenue: number }>
  qtyThisYear: number
  revenueThisYear: number
  qtyLastYear: number
  revenueLastYear: number
  lastInvoiceDate: string | null
}

/**
 * (SKU × year) rows → one row per SKU with This Year / LY / older columns.
 * Pure and exported for unit tests; the grid and the CSV export both use it.
 */
export function pivotSkuYears(
  rows: SkuYearRow[],
  currentYear: number = new Date().getFullYear(),
): SkuPivotRow[] {
  const byPart = new Map<string, SkuPivotRow>()
  for (const r of rows) {
    let p = byPart.get(r.part_key)
    if (!p) {
      p = {
        part_key: r.part_key,
        part_id: r.part_id,
        part_description: r.part_description,
        product_family: r.product_family,
        product_code: r.product_code,
        chambering: r.chambering,
        upc: r.upc,
        byYear: {},
        qtyThisYear: 0,
        revenueThisYear: 0,
        qtyLastYear: 0,
        revenueLastYear: 0,
        lastInvoiceDate: null,
      }
      byPart.set(r.part_key, p)
    }
    const y = p.byYear[r.sales_year] ?? { qty: 0, revenue: 0 }
    y.qty += r.qty
    y.revenue += r.revenue
    p.byYear[r.sales_year] = y
    if (r.sales_year === currentYear) {
      p.qtyThisYear = y.qty
      p.revenueThisYear = y.revenue
    } else if (r.sales_year === currentYear - 1) {
      p.qtyLastYear = y.qty
      p.revenueLastYear = y.revenue
    }
    if (
      r.last_invoice_date &&
      (!p.lastInvoiceDate || r.last_invoice_date > p.lastInvoiceDate)
    ) {
      p.lastInvoiceDate = r.last_invoice_date
    }
  }
  return [...byPart.values()].sort(
    (a, b) => b.revenueThisYear - a.revenueThisYear || b.revenueLastYear - a.revenueLastYear,
  )
}

/* -------------------------------------------------------- sales by family */

/**
 * What a "family" row groups by. The portal has two near-twin attributes and
 * people mean either one when they say family:
 *
 *   'family'  dim_part.product_family, through stockCategory(): the In stock
 *             page's sections and the AI brief's product mix. Guns by family;
 *             barreled actions, and components & accessories, as one row each.
 *   'line'    dim_part.product_code, the ERP product line ("Family" in
 *             Tableau): RIDGELINE FFT, MESA FFT, FG-COMP… Every part has one.
 */
export type FamilyGrouping = 'family' | 'line'

export const FAMILY_GROUPING_LABEL: Record<FamilyGrouping, string> = {
  family: 'Family',
  line: 'Product line',
}

/** The row a part with no product code sits under, in 'line' grouping. */
export const NO_PRODUCT_LINE = 'No product line'

/** The group one sold SKU belongs to. Pure, unit-testable. */
export function salesGroupOf(
  r: Pick<SkuPivotRow, 'product_code' | 'product_family' | 'chambering'>,
  by: FamilyGrouping,
): string {
  if (by === 'line') return (r.product_code ?? '').trim().toUpperCase() || NO_PRODUCT_LINE
  return stockCategory(r)
}

/** One family (or product line): its SKUs and what they add up to. */
export interface FamilySalesRow {
  /** The group's name, as shown — and its identity within one roll-up. */
  key: string
  /** Its SKUs, top sellers first (pivotSkuYears' order). */
  skus: SkuPivotRow[]
  skuCount: number
  qtyThisYear: number
  revenueThisYear: number
  qtyLastYear: number
  revenueLastYear: number
  /**
   * Share of the year's revenue, 0–1; null when nothing was sold that year.
   * A share of the POSITIVE revenue: a family that nets out to a credit
   * counts as 0 rather than making every other share add up past 100%.
   */
  shareThisYear: number | null
  shareLastYear: number | null
  lastInvoiceDate: string | null
}

/**
 * Pivoted SKU rows → one row per family, biggest this year first (then last
 * year, then name). Only SKUs with anything invoiced this year or last are
 * counted: the view reaches back four years, and a family last bought in
 * 2023 is not part of "this year against last". A family's row is exactly
 * the sum of the SKUs under it, so drilling in never disagrees with it.
 * Pure and exported for unit tests.
 */
export function rollupFamilySales(
  pivoted: readonly SkuPivotRow[],
  by: FamilyGrouping = 'family',
): FamilySalesRow[] {
  const byKey = new Map<string, FamilySalesRow>()
  for (const p of pivoted) {
    if (!p.qtyThisYear && !p.revenueThisYear && !p.qtyLastYear && !p.revenueLastYear) continue
    const key = salesGroupOf(p, by)
    let f = byKey.get(key)
    if (!f) {
      f = {
        key,
        skus: [],
        skuCount: 0,
        qtyThisYear: 0,
        revenueThisYear: 0,
        qtyLastYear: 0,
        revenueLastYear: 0,
        shareThisYear: null,
        shareLastYear: null,
        lastInvoiceDate: null,
      }
      byKey.set(key, f)
    }
    f.skus.push(p)
    f.skuCount++
    f.qtyThisYear += p.qtyThisYear
    f.revenueThisYear += p.revenueThisYear
    f.qtyLastYear += p.qtyLastYear
    f.revenueLastYear += p.revenueLastYear
    if (p.lastInvoiceDate && (!f.lastInvoiceDate || p.lastInvoiceDate > f.lastInvoiceDate)) {
      f.lastInvoiceDate = p.lastInvoiceDate
    }
  }
  const rows = [...byKey.values()]
  const positive = (pick: (f: FamilySalesRow) => number) =>
    rows.reduce((sum, f) => sum + Math.max(0, pick(f)), 0)
  const wholeThis = positive((f) => f.revenueThisYear)
  const wholeLast = positive((f) => f.revenueLastYear)
  for (const f of rows) {
    f.shareThisYear = wholeThis > 0 ? Math.max(0, f.revenueThisYear) / wholeThis : null
    f.shareLastYear = wholeLast > 0 ? Math.max(0, f.revenueLastYear) / wholeLast : null
  }
  return rows.sort(
    (a, b) =>
      b.revenueThisYear - a.revenueThisYear ||
      b.revenueLastYear - a.revenueLastYear ||
      a.key.localeCompare(b.key),
  )
}

/* ---- the mix bars -------------------------------------------------------- */

/** Families that get a colour of their own; the rest share "Other". */
export const MIX_MAX_SLOTS = 5
/** The slot "Other" draws in (components/FamilyMixBars.vue: the gray). */
export const MIX_OTHER_SLOT = -1

/**
 * Which colour slot each family draws in: the first MIX_MAX_SLOTS families of
 * the roll-up (this year's biggest; last year's when nothing sold this year)
 * that sold anything, in that order. Everything else is MIX_OTHER_SLOT. One
 * map feeds both years' bars and the list's swatches, so a family is the
 * same colour everywhere on the card. Pure, unit-testable.
 */
export function mixSlots(
  families: readonly FamilySalesRow[],
  max: number = MIX_MAX_SLOTS,
): Map<string, number> {
  const slots = new Map<string, number>()
  let next = 0
  for (const f of families) {
    const sold = f.revenueThisYear > 0 || f.revenueLastYear > 0
    slots.set(f.key, sold && next < max ? next++ : MIX_OTHER_SLOT)
  }
  return slots
}

export interface MixSegment {
  /** The family's key, or '' for "Other" when it folds several. */
  key: string
  label: string
  slot: number
  revenue: number
  /** 0–1 of the bar. */
  share: number
  /** How many families the segment stands for (1 unless it is "Other"). */
  families: number
}

export interface MixBar {
  /** Net revenue for the year: the figure printed beside the bar. */
  total: number
  /** Left to right: the slots in order, then "Other". Zero-width parts left out. */
  segments: MixSegment[]
}

/**
 * One year's mix as bar segments. Segments keep slot order in BOTH years (not
 * each year's own ranking), so a family sits in the same place in the two
 * bars and the eye compares widths, not positions. "Other" folding a single
 * family is named for it. Pure, unit-testable.
 */
export function mixBar(
  families: readonly FamilySalesRow[],
  slots: ReadonlyMap<string, number>,
  year: 'this' | 'last',
): MixBar {
  const revenueOf = (f: FamilySalesRow) => (year === 'this' ? f.revenueThisYear : f.revenueLastYear)
  const shareOf = (f: FamilySalesRow) => (year === 'this' ? f.shareThisYear : f.shareLastYear) ?? 0
  const total = families.reduce((sum, f) => sum + revenueOf(f), 0)

  const named: MixSegment[] = []
  const other: FamilySalesRow[] = []
  for (const f of families) {
    const slot = slots.get(f.key) ?? MIX_OTHER_SLOT
    if (slot === MIX_OTHER_SLOT) {
      if (shareOf(f) > 0) other.push(f)
    } else if (shareOf(f) > 0) {
      named.push({ key: f.key, label: f.key, slot, revenue: revenueOf(f), share: shareOf(f), families: 1 })
    }
  }
  named.sort((a, b) => a.slot - b.slot)
  if (other.length) {
    named.push({
      key: other.length === 1 ? other[0]!.key : '',
      label: other.length === 1 ? other[0]!.key : 'Other',
      slot: MIX_OTHER_SLOT,
      revenue: other.reduce((sum, f) => sum + revenueOf(f), 0),
      share: other.reduce((sum, f) => sum + shareOf(f), 0),
      families: other.length,
    })
  }
  return { total, segments: named }
}

/* ---- the whole book, by account ------------------------------------------ */

/**
 * Account × SKU × year across the caller's whole book, from `sinceYear` on —
 * what the Accounts table's "by family / by SKU" download is built from.
 *
 * Unfiltered on purpose, like v_territory_sku_sales: RLS on erp.agg_sku_year
 * is the territory filter. The view's comment says to query it with
 * .eq(customer_key); that is advice for the account page (one account, no
 * reason to read the book), not a limit. This is the one caller that wants
 * every account at once.
 *
 * Whole book rather than "the accounts on screen": the table's search and
 * Rep filter then narrow rows already in memory, so a manager pulling one
 * file per rep pays for the read once. A rep's book is a few thousand rows;
 * an admin's is ~30k (31 windows of 1,000, four at a time). Only fetched
 * once a detail level is picked.
 */
export function useBookSkuSales(
  enabled: MaybeRef<boolean>,
  sinceYear: number = new Date().getFullYear() - 1,
) {
  return useQuery({
    queryKey: qk.intel.bookSku(sinceYear),
    enabled: computed(() => !!unref(enabled)),
    // The Accounts table's own freshness (useAccountTable): the file is that
    // table with more rows.
    staleTime: 10 * 60_000,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<SkuYearRow[]> => {
      try {
        const data = await fetchAllRows<Record<string, unknown>>((from, to) =>
          db
            .from('v_sku_sales_by_account')
            // Explicit columns: over ~30k rows every stray one is payload.
            .select(
              'customer_key, part_key, part_id, part_description, product_family, ' +
                'product_code, chambering, upc, sales_year, revenue, qty, ' +
                'invoice_count, last_invoice_date',
              { count: 'exact' },
            )
            .gte('sales_year', sinceYear)
            // The rollup's primary key, so the order is total and index-backed.
            .order('customer_key')
            .order('part_key')
            .order('sales_year')
            .range(from, to)
            // Same assertion as useAccountTable: an explicit column list
            // defeats supabase-js's select() parsing on this untyped handle.
            .returns<Record<string, unknown>[]>(),
        )
        return data.map(mapSkuRow)
      } catch (error) {
        throw asDisplayError(error, '025_intel_views.sql')
      }
    },
  })
}

/** The account columns a detail row repeats (AccountTableRow has them all). */
export interface AccountIdentity {
  customer_key: string
  customer_name: string | null
  sold_to_city: string | null
  sold_to_state: string | null
  assigned_sales_rep_name: string | null
}

/**
 * `family` is the row's family as the by-family file names it (stockCategory:
 * "Components & accessories", "Barreled actions"…), not the raw catalog
 * field, so summing the by-SKU file on it reproduces the by-family file.
 */
export type AccountSkuDetailRow = AccountIdentity & SkuPivotRow & { family: string }
export type AccountFamilyDetailRow = AccountIdentity & Omit<FamilySalesRow, 'skus'>

function identityOf(a: AccountIdentity): AccountIdentity {
  return {
    customer_key: a.customer_key,
    customer_name: a.customer_name,
    sold_to_city: a.sold_to_city,
    sold_to_state: a.sold_to_state,
    assigned_sales_rep_name: a.assigned_sales_rep_name,
  }
}

/** Book rows → each account's SKUs, pivoted. */
function pivotByAccount(
  rows: readonly SkuYearRow[],
  currentYear: number,
): Map<string, SkuPivotRow[]> {
  const byAccount = new Map<string, SkuYearRow[]>()
  for (const r of rows) {
    if (!r.customer_key) continue
    const list = byAccount.get(r.customer_key)
    if (list) list.push(r)
    else byAccount.set(r.customer_key, [r])
  }
  const out = new Map<string, SkuPivotRow[]>()
  for (const [key, list] of byAccount) out.set(key, pivotSkuYears(list, currentYear))
  return out
}

/**
 * One row per account × SKU, for exactly the accounts given and in their
 * order (the table's rows on screen). Inside an account the rows run family
 * by family — biggest family first, its top sellers first — so the flat file
 * already reads account → family → SKU before anyone sorts or pivots it. An
 * account with nothing invoiced in the window has no rows. Pure, unit-testable.
 */
export function accountSkuDetail(
  accounts: readonly AccountIdentity[],
  rows: readonly SkuYearRow[],
  currentYear: number = new Date().getFullYear(),
): AccountSkuDetailRow[] {
  const pivots = pivotByAccount(rows, currentYear)
  const out: AccountSkuDetailRow[] = []
  for (const a of accounts) {
    const identity = identityOf(a)
    for (const f of rollupFamilySales(pivots.get(a.customer_key) ?? [], 'family')) {
      for (const p of f.skus) out.push({ ...identity, ...p, family: f.key })
    }
  }
  return out
}

/** One row per account × family (or product line); same rules as above. */
export function accountFamilyDetail(
  accounts: readonly AccountIdentity[],
  rows: readonly SkuYearRow[],
  by: FamilyGrouping,
  currentYear: number = new Date().getFullYear(),
): AccountFamilyDetailRow[] {
  const pivots = pivotByAccount(rows, currentYear)
  const out: AccountFamilyDetailRow[] = []
  for (const a of accounts) {
    const identity = identityOf(a)
    for (const f of rollupFamilySales(pivots.get(a.customer_key) ?? [], by)) {
      const { skus: _skus, ...totals } = f
      out.push({ ...identity, ...totals })
    }
  }
  return out
}

/* --------------------------------------------------------------- backlog */

export interface BacklogSkuRow {
  customer_key: string
  customer_id: string | null
  customer_name: string | null
  part_key: string
  part_id: string | null
  part_description: string | null
  product_family: string | null
  /** dim_part.product_code (20261027090500); null before that migration. */
  product_code: string | null
  chambering: string | null
  backlog_qty: number
  backlog_amount: number
  open_line_count: number
  earliest_promise_date: string | null
  /** min(desired_ship_date) — shown to reps as "estimated production date". */
  earliest_desired_ship_date: string | null
  latest_order_date: string | null
  /** The account's assigned rep (20261026180000) — who the store belongs to.
   *  Null on a database without that migration. */
  assigned_sales_rep_id: string | null
  assigned_sales_rep_name: string | null
}

function mapBacklogRow(r: Record<string, unknown>): BacklogSkuRow {
  return {
    customer_key: String(r.customer_key),
    customer_id: (r.customer_id as string | null) ?? null,
    customer_name: (r.customer_name as string | null) ?? null,
    part_key: String(r.part_key),
    part_id: (r.part_id as string | null) ?? null,
    part_description: (r.part_description as string | null) ?? null,
    product_family: (r.product_family as string | null) ?? null,
    product_code: (r.product_code as string | null) ?? null,
    chambering: (r.chambering as string | null) ?? null,
    backlog_qty: num(r.backlog_qty),
    backlog_amount: num(r.backlog_amount),
    open_line_count: num(r.open_line_count),
    earliest_promise_date: (r.earliest_promise_date as string | null) ?? null,
    earliest_desired_ship_date:
      (r.earliest_desired_ship_date as string | null) ?? null,
    latest_order_date: (r.latest_order_date as string | null) ?? null,
    assigned_sales_rep_id: (r.assigned_sales_rep_id as string | null) ?? null,
    assigned_sales_rep_name: (r.assigned_sales_rep_name as string | null) ?? null,
  }
}

/** Every open backlog line in the caller's book, rolled up to account × SKU. */
export function useTerritoryBacklog() {
  return useQuery({
    queryKey: qk.intel.backlog(),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<BacklogSkuRow[]> => {
      // Account × SKU across the territory can exceed the 1,000-row cap.
      // The (customer_key, part_key) tiebreakers make the sort total so
      // pages never overlap on equal backlog amounts.
      try {
        const data = await fetchAllRows<Record<string, unknown>>((from, to) =>
          db
            .from('v_backlog_by_sku')
            .select('*', { count: 'exact' }) // unfiltered on purpose — RLS is the territory filter
            .order('backlog_amount', { ascending: false })
            .order('customer_key')
            .order('part_key')
            .range(from, to),
        )
        return data.map(mapBacklogRow)
      } catch (error) {
        throw asDisplayError(error, '025_intel_views.sql')
      }
    },
  })
}

/** One account's backlog by SKU, for the account page card. */
export function useAccountBacklog(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.backlogSku(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<BacklogSkuRow[]> => {
      const { data, error } = await db
        .from('v_backlog_by_sku')
        .select('*')
        .eq('customer_key', key.value)
        // Oldest promise first — rep feedback: the card is "what's overdue",
        // and the line the dealer is angriest about is the oldest one. No
        // promise date sorts last; dollars break ties.
        .order('earliest_promise_date', { ascending: true, nullsFirst: false })
        .order('backlog_amount', { ascending: false })
      if (error) throw asDisplayError(error, '025_intel_views.sql')
      return ((data ?? []) as Record<string, unknown>[]).map(mapBacklogRow)
    },
  })
}

/* ------------------------------------------------------------------- ATS */

export interface AtsRow {
  part_key: string
  part_id: string | null
  part_description: string | null
  product_family: string | null
  /**
   * dim_part.product_code and its description (20261027090200). Null on a
   * database without that migration — select('*') — which hides the
   * Product line filter and leaves "Guns only" to the spec test alone.
   */
  product_code: string | null
  product_code_description: string | null
  chambering: string | null
  barrel_length: string | null
  upc: string | null
  on_hand_qty: number
  committed_qty: number
  backlog_qty: number
  inbound_qty: number
  ats_qty: number
  next_avail_date: string | null
  loaded_at: string | null
}

/**
 * The ATS list. isAtsFeedMissing distinguishes "migration 022 not applied /
 * ERP feed not landed yet" so the page can say so instead of erroring.
 */
export function useAtsList() {
  return useQuery({
    queryKey: qk.intel.ats(),
    // One stock load, not the ERP's hours: this list reloads every 15
    // minutes, and the heartbeat's stock stamp (atsStamp) refreshes it
    // sooner when a load lands.
    staleTime: ATS_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AtsRow[]> => {
      // One row per part, but a full catalog can top 1,000 SKUs — page it.
      let data: Record<string, unknown>[]
      try {
        data = await fetchAllRows<Record<string, unknown>>((from, to) =>
          db
            .from('v_ats_list')
            .select('*', { count: 'exact' })
            .order('ats_qty', { ascending: false })
            .order('part_key')
            .range(from, to),
        )
      } catch (error) {
        throw asDisplayError(error, '027_ats.sql')
      }
      return data.map((r) => ({
        part_key: String(r.part_key),
        part_id: (r.part_id as string | null) ?? null,
        part_description: (r.part_description as string | null) ?? null,
        product_family: (r.product_family as string | null) ?? null,
        product_code: (r.product_code as string | null) ?? null,
        product_code_description: (r.product_code_description as string | null) ?? null,
        chambering: (r.chambering as string | null) ?? null,
        barrel_length: (r.barrel_length as string | null) ?? null,
        upc: (r.upc as string | null) ?? null,
        on_hand_qty: num(r.on_hand_qty),
        committed_qty: num(r.committed_qty),
        backlog_qty: num(r.backlog_qty),
        inbound_qty: num(r.inbound_qty),
        ats_qty: num(r.ats_qty),
        next_avail_date: (r.next_avail_date as string | null) ?? null,
        loaded_at: (r.loaded_at as string | null) ?? null,
      }))
    },
  })
}

/* ---------------------------------------------------------------- global */

export interface GlobalSkuRow {
  part_key: string
  part_id: string | null
  part_description: string | null
  product_code: string | null
  product_family: string | null
  chambering: string | null
  barrel_length: string | null
  qty: number
  invoice_count: number
  account_count: number
}

/**
 * Company-wide best sellers via the definer RPC — aggregates only, and
 * units only: 033 stripped revenue from the function so reps never receive
 * company-level dollars, even in the payload.
 */
export function useGlobalProductSales(months: MaybeRef<number>) {
  const m = computed(() => unref(months))
  return useQuery({
    queryKey: computed(() => qk.intel.global(m.value)),
    staleTime: ERP_STALE_TIME,
    // A new window is a new key; keep the old rows up while it loads so the
    // grid stays mounted and keeps the user's column sort.
    placeholderData: keepPreviousData,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<GlobalSkuRow[]> => {
      // Ask for the function's max: ranking is by raw units, where component
      // parts dominate — a small limit would crowd gun SKUs out of the page
      // before the guns-only filter ever sees them.
      const { data, error } = await db.rpc('report_global_product_sales', {
        p_months: m.value,
        p_limit: 2000,
      })
      if (error) throw asDisplayError(error, '033_global_intel_units_only.sql')
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        part_key: String(r.part_key),
        part_id: (r.part_id as string | null) ?? null,
        part_description: (r.part_description as string | null) ?? null,
        product_code: (r.product_code as string | null) ?? null,
        product_family: (r.product_family as string | null) ?? null,
        chambering: (r.chambering as string | null) ?? null,
        barrel_length: (r.barrel_length as string | null) ?? null,
        qty: num(r.qty),
        invoice_count: num(r.invoice_count),
        account_count: num(r.account_count),
      }))
    },
  })
}

/** ERP product code that marks component parts (OEM barrels etc.), not
 *  finished firearms. Substring match — the ERP is free-form here. */
const COMPONENT_PRODUCT_CODE = /component/i

/** True when the spec field carries a real value — dim_part uses blank or
 *  the literal string 'N/A' on parts the spec doesn't apply to. */
function hasSpec(value: string | null): boolean {
  const v = (value ?? '').trim()
  return v !== '' && v.toUpperCase() !== 'N/A'
}

/**
 * True when a global row looks like a finished firearm. Two-layer test:
 * the component product code is out by name, and everything else must carry
 * at least one firearm spec attribute — components and non-gun SKUs land
 * with family and chambering blank/'N/A' (see vw_DimPart: Z_PRODUCT_DETAIL
 * only specs finished goods). Pure, unit-testable.
 */
export function isGunRow(
  r: Pick<GlobalSkuRow, 'product_code' | 'product_family' | 'chambering'>,
): boolean {
  if (r.product_code && COMPONENT_PRODUCT_CODE.test(r.product_code)) return false
  return hasSpec(r.product_family) || hasSpec(r.chambering)
}

/** Barreled actions: finished goods with a chambering, so isGunRow keeps
 *  them, but not a gun a dealer puts on the rack (G07). */
export const BARRELED_ACTION_PRODUCT_CODE = 'FG-BARACT'

/**
 * The In stock page's "Guns only": isGunRow, minus barreled actions. The
 * product-code half only bites once v_ats_list carries product_code
 * (20261027090200); before that a null code passes and the spec test alone
 * decides, exactly as isGunRow does. Pure, unit-testable.
 */
export function isGunStockRow(
  r: Pick<AtsRow, 'product_code' | 'product_family' | 'chambering'>,
): boolean {
  if ((r.product_code ?? '').trim().toUpperCase() === BARRELED_ACTION_PRODUCT_CODE) return false
  return isGunRow(r)
}

/** The In stock page's last two sections: what is not a gun on the rack. */
export const STOCK_CATEGORY_BARRELED = 'Barreled actions'
export const STOCK_CATEGORY_COMPONENTS = 'Components & accessories'

/**
 * The section a stock row sits under when the In stock list is split by
 * category: a gun's product family (EVOKE, RIDGELINE FLASH FORGED
 * TECHNOLOGY…), barreled actions on their own, and everything else — parts,
 * accessories, components — together. Same gun test as "Guns only"
 * (isGunStockRow), so the two can never disagree. Pure, unit-testable.
 */
export function stockCategory(
  r: Pick<AtsRow, 'product_code' | 'product_family' | 'chambering'>,
): string {
  if ((r.product_code ?? '').trim().toUpperCase() === BARRELED_ACTION_PRODUCT_CODE) {
    return STOCK_CATEGORY_BARRELED
  }
  if (!isGunRow(r)) return STOCK_CATEGORY_COMPONENTS
  const family = (r.product_family ?? '').trim()
  return family && family.toUpperCase() !== 'N/A' ? family.toUpperCase() : 'Other guns'
}

/** Gun families by name, then barreled actions, then components last. */
export function compareStockCategories(a: string, b: string): number {
  const rank = (c: string) =>
    c === STOCK_CATEGORY_COMPONENTS ? 2 : c === STOCK_CATEGORY_BARRELED ? 1 : 0
  return rank(a) - rank(b) || a.localeCompare(b)
}

/**
 * True when any row carries a product line. False both on a database whose
 * view predates the product_code column and on a book where it is blank
 * everywhere — either way a "Product line" filter would offer nothing.
 */
export function hasProductLine(rows: readonly { product_code?: string | null }[]): boolean {
  return rows.some((r) => (r.product_code ?? '').trim() !== '')
}

/** SMU screen for the best-sellers list. Special makeup units are
 *  dealer-exclusive runs, so they reach only a handful of accounts; the ERP
 *  has no explicit SMU flag, so dealer breadth is the proxy. "More than
 *  three dealers" per the CEO's ask — tune here if the line moves. */
export const BEST_SELLER_MIN_DEALERS = 4

/** True when enough distinct dealers bought the SKU for it to count as a
 *  regular catalog item rather than an SMU. Pure, unit-testable. */
export function isBroadlyStocked(r: GlobalSkuRow): boolean {
  return r.account_count >= BEST_SELLER_MIN_DEALERS
}

/** Rollup for the "top chamberings" table — pure, unit-testable. Rows with
 *  a blank or 'N/A' value are skipped: a mix bucket named "(none)" is noise,
 *  not a chambering. */
export function rollupBy<K extends 'chambering' | 'product_family'>(
  rows: GlobalSkuRow[],
  key: K,
): { label: string; qty: number }[] {
  const map = new Map<string, { label: string; qty: number }>()
  for (const r of rows) {
    const label = (r[key] ?? '').trim()
    if (!hasSpec(label)) continue
    const entry = map.get(label) ?? { label, qty: 0 }
    entry.qty += r.qty
    map.set(label, entry)
  }
  return [...map.values()].sort((a, b) => b.qty - a.qty)
}
