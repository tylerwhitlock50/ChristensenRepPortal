import { format, isSameYear, parseISO } from 'date-fns'

/**
 * "Where's my order?" — the answer, in words a dealer can read.
 *
 * Lookup already tells the REP where an order stands. The rep then has to
 * say it again to the dealer, usually by retyping it into a text while the
 * dealer waits. This composes that text: their PO (the number they are
 * holding), our order number, what shipped, what is still open and when it
 * is expected, and a tracking link per parcel. Plain text, no emoji, short
 * lines — it lands in Messages, WhatsApp or an email body unchanged.
 *
 * Pure functions plus two thin browser wrappers (shareOrCopy, smsPlatform),
 * so the wording is unit tested (tests/unit/orderStatusMessage.test.ts).
 */

/* ---------------------------------------------------------------- tracking */

/** UPS is the only carrier; the number goes straight to their tracking page. */
export function upsTrackUrl(trackingNumber: string): string {
  return `https://www.ups.com/track?tracknum=${encodeURIComponent(trackingNumber.trim())}`
}

/** A row can carry several parcels' numbers, comma-joined by the database. */
export function trackingList(value: string | null | undefined): string[] {
  return [
    ...new Set(
      (value ?? '')
        .split(',')
        .map((v) => v.trim())
        .filter(Boolean),
    ),
  ]
}

/* ------------------------------------------------------------------ shapes */

/** The header-level facts — a lookup_orders() row satisfies this. */
export interface StatusOrder {
  order_id: string
  customer_po_number: string | null
  order_date: string | null
  order_status_desc?: string | null
  line_count: number
  open_line_count: number
  next_promise_date: string | null
  next_desired_ship_date: string | null
  tracking_numbers: string | null
  last_ship_date: string | null
}

/** One order line — a v_account_order_lines row satisfies this. */
export interface StatusLine {
  line_num: number
  part_id: string | null
  part_description: string | null
  order_qty: number | null
  backlog_qty: number | null
  is_backlog_line: boolean | null
  total_shipped_qty_to_date: number | null
  promise_date: string | null
  desired_ship_date: string | null
  /** Appended to the view by 20261013150000; absent on older databases. */
  tracking_numbers?: string | null
}

export interface StatusMessageOptions {
  /** The order's lines when they are loaded; the message is richer with them. */
  lines?: StatusLine[] | null
  /** Who is sending it — the rep's first name, for the sign-off. */
  from?: string | null
  /** For tests; dates in the current year drop the year. */
  today?: Date
}

/** How many tracking links a text carries before it says "+N more". */
export const MAX_TRACKING_LINKS = 3

/* ------------------------------------------------------------------ pieces */

function day(value: string | null | undefined, today: Date): string | null {
  if (!value) return null
  const d = parseISO(value)
  if (Number.isNaN(d.getTime())) return null
  return format(d, isSameYear(d, today) ? 'MMM d' : 'MMM d, yyyy')
}

function qty(value: number | null | undefined): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

/** "Mesa 6.5 Creedmoor 22in" — the dealer's words, falling back to our SKU. */
function partLabel(l: StatusLine): string {
  const desc = (l.part_description ?? '').trim()
  const id = (l.part_id ?? '').trim()
  return desc || id || `Line ${l.line_num}`
}

/** "your PO 44182 (our order SO-88412, placed Oct 3)" */
function orderPhrase(o: StatusOrder, today: Date): string {
  const placed = day(o.order_date, today)
  const ours = `our order ${o.order_id}${placed ? `, placed ${placed}` : ''}`
  return o.customer_po_number
    ? `your PO ${o.customer_po_number} (${ours})`
    : `${ours.charAt(0).toUpperCase()}${ours.slice(1)}`
}

/** When an open line is expected, in the order a dealer trusts it. */
function whenLine(
  promise: string | null | undefined,
  desired: string | null | undefined,
  today: Date,
): string {
  const p = day(promise, today)
  if (p) return `promised ${p}`
  const d = day(desired, today)
  if (d) return `est. production ${d}`
  return 'no date yet'
}

