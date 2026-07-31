import { computed, unref, type MaybeRef } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { format, startOfMonth, subMonths } from 'date-fns'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'

/**
 * The account mini-dashboard read path (PRD §7).
 *
 * Every query here hits a `public.v_account_*` view from
 * supabase/migrations/011_account_views.sql. Those views do the aggregation
 * in Postgres on purpose — fact_invoice_line is ~529k rows and
 * fact_order_line ~501k, so summing them in the browser is not an option
 * (TECH_STACK §3.3). Nothing in this file reduces a fact table.
 *
 * Two rules the views depend on:
 *
 *  1. Always `.eq('customer_key', …)`. The views are written so that
 *     predicate reaches the indexed fact scan; without it the query
 *     aggregates the caller's entire book, which for an admin is every
 *     account in the ERP.
 *  2. Never add an owner filter. RLS is the security boundary — the views
 *     are `security_invoker = true`, so an unscoped select already returns
 *     exactly the caller's book (TECH_STACK §1).
 */

/**
 * 011_account_views.sql lands after database.types.ts was last generated, so
 * the v_account_* views are not in the typed `Database` yet and
 * `supabase.from('v_account_summary')` would not compile.
 *
 * This is the SAME client — same JWT, same session, same RLS — read through
 * an untyped handle, with the row shapes asserted below instead. Once the
 * migration is applied and types are regenerated, delete this cast and let
 * the generated `Views` entries type these calls.
 */
const db = supabase as unknown as SupabaseClient

/* ------------------------------------------------------------------ keys */

/**
 * Local keys rather than additions to `qk` — this file does not own
 * src/lib/queryClient.ts. They are built on `qk.account.root(key)` so the
 * existing `invalidateQueries({ queryKey: qk.account.root(key) })` in
 * useRecommendations / useAccountData still sweeps them up.
 */
export const accountMetricsKeys = {
  summary: (key: string) => [...qk.account.root(key), 'summary'] as const,
  revenueMonthly: (key: string) =>
    [...qk.account.root(key), 'revenue-monthly'] as const,
  recentOrders: (key: string) => qk.account.orders(key),
  recentShipments: (key: string) => qk.account.shipments(key),
}

/* ----------------------------------------------------------------- rows */

export interface AccountSummaryRow {
  customer_key: string
  revenue_ytd: number
  revenue_prior_ytd: number
  revenue_trailing_12m: number
  last_order_date: string | null
  last_invoice_date: string | null
  open_order_count: number
  open_order_value: number
  backlog_qty: number
}

export interface AccountRevenueMonthRow {
  customer_key: string
  /** First of the month, `yyyy-MM-dd`. */
  month: string
  revenue: number
  invoice_count: number
}

export interface AccountRecentOrderRow {
  customer_key: string
  order_id: string
  line_num: number
  order_date: string | null
  promise_date: string | null
  order_state: string | null
  order_status_desc: string | null
  line_status_desc: string | null
  part_key: string | null
  part_id: string | null
  part_description: string | null
  order_qty: number | null
  bookings: number | null
  backlog_qty: number | null
  is_backlog_line: boolean | null
}

export interface AccountRecentShipmentRow {
  customer_key: string
  packlist_id: string
  line_num: number
  order_id: string | null
  invoice_id: string | null
  ship_date: string | null
  promise_date: string | null
  actual_delivery_date: string | null
  shipment_state: string | null
  shipper_status_desc: string | null
  part_key: string | null
  part_id: string | null
  part_description: string | null
  shipped_qty: number | null
  shipped_revenue: number | null
}

/* -------------------------------------------------------------- plumbing */

/** PostgREST can hand numerics back as strings depending on the column type. */
function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

