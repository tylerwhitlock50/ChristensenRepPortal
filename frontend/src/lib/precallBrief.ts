/**
 * The sentences in the account page's "Before you call" card
 * (components/BeforeYouCallCard.vue), as pure functions so the wording and
 * the date arithmetic can be unit-tested without a component or a network.
 *
 * Observation voice throughout: each line states what is so — "2 open
 * orders · $18,900", "Bought 6 in Jul 2026 · 40 available" — and leaves the
 * conclusion to the rep.
 */
import { format, parseISO } from 'date-fns'
import { count, dayMonth, humanize, money, shortDate } from '@/lib/format'

/** The v_account_summary fields the owed line reads. */
export interface OwedSummary {
  open_order_count: number
  open_order_value: number
  backlog_qty: number
}

/** The v_backlog_by_sku fields the owed detail reads. */
export interface OwedSkuRow {
  backlog_amount: number
  /** Earliest promise date among the SKU's open lines, 'YYYY-MM-DD'. */
  earliest_promise_date: string | null
}

/**
 * "2 open orders · $18,900 · 6 units", then — once the backlog rows are in —
 * "Next promise Oct 23 · 2 items past promise ($6,996)". Null when nothing
 * is open: a clean book should say nothing, not "0 open orders".
 *
 * The promise dates are per SKU (the earliest open line of each), so "past
 * promise" counts SKUs whose earliest open line is late: the same rows the
 * On backorder card lists, so the two agree. `today` is 'YYYY-MM-DD'.
 */
export function owedLines(
  summary: OwedSummary | null | undefined,
  rows: readonly OwedSkuRow[] | null | undefined,
  today: string,
): { headline: string; detail: string } | null {
  if (!summary || summary.open_order_count <= 0) return null
  const n = summary.open_order_count
  const units = summary.backlog_qty ? ` · ${count(Math.round(summary.backlog_qty))} units` : ''
  const headline = `${n} open order${n === 1 ? '' : 's'} · ${money(summary.open_order_value)}${units}`
  if (!rows) return { headline, detail: '' }

  const late = rows.filter((r) => !!r.earliest_promise_date && r.earliest_promise_date < today)
  const next = rows
    .map((r) => r.earliest_promise_date)
    .filter((d): d is string => !!d && d >= today)
    .sort()[0]
  const lateAmount = late.reduce((sum, r) => sum + r.backlog_amount, 0)
  const detail = [
    next ? `Next promise ${dayMonth(next)}` : '',
    late.length
      ? `${late.length} item${late.length === 1 ? '' : 's'} past promise (${money(lateAmount)})`
      : '',
  ]
    .filter(Boolean)
    .join(' · ')
  return { headline, detail }
}

/** The v_account_recent_order_headers fields the last-order line reads. */
export interface LastOrderRow {
  order_id: string
  order_date: string | null
  order_state: string | null
  order_status_desc: string | null
  line_count: number
  bookings: number
  open_line_count: number
  backlog_qty: number
  customer_po_number: string | null
}

/**
 * "51234 · $4,250 · 3 lines · their PO 7781 · 2 units still open". The
 * units say what the number counts: next to "3 lines", a bare "5 still
 * open" reads as more open lines than the order has. The order's
 * own date joins the line only when it differs from `shownDate`, the date
 * already printed above it — the ERP's own last-order field can be newer
 * than any order line, and then the line must say which order it means.
 */
export function lastOrderLine(o: LastOrderRow | null | undefined, shownDate?: string | null): string {
  if (!o) return ''
  const parts = [
    o.order_id,
    money(o.bookings),
    `${count(o.line_count)} line${o.line_count === 1 ? '' : 's'}`,
  ]
  if (o.order_date && o.order_date !== shownDate) parts.unshift(shortDate(o.order_date))
  if (o.customer_po_number) parts.push(`their PO ${o.customer_po_number}`)
  parts.push(
    o.open_line_count > 0
      ? `${count(o.backlog_qty)} unit${o.backlog_qty === 1 ? '' : 's'} still open`
      : humanize(o.order_state ?? o.order_status_desc),
  )
  return parts.join(' · ')
}

/**
 * How many reorder candidates Before you call lists. Ready to ship, further
 * down the same page, lists only the ones after these, so no part is shown
 * twice.
 */
export const PRECALL_REORDERS_SHOWN = 3

/**
 * "Bought 6 in Jul 2026 · 40 available" — one reorder candidate, plus their
 * rhythm when it is due ("· buys about every 3 months"): the reason it is
 * due, in the dealer's own terms.
 */
export function boughtLine(r: {
  last_qty: number
  last_bought_month: string
  ats_qty: number
  is_due?: boolean | null
  median_months_between_buys?: number | null
}): string {
  const d = parseISO(r.last_bought_month)
  const month = Number.isNaN(d.getTime()) ? r.last_bought_month : format(d, 'MMM yyyy')
  const parts = [`Bought ${count(r.last_qty)} in ${month}`, `${count(r.ats_qty)} available`]
  const gap = r.median_months_between_buys
  if (r.is_due && gap != null && gap >= 1) {
    const months = Math.round(gap)
    parts.push(months === 1 ? 'buys about monthly' : `buys about every ${months} months`)
  }
  return parts.join(' · ')
}
