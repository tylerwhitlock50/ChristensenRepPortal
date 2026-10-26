import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/fetchAll'
import { qk } from '@/lib/queryClient'
import { isViewMissing } from '@/composables/useOverview'

/**
 * The Agency page — a rep-group principal's agency cut by rep — over
 * migration 20261026180000.
 *
 * Scope is never decided here. Every query takes `vendor`:
 *   ''      a principal's own agency: the reads are UNFILTERED, because the
 *           principal's book IS the agency (my_customer_keys(), group book)
 *           and RLS is the filter — the same rule as useOverview.ts;
 *   'XYZ'   an admin's pick: the same reads narrowed to one vendor. For a
 *           principal a vendor can only narrow (RLS already removed every
 *           other agency's rows), and agency_rep_activity() ignores it.
 *
 * Every measure arrives as a raw sum at (rep, channel) grain; the per-rep,
 * per-channel and agency figures are added up below, never averaged — the
 * same discipline as useAdminReports.ts.
 */

/** 20261026180000 lands after database.types.ts was last generated — same
 *  untyped-handle convention as useAdminReports.ts; delete after regenerating. */
const db = supabase as unknown as SupabaseClient

/** Joins goals and actions, so not pure ERP — the Reports tab's holding period. */
const AGENCY_STALE_TIME = 10 * 60_000

const MISSING_MESSAGE =
  'The agency views are not in the database yet. Apply ' +
  'supabase/migrations/20261026180000_agency_overview.sql, then reload.'

function asDisplayError(error: unknown): unknown {
  if (isViewMissing(error)) {
    return Object.assign(new Error(MISSING_MESSAGE), { code: 'PGRST205' })
  }
  return error
}

function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isViewMissing(error) && failureCount < 1
}

/** PostgREST hands numerics back as strings; every measure goes through this. */
function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

function text(value: unknown): string | null {
  return value == null || value === '' ? null : String(value)
}

/** The rpc argument: null for "my own agency". */
function vendorArg(vendor: string): string | null {
  return vendor.trim() || null
}

/* ------------------------------------------------------------- measures */

export interface AgencyMeasures {
  accounts: number
  buying_accounts: number
  lapsed_accounts: number
  new_accounts: number
  accounts_with_goal: number
  contacted_30d: number
  revenue_ytd: number
  revenue_prior_ytd: number
  revenue_trailing_12m: number
  revenue_prior_full: number
  bookings_ytd: number
  bookings_prior_ytd: number
  open_order_value: number
  backlog_amount: number
  goal_total: number
  last_invoice_date: string | null
}

const ZERO: AgencyMeasures = {
  accounts: 0,
  buying_accounts: 0,
  lapsed_accounts: 0,
  new_accounts: 0,
  accounts_with_goal: 0,
  contacted_30d: 0,
  revenue_ytd: 0,
  revenue_prior_ytd: 0,
  revenue_trailing_12m: 0,
  revenue_prior_full: 0,
  bookings_ytd: 0,
  bookings_prior_ytd: 0,
  open_order_value: 0,
  backlog_amount: 0,
  goal_total: 0,
  last_invoice_date: null,
}

function addInto(target: AgencyMeasures, row: AgencyMeasures) {
  target.accounts += row.accounts
  target.buying_accounts += row.buying_accounts
  target.lapsed_accounts += row.lapsed_accounts
  target.new_accounts += row.new_accounts
  target.accounts_with_goal += row.accounts_with_goal
  target.contacted_30d += row.contacted_30d
  target.revenue_ytd += row.revenue_ytd
  target.revenue_prior_ytd += row.revenue_prior_ytd
  target.revenue_trailing_12m += row.revenue_trailing_12m
  target.revenue_prior_full += row.revenue_prior_full
  target.bookings_ytd += row.bookings_ytd
  target.bookings_prior_ytd += row.bookings_prior_ytd
  target.open_order_value += row.open_order_value
  target.backlog_amount += row.backlog_amount
  target.goal_total += row.goal_total
  if (
    row.last_invoice_date &&
    (!target.last_invoice_date || row.last_invoice_date > target.last_invoice_date)
  ) {
    target.last_invoice_date = row.last_invoice_date
  }
}

