/**
 * Hand-priced ("admin-priced": price_source = 'admin') and unmatched order
 * lines (20261111170000) — the pure rules the portal applies around them,
 * unit tested in tests/unit/adminPricing.test.ts.
 *
 * An admin's or inside sales' Claude can stage a customer PO as it was sent:
 * parts on no price list, prices that are not the published price, even item
 * numbers that match no part. The database is the authority — submit_order()
 * refuses unmatched lines outright, and hand-priced ones unless someone who
 * may price THIS order submits it with the acknowledgement: an admin, or
 * inside sales on their own order (can_price_orders() plus submit_order()'s
 * owner-or-admin rule, 20261113090000; admin_set_order_line_price() holds a
 * price change to the same two). A trigger stops anyone writing those lines
 * directly. What lives here only decides what the screen SHOWS and OFFERS.
 *
 * A hand-priced order may carry the same part on two lines at different
 * prices (10 paid and 1 free), so a line is always identified by its id,
 * never by its part.
 */

/** The line columns these rules read (a subset of OrderLineRow). */
export interface PricedLine {
  id: number
  part_id: string
  description: string | null
  qty: number
  unit_price: number
  price_source?: 'list' | 'admin' | null
  list_unit_price?: number | null
  customer_part_ref?: string | null
  customer_description?: string | null
  part_unresolved?: boolean | null
  last_paid_price?: number | null
  last_paid_date?: string | null
  description_mismatch?: boolean | null
}

export type LineFlag = 'unmatched' | 'off_list' | 'not_list_price' | 'check_description' | 'vs_last_paid'

/** Why a line needs a look, most serious first. Empty = a plain list line. */
export function lineFlags(l: PricedLine): LineFlag[] {
  const out: LineFlag[] = []
  if (l.part_unresolved) out.push('unmatched')
  if (l.price_source === 'admin' && !l.part_unresolved) {
    out.push(l.list_unit_price == null ? 'off_list' : 'not_list_price')
  }
  if (l.description_mismatch) out.push('check_description')
  if (
    l.price_source === 'admin' &&
    l.last_paid_price != null &&
    Number(l.last_paid_price) !== Number(l.unit_price)
  ) {
    out.push('vs_last_paid')
  }
  return out
}

export const FLAG_LABEL: Record<LineFlag, string> = {
  unmatched: 'No matching part',
  off_list: 'Not on a price list',
  not_list_price: 'Not the list price',
  check_description: 'Check description',
  vs_last_paid: 'Differs from last paid',
}

/** A line the review block lists. */
export function isFlagged(l: PricedLine): boolean {
  return lineFlags(l).length > 0
}

/**
 * The lines the review block shows, each with its flags. Only the flagged
 * ones to look at; every line when the viewer may set prices (`all`), so a
 * price can be set on a line at list price, or put back on one reset by
 * mistake, which then no longer carries a flag.
 */
export function reviewLines<T extends PricedLine>(lines: readonly T[], all: boolean): { line: T; flags: LineFlag[] }[] {
  return lines
    .map((line) => ({ line, flags: lineFlags(line) }))
    .filter((x) => all || x.flags.length > 0)
}

/**
 * Whether this viewer may price this order by hand, and so submit it with
 * hand-priced lines: an admin on any order, inside sales (canPriceOrders)
 * on an order they own. Mirrors admin_set_order_line_price() (not_owner)
 * and submit_order() (owner or admin, then can_price_orders()), so whoever
 * can set a price can also submit the result.
 */
export function mayPriceOrder(viewer: {
  isAdmin: boolean
  isOwner: boolean
  canPriceOrders: boolean
}): boolean {
  return viewer.isAdmin || (viewer.isOwner && viewer.canPriceOrders)
}

export interface PricingSummary {
  lines: number
  adminLines: number
  offList: number
  notListPrice: number
  unmatched: number
  descriptionChecks: number
  adminValue: number
  /** Sum of qty × (list − admin price) over admin lines that have a list price. */
  belowList: number
}

