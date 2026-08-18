import { computed, unref, type MaybeRef } from 'vue'
import { useQuery } from '@tanstack/vue-query'
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

function asDisplayError(error: unknown, migration: string): unknown {
  if (isViewMissing(error)) {
    return Object.assign(
      new Error(
        `This report's view is not in the database yet. Apply supabase/migrations/${migration}, then reload.`,
      ),
      { code: 'PGRST205' },
    )
  }
  return error
}

function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isViewMissing(error) && failureCount < 1
}

const ERP_STALE_TIME = 10 * 60_000

/* ------------------------------------------------------------- SKU sales */

export interface SkuYearRow {
  customer_key?: string
  part_key: string
  part_id: string | null
  part_description: string | null
  product_family: string | null
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
      // (LIPSEYS: 1,692 rows) — unpaged, the grid AND the header totals were
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

/* --------------------------------------------------------------- backlog */

export interface BacklogSkuRow {
  customer_key: string
  customer_id: string | null
  customer_name: string | null
  part_key: string
  part_id: string | null
  part_description: string | null
  product_family: string | null
  chambering: string | null
  backlog_qty: number
  backlog_amount: number
  open_line_count: number
  earliest_promise_date: string | null
  /** min(desired_ship_date) — shown to reps as "estimated production date". */
  earliest_desired_ship_date: string | null
  latest_order_date: string | null
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
    chambering: (r.chambering as string | null) ?? null,
    backlog_qty: num(r.backlog_qty),
    backlog_amount: num(r.backlog_amount),
    open_line_count: num(r.open_line_count),
    earliest_promise_date: (r.earliest_promise_date as string | null) ?? null,
    earliest_desired_ship_date:
      (r.earliest_desired_ship_date as string | null) ?? null,
    latest_order_date: (r.latest_order_date as string | null) ?? null,
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
    staleTime: ERP_STALE_TIME,
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
export function isGunRow(r: GlobalSkuRow): boolean {
  if (r.product_code && COMPONENT_PRODUCT_CODE.test(r.product_code)) return false
  return hasSpec(r.product_family) || hasSpec(r.chambering)
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
