import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { isViewMissing } from '@/composables/useOverview'

/**
 * The admin Reports tab: channel performance and rep-group performance,
 * both from migration 20260816120000.
 *
 * Both views emit RAW SUMS at their finest grain and nothing derived — that
 * is deliberate (see the migration header). Every ratio on the screen is
 * computed here, from sums, so rolling sub-channels up into a channel can
 * never produce an average of averages.
 */

/** 20260816120000 lands after database.types.ts was last generated — same
 *  untyped-handle convention as useAdmin.ts / useOverview.ts; delete after
 *  regenerating the types. */
const db = supabase as unknown as SupabaseClient

/** ERP rollups move once a night. Same holding period as useOverview.ts. */
const ERP_STALE_TIME = 10 * 60_000

const MISSING_VIEW_MESSAGE =
  'The admin reporting views are not in the database yet. Apply ' +
  'supabase/migrations/20260816120000_admin_channel_rep_group_reporting.sql, ' +
  'then reload.'

/** PostgREST hands numerics back as strings; every measure goes through this. */
function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

function text(value: unknown): string | null {
  return value == null || value === '' ? null : String(value)
}

async function selectRows(view: string): Promise<Record<string, unknown>[]> {
  const { data, error } = await db.from(view).select('*')
  if (error) {
    if (isViewMissing(error)) {
      throw Object.assign(new Error(MISSING_VIEW_MESSAGE), { code: 'PGRST205' })
    }
    throw error
  }
  return (data ?? []) as Record<string, unknown>[]
}

function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isViewMissing(error) && failureCount < 1
}

/* ------------------------------------------------------------- channels */

/** The measures both grains share, so a sub-channel row and the channel it
 *  rolls up into are the same shape to every formatter below. */
export interface ChannelMeasures {
  accounts: number
  buying_accounts: number
  lapsed_accounts: number
  new_accounts: number
  accounts_with_goal: number
  revenue_ytd: number
  revenue_prior_ytd: number
  revenue_trailing_12m: number
  bookings_ytd: number
  open_order_value: number
  backlog_amount: number
  goal_total: number
  last_invoice_date: string | null
}

export interface ChannelRow extends ChannelMeasures {
  channel: string
  /** Null on a rolled-up channel row; set on the sub-channel rows. */
  sub_channel: string | null
}

const ZERO: ChannelMeasures = {
  accounts: 0,
  buying_accounts: 0,
  lapsed_accounts: 0,
  new_accounts: 0,
  accounts_with_goal: 0,
  revenue_ytd: 0,
  revenue_prior_ytd: 0,
  revenue_trailing_12m: 0,
  bookings_ytd: 0,
  open_order_value: 0,
  backlog_amount: 0,
  goal_total: 0,
  last_invoice_date: null,
}

function toChannelRow(r: Record<string, unknown>): ChannelRow {
  return {
    channel: String(r.channel ?? 'Unclassified'),
    sub_channel: text(r.sub_channel),
    accounts: num(r.accounts),
    buying_accounts: num(r.buying_accounts),
    lapsed_accounts: num(r.lapsed_accounts),
    new_accounts: num(r.new_accounts),
    accounts_with_goal: num(r.accounts_with_goal),
    revenue_ytd: num(r.revenue_ytd),
    revenue_prior_ytd: num(r.revenue_prior_ytd),
    revenue_trailing_12m: num(r.revenue_trailing_12m),
    bookings_ytd: num(r.bookings_ytd),
    open_order_value: num(r.open_order_value),
    backlog_amount: num(r.backlog_amount),
    goal_total: num(r.goal_total),
    last_invoice_date: text(r.last_invoice_date),
  }
}

/**
 * One row per (channel, sub-channel) from public.v_channel_performance.
 * ~30 rows for the whole company — no paging, one round trip.
 */
export function useChannelPerformance() {
  return useQuery({
    queryKey: qk.admin.channels(),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<ChannelRow[]> =>
      (await selectRows('v_channel_performance')).map(toChannelRow),
  })
}