/** Agency totals over whatever rows are passed. Sums only, so exact. */
export function agencyTotals(rows: AgencyMeasures[]): AgencyMeasures {
  const total = { ...ZERO }
  for (const row of rows) addInto(total, row)
  return total
}

/* ------------------------------------------------- (rep, channel) rows */

export interface AgencyRepChannelRow extends AgencyMeasures {
  /** The account's assigned rep code; null for accounts with none. */
  sales_rep_key: string | null
  sales_rep_name: string | null
  vendor_id: string | null
  channel: string
}

function toRepChannelRow(r: Record<string, unknown>): AgencyRepChannelRow {
  return {
    sales_rep_key: text(r.sales_rep_key),
    sales_rep_name: text(r.sales_rep_name),
    vendor_id: text(r.vendor_id),
    channel: String(r.channel ?? 'Unclassified'),
    accounts: num(r.accounts),
    buying_accounts: num(r.buying_accounts),
    lapsed_accounts: num(r.lapsed_accounts),
    new_accounts: num(r.new_accounts),
    accounts_with_goal: num(r.accounts_with_goal),
    contacted_30d: num(r.contacted_30d),
    revenue_ytd: num(r.revenue_ytd),
    revenue_prior_ytd: num(r.revenue_prior_ytd),
    revenue_trailing_12m: num(r.revenue_trailing_12m),
    revenue_prior_full: num(r.revenue_prior_full),
    bookings_ytd: num(r.bookings_ytd),
    bookings_prior_ytd: num(r.bookings_prior_ytd),
    open_order_value: num(r.open_order_value),
    backlog_amount: num(r.backlog_amount),
    goal_total: num(r.goal_total),
    last_invoice_date: text(r.last_invoice_date),
  }
}

/** The book at (rep, channel) grain — public.v_agency_rep_performance. */
export function useAgencyRepPerformance(
  vendor: MaybeRefOrGetter<string>,
  enabled: MaybeRefOrGetter<boolean> = true,
) {
  const v = computed(() => toValue(vendor).trim())
  return useQuery({
    queryKey: computed(() => qk.agency.reps(v.value)),
    enabled: computed(() => toValue(enabled)),
    staleTime: AGENCY_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AgencyRepChannelRow[]> => {
      try {
        // Reps × channels is tens of rows for an agency; paged anyway, on
        // the view's grain, so a large book can never be cut at 1,000.
        const rows = await fetchAllRows<Record<string, unknown>>((from, to) => {
          let q = db
            .from('v_agency_rep_performance')
            .select('*', { count: 'exact' }) // unfiltered for a principal — RLS is the agency
          if (v.value) q = q.eq('vendor_id', v.value)
          return q
            .order('sales_rep_key', { nullsFirst: true })
            .order('vendor_id', { nullsFirst: true })
            .order('channel')
            .range(from, to)
        })
        return rows.map(toRepChannelRow)
      } catch (error) {
        throw asDisplayError(error)
      }
    },
  })
}

/* ------------------------------------------------------------ activity */

export interface AgencyActivityRow {
  user_id: string
  full_name: string | null
  sales_rep_key: string | null
  vendor_id: string | null
  is_principal: boolean
  active: boolean
  last_login_at: string | null
  logins_7d: number
  logins_30d: number
  active_days_30d: number
  actions_30d: number
  visits_30d: number
  last_action_date: string | null
}

/** Who in the agency uses the portal — public.agency_rep_activity(). */
export function useAgencyActivity(
  vendor: MaybeRefOrGetter<string>,
  enabled: MaybeRefOrGetter<boolean> = true,
) {
  const v = computed(() => toValue(vendor).trim())
  return useQuery({
    queryKey: computed(() => qk.agency.activity(v.value)),
    enabled: computed(() => toValue(enabled)),
    staleTime: AGENCY_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AgencyActivityRow[]> => {
      const { data, error } = await db.rpc('agency_rep_activity', {
        p_vendor_id: vendorArg(v.value),
      })
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        user_id: String(r.user_id),
        full_name: text(r.full_name),
        sales_rep_key: text(r.sales_rep_key),
        vendor_id: text(r.vendor_id),
        is_principal: r.is_principal === true,
        active: r.active !== false,
        last_login_at: text(r.last_login_at),
        logins_7d: num(r.logins_7d),
        logins_30d: num(r.logins_30d),
        active_days_30d: num(r.active_days_30d),
        actions_30d: num(r.actions_30d),
        visits_30d: num(r.visits_30d),
        last_action_date: text(r.last_action_date),
      }))
    },
  })
}

