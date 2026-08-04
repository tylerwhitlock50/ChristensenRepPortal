import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { differenceInCalendarDays, parseISO } from 'date-fns'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'

/**
 * The Overview (morning briefing) read path.
 *
 * ONE unfiltered select of public.v_territory_account_yoy is the whole page:
 * RLS scopes it to the caller's book, Postgres did the per-account sums, and
 * everything else — territory totals, movers, worth-investigating — is
 * derivation over a few hundred rows, exported below so it can be unit
 * tested without a DB. (Unfiltered is correct here and only here; the
 * account views in useAccountMetrics.ts must stay .eq — see 020's header.)
 */

/** 020 lands after database.types.ts was last generated — same untyped-handle
 *  convention as useAccountMetrics.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

/* ----------------------------------------------------------------- rows */

export interface TerritoryAccountRow {
  customer_key: string
  customer_name: string | null
  sold_to_city: string | null
  sold_to_state: string | null
  yearly_sales_goal: number | null
  revenue_ytd: number
  revenue_prior_ytd: number
  revenue_trailing_12m: number
  last_invoice_date: string | null
  open_order_value: number
  backlog_qty: number
  backlog_amount: number
}

export interface TerritoryRecentOrderRow {
  customer_key: string
  customer_name: string | null
  order_id: string
  order_date: string | null
  order_amount: number
  line_count: number
  has_backlog: boolean
}

/* ------------------------------------------------------------- plumbing */

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
  'The territory views are not in the database yet. Apply ' +
  'supabase/migrations/025_intel_views.sql, then reload.'

/** Same deployment-state handling as useAccountMetrics.ts, plus PGRST202 —
 *  "could not find the function" — because the intel pages also call an RPC. */
export function isViewMissing(error: unknown): boolean {
  const e = error as { code?: string; message?: string } | null
  if (!e) return false
  return (
    e.code === 'PGRST205' ||
    e.code === 'PGRST202' ||
    e.code === '42P01' ||
    /could not find the (table|view|relation|function)|relation .* does not exist|function .* does not exist/i.test(
      e.message ?? '',
    )
  )
}

function asDisplayError(error: unknown): unknown {
  if (isViewMissing(error)) {
    return Object.assign(new Error(MISSING_VIEW_MESSAGE), { code: 'PGRST205' })
  }
  return error
}

function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isViewMissing(error) && failureCount < 1
}

// Nightly ERP data; same holding period as useAccountMetrics.ts.
const ERP_STALE_TIME = 10 * 60_000

/* -------------------------------------------------------------- queries */

/** Every account in the caller's book with YoY + backlog. THE Overview query. */
export function useTerritoryAccounts() {
  return useQuery({
    queryKey: qk.intel.territoryYoy(),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<TerritoryAccountRow[]> => {
      const { data, error } = await db
        .from('v_territory_account_yoy')
        .select('*') // unfiltered on purpose — RLS is the territory filter
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        customer_key: String(r.customer_key),
        customer_name: (r.customer_name as string | null) ?? null,
        sold_to_city: (r.sold_to_city as string | null) ?? null,
        sold_to_state: (r.sold_to_state as string | null) ?? null,
        yearly_sales_goal: numOrNull(r.yearly_sales_goal),
        revenue_ytd: num(r.revenue_ytd),
        revenue_prior_ytd: num(r.revenue_prior_ytd),
        revenue_trailing_12m: num(r.revenue_trailing_12m),
        last_invoice_date: (r.last_invoice_date as string | null) ?? null,
        open_order_value: num(r.open_order_value),
        backlog_qty: num(r.backlog_qty),
        backlog_amount: num(r.backlog_amount),
      }))
    },
  })
}

/** Territory orders from the last 14 days — the Recent Activity feed. */
export function useTerritoryRecentOrders() {
  return useQuery({
    queryKey: qk.intel.territoryRecentOrders(),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<TerritoryRecentOrderRow[]> => {
      const { data, error } = await db
        .from('v_territory_recent_orders')
        .select('*')
        .order('order_date', { ascending: false, nullsFirst: false })
        .limit(25)
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        customer_key: String(r.customer_key),
        customer_name: (r.customer_name as string | null) ?? null,
        order_id: String(r.order_id),
        order_date: (r.order_date as string | null) ?? null,
        order_amount: num(r.order_amount),
        line_count: num(r.line_count),
        has_backlog: r.has_backlog === true,
      }))
    },
  })
}

/* ---------------------------------------------------- derivations (pure) */