function isCancelled(o: StatusOrder): boolean {
  return /cancel/i.test(o.order_status_desc ?? '')
}

function trackingBlock(numbers: string[]): string[] {
  if (numbers.length === 0) return []
  const shown = numbers.slice(0, MAX_TRACKING_LINKS)
  const out = [shown.length === 1 ? 'Track it:' : 'Track them:']
  for (const n of shown) out.push(upsTrackUrl(n))
  if (numbers.length > shown.length) {
    out.push(`+${numbers.length - shown.length} more parcels`)
  }
  return out
}

/* --------------------------------------------------------------- messages */

/**
 * The dealer-ready status of one order. With `lines`, it lists what shipped
 * and what is still open part by part; without, it says the same at order
 * level from the lookup row alone (Lookup shares before lines are opened).
 */
export function orderStatusMessage(
  order: StatusOrder,
  opts: StatusMessageOptions = {},
): string {
  const today = opts.today ?? new Date()
  const lines = opts.lines ?? null
  const out: string[] = [`Christensen Arms order update: ${orderPhrase(order, today)}.`]

  if (isCancelled(order)) {
    out.push('This order is cancelled.')
  } else if (lines && lines.length > 0) {
    const shipped = lines.filter((l) => qty(l.total_shipped_qty_to_date) > 0)
    const open = lines.filter((l) => l.is_backlog_line && qty(l.backlog_qty) > 0)
    if (shipped.length > 0) {
      out.push('', 'Shipped:')
      for (const l of shipped) {
        out.push(`- ${partLabel(l)} x ${qty(l.total_shipped_qty_to_date)}`)
      }
    }
    if (open.length > 0) {
      out.push('', 'Still open:')
      for (const l of open) {
        out.push(
          `- ${partLabel(l)} x ${qty(l.backlog_qty)}, ${whenLine(l.promise_date, l.desired_ship_date, today)}`,
        )
      }
    }
    if (shipped.length === 0 && open.length === 0) out.push('Nothing open on this order.')
  } else if (order.open_line_count > 0) {
    const n = order.open_line_count
    const of = order.line_count > n ? ` of ${order.line_count}` : ''
    const when = whenLine(order.next_promise_date, order.next_desired_ship_date, today)
    const plural = of || n !== 1 ? 's' : ''
    out.push(
      `${n}${of} line${plural} still open, ` +
        (when === 'no date yet' ? 'no ship date yet.' : `next ${when}.`),
    )
    const last = day(order.last_ship_date, today)
    if (last) out.push(`Last shipment went out ${last}.`)
  } else {
    const last = day(order.last_ship_date, today)
    out.push(last ? `Shipped complete, last on ${last}.` : 'Nothing open on this order.')
  }

  // Per-line numbers when the lines carry them (20261013150000), else the
  // order's. Either way each parcel once.
  const fromLines = trackingList(
    (lines ?? []).map((l) => l.tracking_numbers ?? '').join(','),
  )
  const numbers = fromLines.length > 0 ? fromLines : trackingList(order.tracking_numbers)
  const tracking = trackingBlock(numbers)
  if (tracking.length > 0) out.push('', ...tracking)

  if (opts.from?.trim()) out.push('', `- ${opts.from.trim()}`)
  return out.join('\n')
}

/** What the activity feed's "Send tracking" composes for one shipment. */
export interface StatusShipment {
  order_id: string | null
  customer_po_number?: string | null
  ship_date: string | null
  tracking_numbers: string | null
}

export function shipmentMessage(
  s: StatusShipment,
  opts: { from?: string | null; today?: Date } = {},
): string {
  const today = opts.today ?? new Date()
  const what = s.customer_po_number
    ? `your PO ${s.customer_po_number}${s.order_id ? ` (our order ${s.order_id})` : ''}`
    : s.order_id
      ? `your order ${s.order_id}`
      : 'your order'
  const when = day(s.ship_date, today)
  const out = [`Christensen Arms shipping update: ${what} shipped${when ? ` ${when}` : ''}.`]
  const tracking = trackingBlock(trackingList(s.tracking_numbers))
  if (tracking.length > 0) out.push('', ...tracking)
  if (opts.from?.trim()) out.push('', `- ${opts.from.trim()}`)
  return out.join('\n')
}