export function pricingSummary(lines: PricedLine[]): PricingSummary {
  const s: PricingSummary = {
    lines: lines.length,
    adminLines: 0,
    offList: 0,
    notListPrice: 0,
    unmatched: 0,
    descriptionChecks: 0,
    adminValue: 0,
    belowList: 0,
  }
  for (const l of lines) {
    if (l.part_unresolved) s.unmatched++
    if (l.description_mismatch) s.descriptionChecks++
    if (l.price_source !== 'admin') continue
    s.adminLines++
    s.adminValue += l.qty * Number(l.unit_price)
    if (l.part_unresolved) continue
    if (l.list_unit_price == null) s.offList++
    else {
      s.notListPrice++
      s.belowList += l.qty * (Number(l.list_unit_price) - Number(l.unit_price))
    }
  }
  s.adminValue = Math.round(s.adminValue * 100) / 100
  s.belowList = Math.round(s.belowList * 100) / 100
  return s
}

/** Anything the review block has to show. */
export function needsPricingReview(lines: PricedLine[]): boolean {
  return lines.some(isFlagged)
}

/**
 * Lines the order writer must not rebuild: it reprices every line from the
 * price lists, which would drop an admin price or an unmatched item.
 */
export function blocksWriterEdit(
  lines: readonly Pick<PricedLine, 'price_source' | 'part_unresolved'>[],
): boolean {
  return lines.some((l) => l.price_source === 'admin' || !!l.part_unresolved)
}

/**
 * Why the order writer must not save over a draft, in words, or ''. Its save
 * deletes every line and writes the screen's copy at list prices, and the
 * screen was filled from a cached read. If Claude (update_order_draft) or a
 * hand price has changed the draft since, saving would silently drop a hand
 * price or a free-goods line. `current` is the database's lines read just
 * before the save; `expectedIds` the line ids the screen was filled with
 * (or last saved).
 */
export function writerSaveRefusal(
  current: readonly (Pick<PricedLine, 'price_source' | 'part_unresolved'> & { id: number })[],
  expectedIds: readonly number[],
): string {
  if (blocksWriterEdit(current)) {
    return (
      'Nothing was saved: this draft now has hand-priced or unmatched lines, which saving here ' +
      'would reprice from the price lists. Open the order page to see it as it is now.'
    )
  }
  const now = current.map((l) => l.id).sort((a, b) => a - b)
  const then = [...expectedIds].sort((a, b) => a - b)
  if (now.length !== then.length || now.some((id, i) => id !== then[i])) {
    return (
      'Nothing was saved: this draft was changed somewhere else since you opened it. ' +
      'Open the order page to see it as it is now, then edit it again.'
    )
  }
  return ''
}

/**
 * Why Submit is not offered, in words, or '' when pricing allows it. Same
 * rules as submit_order(): unmatched lines never submit; hand-priced lines
 * need a viewer who may price this order — `mayPrice` is mayPriceOrder():
 * an admin, or inside sales on their own order (the acknowledgement is the
 * review block's checkbox). The page offers Submit at all only to the
 * order's owner or an admin, as submit_order() does.
 */
export function pricingSubmitBlock(lines: PricedLine[], mayPrice: boolean): string {
  const s = pricingSummary(lines)
  const out: string[] = []
  if (s.unmatched > 0) {
    out.push(
      `${s.unmatched} line${s.unmatched === 1 ? '' : 's'} match no part. Ask Claude to correct ${s.unmatched === 1 ? 'it' : 'them'}, or remove ${s.unmatched === 1 ? 'it' : 'them'}, before submitting.`,
    )
  }
  if (s.adminLines > 0 && !mayPrice) {
    out.push('This order has hand-priced lines, so an admin must submit it.')
  }
  return out.join(' ')
}

/**
 * Hand-priced lines stop THIS viewer submitting, whatever else is fixed:
 * the page then hides the acknowledgement and Submit rather than offer a
 * box that can never enable the button.
 */
export function handPricingStopsSubmit(lines: PricedLine[], mayPrice: boolean): boolean {
  return !mayPrice && pricingSummary(lines).adminLines > 0
}

/**
 * Parse a price typed into the line editor: a non-negative amount with at
 * most two decimals (a leading $ and thousands commas allowed). null when it
 * is not one.
 */
export function parsePriceInput(raw: string): number | null {
  const s = raw.trim().replace(/^\$/, '').replace(/,/g, '')
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null
  const n = Number(s)
  return Number.isFinite(n) && n <= 1_000_000 ? n : null
}
