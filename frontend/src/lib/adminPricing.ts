/**
 * Hand-priced ("admin-priced": price_source = 'admin') and unmatched order
 * lines (20261111170000) — the pure rules the portal applies around them,
 * unit tested in tests/unit/adminPricing.test.ts.
 *
 * An admin's or inside sales' Claude can stage a customer PO as it was sent:
 * parts on no price list, prices that are not the published price, even item
 * numbers that match no part. The database is the authority — submit_order()
 * refuses unmatched lines outright, and hand-priced ones unless someone who
 * may price orders (can_price_orders(): an admin or inside sales,
 * 20261113090000) submits with the acknowledgement; a trigger stops anyone
 * writing those lines directly. What lives here only decides what the screen
 * SHOWS and OFFERS.
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
export function blocksWriterEdit(lines: PricedLine[]): boolean {
  return lines.some((l) => l.price_source === 'admin' || !!l.part_unresolved)
}

/**
 * Why Submit is not offered, in words, or '' when pricing allows it. Same
 * rules as submit_order(): unmatched lines never submit; hand-priced lines
 * need someone who may price orders — `canPriceOrders` is
 * session.canPriceOrders, an admin or inside sales (the acknowledgement is
 * the review block's checkbox). Who OWNS the order is a separate rule the
 * page applies: submit_order() takes it only from its owner or an admin.
 */
export function pricingSubmitBlock(lines: PricedLine[], canPriceOrders: boolean): string {
  const s = pricingSummary(lines)
  if (s.unmatched > 0) {
    return `${s.unmatched} line${s.unmatched === 1 ? '' : 's'} match no part. Ask Claude to correct ${s.unmatched === 1 ? 'it' : 'them'}, or remove ${s.unmatched === 1 ? 'it' : 'them'}, before submitting.`
  }
  if (s.adminLines > 0 && !canPriceOrders) {
    return 'This order has hand-priced lines, so only an admin or inside sales can submit it.'
  }
  return ''
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