function numOrNull(value: unknown): number | null {
  if (value == null) return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

const MISSING_VIEW_MESSAGE =
  'The account rollup views are not in the database yet. Apply ' +
  'supabase/migrations/011_account_views.sql (it creates the v_account_* views), ' +
  'then reload.'

/**
 * True when PostgREST could not find the relation — i.e. 011 has not been
 * applied, or the schema cache is stale after applying it.
 */
export function isViewMissing(error: unknown): boolean {
  const e = error as { code?: string; message?: string } | null
  if (!e) return false
  return (
    e.code === 'PGRST205' ||
    e.code === '42P01' ||
    /could not find the (table|view|relation)|relation .* does not exist/i.test(
      e.message ?? '',
    )
  )
}

/**
 * A missing view is a deployment state, not a crash. Swapping in a message
 * that says what to do means AsyncState renders an explanation instead of
 * `PGRST205`, and the rest of the account page keeps working.
 */
function asDisplayError(error: unknown): unknown {
  if (isViewMissing(error)) {
    return Object.assign(new Error(MISSING_VIEW_MESSAGE), { code: 'PGRST205' })
  }
  return error
}

/** One retry for bad signal; none for a view that does not exist. */
function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isViewMissing(error) && failureCount < 1
}

// The ETL lands erp once a night, so these are safe to hold for a while.
const ERP_STALE_TIME = 10 * 60_000

/* -------------------------------------------------------------- queries */

/** Stat tiles: YTD vs prior YTD, trailing 12m, open orders. */
export function useAccountSummary(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => accountMetricsKeys.summary(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AccountSummaryRow | null> => {
      const { data, error } = await db
        .from('v_account_summary')
        .select('*')
        .eq('customer_key', key.value) // required — see the file header
        .maybeSingle()
      if (error) throw asDisplayError(error)
      if (!data) return null
      return {
        customer_key: String(data.customer_key),
        revenue_ytd: num(data.revenue_ytd),
        revenue_prior_ytd: num(data.revenue_prior_ytd),
        revenue_trailing_12m: num(data.revenue_trailing_12m),
        last_order_date: data.last_order_date ?? null,
        last_invoice_date: data.last_invoice_date ?? null,
        open_order_count: num(data.open_order_count),
        open_order_value: num(data.open_order_value),
        backlog_qty: num(data.backlog_qty),
      }
    },
  })
}

/**
 * Trailing 24 months of invoiced revenue, ascending. 24 rather than 12 so
 * the chart draws this year and last year from one round trip — see
 * buildRevenueSeries().
 */
export function useAccountRevenueMonthly(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => accountMetricsKeys.revenueMonthly(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AccountRevenueMonthRow[]> => {
      const { data, error } = await db
        .from('v_account_revenue_monthly')
        .select('customer_key, month, revenue, invoice_count')
        .eq('customer_key', key.value)
        .order('month', { ascending: true })
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        customer_key: String(r.customer_key),
        month: String(r.month).slice(0, 10),
        revenue: num(r.revenue),
        invoice_count: num(r.invoice_count),
      }))
    },
  })
}

export function useAccountRecentOrders(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => accountMetricsKeys.recentOrders(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AccountRecentOrderRow[]> => {
      const { data, error } = await db
        .from('v_account_recent_orders')
        .select('*')
        .eq('customer_key', key.value)
        .order('order_date', { ascending: false, nullsFirst: false })
        .order('order_id', { ascending: false })
        .order('line_num', { ascending: true })
        .limit(20)
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        customer_key: String(r.customer_key),
        order_id: String(r.order_id),
        line_num: num(r.line_num),
        order_date: (r.order_date as string | null) ?? null,
        promise_date: (r.promise_date as string | null) ?? null,
        order_state: (r.order_state as string | null) ?? null,
        order_status_desc: (r.order_status_desc as string | null) ?? null,
        line_status_desc: (r.line_status_desc as string | null) ?? null,
        part_key: (r.part_key as string | null) ?? null,
        part_id: (r.part_id as string | null) ?? null,
        part_description: (r.part_description as string | null) ?? null,
        order_qty: numOrNull(r.order_qty),
        bookings: numOrNull(r.bookings),
        backlog_qty: numOrNull(r.backlog_qty),
        is_backlog_line: (r.is_backlog_line as boolean | null) ?? null,
      }))
    },
  })
}