/* ------------------------------------------------------------- monthly */

export interface AgencyMonthRow {
  /** First of the month, `yyyy-MM-dd`. */
  sales_month: string
  sales_rep_key: string | null
  revenue: number
  qty: number
  invoice_count: number
  account_count: number
}

/** Invoiced revenue per (month, rep), 24 months — report_agency_sales_by_month(). */
export function useAgencySalesByMonth(
  vendor: MaybeRefOrGetter<string>,
  enabled: MaybeRefOrGetter<boolean> = true,
) {
  const v = computed(() => toValue(vendor).trim())
  return useQuery({
    queryKey: computed(() => qk.agency.months(v.value)),
    enabled: computed(() => toValue(enabled)),
    staleTime: AGENCY_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AgencyMonthRow[]> => {
      // 24 months × an agency's reps: a few hundred rows at most.
      const { data, error } = await db.rpc('report_agency_sales_by_month', {
        p_months: 24,
        p_vendor_id: vendorArg(v.value),
      })
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        sales_month: String(r.sales_month).slice(0, 10),
        sales_rep_key: text(r.sales_rep_key),
        revenue: num(r.revenue),
        qty: num(r.qty),
        invoice_count: num(r.invoice_count),
        account_count: num(r.account_count),
      }))
    },
  })
}

/**
 * (month, rep) rows → one revenue per month, for buildCalendarYearSeries():
 * the whole agency when `repKey` is undefined, else that rep (null = the
 * accounts with no assigned rep). Summing reps is exact — an account has one
 * assigned rep. Pure, unit-tested.
 */
export function monthlySeriesRows(
  rows: AgencyMonthRow[],
  repKey?: string | null,
): { month: string; revenue: number }[] {
  const byMonth = new Map<string, number>()
  for (const r of rows) {
    if (repKey !== undefined && r.sales_rep_key !== repKey) continue
    byMonth.set(r.sales_month, (byMonth.get(r.sales_month) ?? 0) + r.revenue)
  }
  return [...byMonth.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([month, revenue]) => ({ month, revenue }))
}

/* --------------------------------------------------------- large orders */

export interface AgencyLargeOrder {
  customer_key: string
  customer_id: string | null
  customer_name: string | null
  order_id: string
  order_date: string | null
  amount: number
  line_count: number
  has_open_lines: boolean
  sales_rep_key: string | null
  sales_rep_name: string | null
}

/** The biggest orders of the last `days` — report_agency_large_orders(). */
export function useAgencyLargeOrders(
  vendor: MaybeRefOrGetter<string>,
  days: MaybeRefOrGetter<number>,
  enabled: MaybeRefOrGetter<boolean> = true,
) {
  const v = computed(() => toValue(vendor).trim())
  const d = computed(() => toValue(days))
  return useQuery({
    queryKey: computed(() => qk.agency.largeOrders(v.value, d.value)),
    enabled: computed(() => toValue(enabled)),
    staleTime: AGENCY_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AgencyLargeOrder[]> => {
      const { data, error } = await db.rpc('report_agency_large_orders', {
        p_days: d.value,
        p_limit: 15,
        p_vendor_id: vendorArg(v.value),
      })
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        customer_key: String(r.customer_key),
        customer_id: text(r.customer_id),
        customer_name: text(r.customer_name),
        order_id: String(r.order_id),
        order_date: text(r.order_date),
        amount: num(r.amount),
        line_count: num(r.line_count),
        has_open_lines: r.has_open_lines === true,
        sales_rep_key: text(r.sales_rep_key),
        sales_rep_name: text(r.sales_rep_name),
      }))
    },
  })
}

/* ---------------------------------------------------- derived (pure) */

/** Shown for accounts whose ERP header has no rep code at all. */
export const NO_REP_LABEL = 'No rep assigned'

/** One line of the reps table: a rep's book, and how they use the portal. */
export interface AgencyRepLine extends AgencyMeasures {
  /** Row identity: the rep code, else the portal user, else the no-rep bucket. */
  id: string
  sales_rep_key: string | null
  name: string
  /** The portal login for this rep code, or the principal's own; null = none. */
  portal: AgencyActivityRow | null
  is_principal: boolean
}