function addInto(target: ChannelMeasures, row: ChannelMeasures) {
  target.accounts += row.accounts
  target.buying_accounts += row.buying_accounts
  target.lapsed_accounts += row.lapsed_accounts
  target.new_accounts += row.new_accounts
  target.accounts_with_goal += row.accounts_with_goal
  target.revenue_ytd += row.revenue_ytd
  target.revenue_prior_ytd += row.revenue_prior_ytd
  target.revenue_trailing_12m += row.revenue_trailing_12m
  target.bookings_ytd += row.bookings_ytd
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

/** Sub-channel rows → one row per channel. Sums only, so this is exact. */
export function rollUpChannels(rows: ChannelRow[]): ChannelRow[] {
  const byChannel = new Map<string, ChannelRow>()
  for (const row of rows) {
    let acc = byChannel.get(row.channel)
    if (!acc) {
      acc = { ...ZERO, channel: row.channel, sub_channel: null }
      byChannel.set(row.channel, acc)
    }
    addInto(acc, row)
  }
  return [...byChannel.values()]
}

/** Company totals across whatever rows are on screen. */
export function totalChannels(rows: ChannelMeasures[]): ChannelMeasures {
  const total = { ...ZERO }
  for (const row of rows) addInto(total, row)
  return total
}

/* ---------------------------------------------------------- rep groups */

export interface RepGroupRow {
  rep_group_id: string
  /** Portal logins attached to the group — the people who actually sign in. */
  portal_users: number
  portal_user_names: string | null
  /** ERP sales reps whose accounts roll up here. */
  rep_count: number
  rep_names: string | null
  accounts: number
  buying_accounts: number
  lapsed_accounts: number
  accounts_with_goal: number
  contacted_30d: number
  contacted_90d: number
  revenue_ytd: number
  revenue_prior_ytd: number
  revenue_trailing_12m: number
  bookings_ytd: number
  open_order_value: number
  backlog_amount: number
  goal_total: number
  last_invoice_date: string | null
}

/** One row per rep group (agency) from public.v_rep_group_performance. */
export function useRepGroupPerformance() {
  return useQuery({
    queryKey: qk.admin.repGroupPerformance(),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<RepGroupRow[]> =>
      (await selectRows('v_rep_group_performance')).map((r) => ({
        rep_group_id: String(r.rep_group_id ?? '—'),
        portal_users: num(r.portal_users),
        portal_user_names: text(r.portal_user_names),
        rep_count: num(r.rep_count),
        rep_names: text(r.rep_names),
        accounts: num(r.accounts),
        buying_accounts: num(r.buying_accounts),
        lapsed_accounts: num(r.lapsed_accounts),
        accounts_with_goal: num(r.accounts_with_goal),
        contacted_30d: num(r.contacted_30d),
        contacted_90d: num(r.contacted_90d),
        revenue_ytd: num(r.revenue_ytd),
        revenue_prior_ytd: num(r.revenue_prior_ytd),
        revenue_trailing_12m: num(r.revenue_trailing_12m),
        bookings_ytd: num(r.bookings_ytd),
        open_order_value: num(r.open_order_value),
        backlog_amount: num(r.backlog_amount),
        goal_total: num(r.goal_total),
        last_invoice_date: text(r.last_invoice_date),
      })),
  })
}

/* ------------------------------------------------------ derived measures */

/**
 * Year over year, as a percentage. Null when there is no prior-year base to
 * compare against — "+∞%" on a channel that sold nothing last year is noise,
 * and the UI shows "new" instead.
 */
export function yoyPct(current: number, prior: number): number | null {
  if (prior <= 0) return null
  return ((current - prior) / prior) * 100
}

/** Percent of goal. Null when the group has no goal set — not 0%. */
export function attainmentPct(actual: number, goal: number): number | null {
  if (goal <= 0) return null
  return (actual / goal) * 100
}

/** Share of a total, as a fraction (0–1) for `share()` in lib/format. */
export function shareOf(value: number, total: number): number | null {
  if (total <= 0) return null
  return value / total
}

/**
 * How far through the calendar year we are, 0–100. The pace marker every
 * attainment bar is read against: 58% of goal in August is fine, in March
 * it is not.
 */
export function yearElapsedPct(now = new Date()): number {
  const start = new Date(now.getFullYear(), 0, 1).getTime()
  const end = new Date(now.getFullYear() + 1, 0, 1).getTime()
  return ((now.getTime() - start) / (end - start)) * 100
}