export function useAccountRecentShipments(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => accountMetricsKeys.recentShipments(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AccountRecentShipmentRow[]> => {
      const { data, error } = await db
        .from('v_account_recent_shipments')
        .select('*')
        .eq('customer_key', key.value)
        .order('ship_date', { ascending: false, nullsFirst: false })
        .order('packlist_id', { ascending: false })
        .order('line_num', { ascending: true })
        .limit(20)
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        customer_key: String(r.customer_key),
        packlist_id: String(r.packlist_id),
        line_num: num(r.line_num),
        order_id: (r.order_id as string | null) ?? null,
        invoice_id: (r.invoice_id as string | null) ?? null,
        ship_date: (r.ship_date as string | null) ?? null,
        promise_date: (r.promise_date as string | null) ?? null,
        actual_delivery_date: (r.actual_delivery_date as string | null) ?? null,
        shipment_state: (r.shipment_state as string | null) ?? null,
        shipper_status_desc: (r.shipper_status_desc as string | null) ?? null,
        part_key: (r.part_key as string | null) ?? null,
        part_id: (r.part_id as string | null) ?? null,
        part_description: (r.part_description as string | null) ?? null,
        shipped_qty: numOrNull(r.shipped_qty),
        shipped_revenue: numOrNull(r.shipped_revenue),
      }))
    },
  })
}

/* ----------------------------------------------------------- chart shape */

export interface RevenueSeries {
  /** 12 short month labels, oldest first — 'Aug', 'Sep', … */
  labels: string[]
  /** 12 full labels for tooltips and the screen-reader table — 'Aug 2025'. */
  monthLabels: string[]
  /** Same 12 months a year earlier — 'Aug 2024'. */
  priorMonthLabels: string[]
  /** Revenue for each of the last 12 months. */
  current: number[]
  /** Revenue for the same 12 months a year earlier. */
  prior: number[]
  currentTotal: number
  priorTotal: number
  /** Percent change vs the prior year. Null when the prior year was zero. */
  deltaPct: number | null
  /** False when every one of the 24 months is zero — nothing to draw. */
  hasData: boolean
}

/**
 * Aligns the 24 monthly rows into two 12-month series, month-of-year for
 * month-of-year, filling silent months with 0.
 *
 * This is date alignment over at most 24 rows, not aggregation — the sums
 * were done in Postgres. Exported so it can be unit-tested without a DB.
 */
export function buildRevenueSeries(
  rows: AccountRevenueMonthRow[],
  today: Date = new Date(),
): RevenueSeries {
  const byMonth = new Map<string, number>()
  for (const row of rows) byMonth.set(row.month, row.revenue)

  const thisMonth = startOfMonth(today)
  const months = Array.from({ length: 12 }, (_, i) => subMonths(thisMonth, 11 - i))

  const labels: string[] = []
  const monthLabels: string[] = []
  const priorMonthLabels: string[] = []
  const current: number[] = []
  const prior: number[] = []

  for (const m of months) {
    const p = subMonths(m, 12)
    labels.push(format(m, 'MMM'))
    monthLabels.push(format(m, 'MMM yyyy'))
    priorMonthLabels.push(format(p, 'MMM yyyy'))
    current.push(byMonth.get(format(m, 'yyyy-MM-dd')) ?? 0)
    prior.push(byMonth.get(format(p, 'yyyy-MM-dd')) ?? 0)
  }

  const currentTotal = current.reduce((a, b) => a + b, 0)
  const priorTotal = prior.reduce((a, b) => a + b, 0)

  return {
    labels,
    monthLabels,
    priorMonthLabels,
    current,
    prior,
    currentTotal,
    priorTotal,
    deltaPct: priorTotal > 0 ? ((currentTotal - priorTotal) / priorTotal) * 100 : null,
    hasData: currentTotal !== 0 || priorTotal !== 0,
  }
}

/** Percent change between two periods. Null when the base is zero. */
export function percentChange(current: number, base: number): number | null {
  if (!base) return null
  return ((current - base) / base) * 100
}

/** '+12%' / '−8%' / '—'. Uses a real minus sign, not a hyphen. */
export function deltaLabel(pct: number | null): string {
  if (pct == null || !Number.isFinite(pct)) return '—'
  const rounded = Math.round(pct)
  if (rounded === 0) return 'flat'
  return rounded > 0 ? `+${rounded}%` : `−${Math.abs(rounded)}%`
}