function repId(key: string | null): string {
  return key == null ? 'rep:(none)' : `rep:${key}`
}

/** Most recently active first, so a rep code shared by two logins shows the live one. */
function moreActive(a: AgencyActivityRow, b: AgencyActivityRow): AgencyActivityRow {
  if (a.active !== b.active) return a.active ? a : b
  return (b.last_login_at ?? '') > (a.last_login_at ?? '') ? b : a
}

/**
 * The reps table: every rep code with accounts in the book (from the
 * (rep, channel) rows, channels summed), joined to the portal login that
 * carries that code. Portal users with no rep code of their own — the
 * principal, usually — or whose code has no active accounts get a row of
 * their own with zero sales, so "who signs in" is never missing someone.
 * Biggest book first. Pure, unit-tested.
 */
export function buildRepLines(
  rows: AgencyRepChannelRow[],
  activity: AgencyActivityRow[],
): AgencyRepLine[] {
  const byCode = new Map<string, AgencyActivityRow>()
  for (const a of activity) {
    if (!a.sales_rep_key) continue
    const seen = byCode.get(a.sales_rep_key)
    byCode.set(a.sales_rep_key, seen ? moreActive(seen, a) : a)
  }

  const lines = new Map<string, AgencyRepLine>()
  for (const r of rows) {
    const id = repId(r.sales_rep_key)
    let line = lines.get(id)
    if (!line) {
      const portal = r.sales_rep_key ? (byCode.get(r.sales_rep_key) ?? null) : null
      line = {
        ...ZERO,
        id,
        sales_rep_key: r.sales_rep_key,
        name: r.sales_rep_key
          ? r.sales_rep_name || portal?.full_name || r.sales_rep_key
          : NO_REP_LABEL,
        portal,
        is_principal: portal?.is_principal ?? false,
      }
      lines.set(id, line)
    }
    addInto(line, r)
  }

  const placed = new Set(
    [...lines.values()].map((l) => l.portal?.user_id).filter((id): id is string => !!id),
  )
  for (const a of activity) {
    if (placed.has(a.user_id)) continue
    // Same code as a placed login (a second account on one rep code): the
    // line already shows the livelier of the two.
    if (a.sales_rep_key && lines.has(repId(a.sales_rep_key))) continue
    placed.add(a.user_id)
    lines.set(`user:${a.user_id}`, {
      ...ZERO,
      id: `user:${a.user_id}`,
      sales_rep_key: a.sales_rep_key,
      name: a.full_name || a.sales_rep_key || 'Portal user',
      portal: a,
      is_principal: a.is_principal,
    })
  }

  return [...lines.values()].sort(
    (a, b) =>
      b.revenue_ytd - a.revenue_ytd ||
      b.revenue_prior_ytd - a.revenue_prior_ytd ||
      a.name.localeCompare(b.name),
  )
}

export interface AgencyChannelLine extends AgencyMeasures {
  channel: string
}

/**
 * (rep, channel) rows → one row per channel, optionally for one rep
 * (undefined = every rep; null = the no-rep bucket). Biggest first.
 * Pure, unit-tested.
 */
export function rollUpAgencyChannels(
  rows: AgencyRepChannelRow[],
  repKey?: string | null,
): AgencyChannelLine[] {
  const byChannel = new Map<string, AgencyChannelLine>()
  for (const r of rows) {
    if (repKey !== undefined && r.sales_rep_key !== repKey) continue
    let line = byChannel.get(r.channel)
    if (!line) {
      line = { ...ZERO, channel: r.channel }
      byChannel.set(r.channel, line)
    }
    addInto(line, r)
  }
  return [...byChannel.values()].sort(
    (a, b) => b.revenue_ytd - a.revenue_ytd || b.revenue_prior_ytd - a.revenue_prior_ytd,
  )
}

/** Signed in within `days` of `now`. */
export function activeWithin(
  row: Pick<AgencyActivityRow, 'last_login_at'> | null | undefined,
  days: number,
  now: Date = new Date(),
): boolean {
  if (!row?.last_login_at) return false
  return now.getTime() - new Date(row.last_login_at).getTime() < days * 86_400_000
}