export interface TerritoryTotals {
  accountCount: number
  revenueYtd: number
  revenuePriorYtd: number
  /** Percent change YTD vs prior. Null when the prior year was zero. */
  deltaPct: number | null
  /** Sum of yearly_sales_goal over accounts that have one; 0 = no goal data. */
  goal: number
  /** revenueYtd / goal, percent. Null when there is no goal data. */
  goalPct: number | null
  openOrderValue: number
  backlogAmount: number
  backlogQty: number
}

export function territoryTotals(rows: TerritoryAccountRow[]): TerritoryTotals {
  const sum = (f: (r: TerritoryAccountRow) => number) =>
    rows.reduce((a, r) => a + f(r), 0)
  const revenueYtd = sum((r) => r.revenue_ytd)
  const revenuePriorYtd = sum((r) => r.revenue_prior_ytd)
  const goal = sum((r) => r.yearly_sales_goal ?? 0)
  return {
    accountCount: rows.length,
    revenueYtd,
    revenuePriorYtd,
    deltaPct:
      revenuePriorYtd > 0
        ? ((revenueYtd - revenuePriorYtd) / revenuePriorYtd) * 100
        : null,
    goal,
    goalPct: goal > 0 ? (revenueYtd / goal) * 100 : null,
    openOrderValue: sum((r) => r.open_order_value),
    backlogAmount: sum((r) => r.backlog_amount),
    backlogQty: sum((r) => r.backlog_qty),
  }
}

export interface Mover extends TerritoryAccountRow {
  /** revenue_ytd − revenue_prior_ytd, the sort key. */
  delta: number
}

/** Top N up and top N down by dollar YoY change. Flat accounts don't move. */
export function largestMovers(
  rows: TerritoryAccountRow[],
  n = 5,
): { up: Mover[]; down: Mover[] } {
  const withDelta: Mover[] = rows
    .map((r) => ({ ...r, delta: r.revenue_ytd - r.revenue_prior_ytd }))
    .filter((r) => r.delta !== 0)
  const sorted = [...withDelta].sort((a, b) => b.delta - a.delta)
  return {
    up: sorted.filter((r) => r.delta > 0).slice(0, n),
    down: sorted
      .filter((r) => r.delta < 0)
      .sort((a, b) => a.delta - b.delta)
      .slice(0, n),
  }
}

export interface Observation {
  kind: 'dormant' | 'decline' | 'backlog'
  customer_key: string
  customer_name: string
  /** Plain-English, observation-voiced: what the data shows, never a task. */
  note: string
  /** Dollar magnitude, for ranking across kinds. */
  weight: number
}

/**
 * "Worth investigating" — data-derived observations, deliberately framed as
 * what the data shows ("hasn't invoiced in 103 days"), never as assignments.
 * The rep decides whether action is warranted. Thresholds are modest and
 * hard-coded for v1; if they need tuning, app_settings.params is the home.
 */
export function worthInvestigating(
  rows: TerritoryAccountRow[],
  n = 6,
  today: Date = new Date(),
): Observation[] {
  const out: Observation[] = []
  for (const r of rows) {
    const name = r.customer_name || r.customer_key

    // Dormant: real recent history, but nothing invoiced in 90+ days.
    if (r.last_invoice_date && r.revenue_trailing_12m >= 5_000) {
      const days = differenceInCalendarDays(today, parseISO(r.last_invoice_date))
      if (days >= 90) {
        out.push({
          kind: 'dormant',
          customer_key: r.customer_key,
          customer_name: name,
          note: `Hasn't invoiced in ${days} days`,
          weight: r.revenue_trailing_12m,
        })
        continue // one observation per account — the loudest one
      }
    }

    // Sharp decline: meaningful prior-year base, less than half of it now.
    if (r.revenue_prior_ytd >= 10_000 && r.revenue_ytd < r.revenue_prior_ytd * 0.5) {
      const pct = Math.round(
        (1 - r.revenue_ytd / r.revenue_prior_ytd) * 100,
      )
      out.push({
        kind: 'decline',
        customer_key: r.customer_key,
        customer_name: name,
        note: `Revenue down ${pct}% vs this time last year`,
        weight: r.revenue_prior_ytd - r.revenue_ytd,
      })
      continue
    }

    // Large backorder position.
    if (r.backlog_amount >= 10_000) {
      out.push({
        kind: 'backlog',
        customer_key: r.customer_key,
        customer_name: name,
        note: `Has a large backorder position`,
        weight: r.backlog_amount,
      })
    }
  }
  return out.sort((a, b) => b.weight - a.weight).slice(0, n)
}