/** The sign-off name: a rep's first name, never their email. */
export function senderName(displayName: string | null | undefined): string | null {
  const first = (displayName ?? '').trim().split(/\s+/)[0] ?? ''
  if (!first || first.includes('@')) return null
  return first
}

/* --------------------------------------------------------------------- sms */

export type SmsPlatform = 'ios' | 'other'

/**
 * iOS reads the body after `&`, Android (and everything else) after `?`.
 * iPadOS reports itself as a Mac, so a touch-capable "Mac" is an iPad.
 */
export function smsPlatform(
  userAgent: string = typeof navigator === 'undefined' ? '' : navigator.userAgent,
  maxTouchPoints: number = typeof navigator === 'undefined' ? 0 : navigator.maxTouchPoints,
): SmsPlatform {
  if (/iPhone|iPad|iPod/i.test(userAgent)) return 'ios'
  if (/Macintosh/i.test(userAgent) && maxTouchPoints > 1) return 'ios'
  return 'other'
}

/**
 * The number a text can go to: the main line without its extension (a
 * desk's "x204" means nothing to Messages), digits and a leading + only.
 * Null when fewer than 7 digits remain — the same floor as lib/contacts.
 */
export function smsNumber(phone: string | null | undefined): string | null {
  const main = (phone ?? '').replace(/\s*(?:x|ext\.?|extension)\s*\d+\s*$/i, '')
  const plus = main.trim().startsWith('+') ? '+' : ''
  const digits = main.replace(/\D/g, '')
  return digits.length >= 7 ? `${plus}${digits}` : null
}

export function smsHref(
  phone: string | null | undefined,
  body: string,
  platform: SmsPlatform,
): string | null {
  const to = smsNumber(phone)
  if (!to) return null
  const sep = platform === 'ios' ? '&' : '?'
  return `sms:${to}${sep}body=${encodeURIComponent(body)}`
}

/* ------------------------------------------------------------------- share */

export type ShareOutcome = 'shared' | 'copied' | 'cancelled' | 'failed'

type ShareNavigator = {
  share?: (data: { text?: string }) => Promise<void>
  canShare?: (data: { text?: string }) => boolean
  clipboard?: { writeText: (text: string) => Promise<void> }
}

/**
 * The phone's share sheet when there is one (Messages, WhatsApp, Mail —
 * whatever the rep uses with that dealer), otherwise the clipboard, with
 * the textarea fallback from ConnectView for Safari without a gesture or an
 * insecure origin. A dismissed share sheet is 'cancelled', not a failure.
 *
 * Call it straight from the tap handler: Safari only opens the share sheet
 * inside the user gesture, so nothing may be awaited before it.
 */
export async function shareOrCopy(
  text: string,
  nav: ShareNavigator = navigator as unknown as ShareNavigator,
  doc: Document | null = typeof document === 'undefined' ? null : document,
): Promise<ShareOutcome> {
  if (typeof nav.share === 'function' && (!nav.canShare || nav.canShare({ text }))) {
    try {
      await nav.share({ text })
      return 'shared'
    } catch (e) {
      if ((e as { name?: string } | null)?.name === 'AbortError') return 'cancelled'
      // NotAllowedError and friends: fall through to the clipboard.
    }
  }
  try {
    if (!nav.clipboard) throw new Error('no clipboard')
    await nav.clipboard.writeText(text)
    return 'copied'
  } catch {
    if (!doc) return 'failed'
    const field = doc.createElement('textarea')
    field.value = text
    doc.body.appendChild(field)
    field.select()
    const ok = doc.execCommand('copy')
    field.remove()
    return ok ? 'copied' : 'failed'
  }
}
