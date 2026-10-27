import {
  addDays,
  differenceInCalendarDays,
  format,
  parseISO,
  startOfMonth,
  startOfQuarter,
  startOfWeek,
  startOfYear,
} from 'date-fns'

/**
 * The two book lists outside reps used to pull from Tableau — Open orders
 * (G03, public.v_open_order_lines) and Shipments (G04,
 * public.report_book_shipments) — as pure functions: filtering, grouping,
 * totals and the shipment date windows. The pages (pages/intel/
 * OpenOrdersIntel.vue, ShipmentsIntel.vue) only wire these to the screen;
 * tests/unit/bookLists.test.ts pins them.
 *
 * Money words: an open line's dollars are "Open $" (unshipped order value),
 * a shipment's are "Shipped value" (packlist value). Neither is revenue —
 * revenue is invoiced only, and shipping runs ahead of invoicing.
 */

/* ------------------------------------------------------------- rows */

/** One open order line — public.v_open_order_lines (20261027090600), in its column order. */
export interface OpenOrderLine {
  customer_key: string
  customer_id: string | null
  customer_name: string | null
  customer_reporting_name: string | null
  assigned_sales_rep_id: string | null
  assigned_sales_rep_name: string | null
  order_id: string
  line_num: number
  order_date: string | null
  customer_po_number: string | null
  /** R / F / H — Released, Firmed, Hold (closed and cancelled lines are never open). */
  order_status: string | null
  order_status_desc: string | null
  /** The dealer's want date — "Want date" on screen. */
  desired_ship_date: string | null
  promise_date: string | null
  part_key: string | null
  part_id: string | null
  part_description: string | null
  /** dim_part.product_code — the product line (Tableau's "Family"). */
  product_code: string | null
  product_family: string | null
  upc: string | null
  /** fact_order_line.product_code: MDF / SUNSET / DEALER EVENT / WARRANTY … */
  program_code: string | null
  unit_price: number | null
  trade_discount_pct: number | null
  backlog_qty: number
  backlog_amount: number
  credit_status: string | null
  /** PO mentions RMA, or the line is a WARRANTY program line. */
  is_rma: boolean
  /** A discount / credit / non-part line (no real part behind it). */
  is_non_part: boolean
  is_past_want: boolean
  is_past_promise: boolean
}

/** One packlist line — public.report_book_shipments() (20261027090600), in its column order. */
export interface BookShipmentLine {
  packlist_id: string
  line_num: number
  ship_date: string | null
  customer_key: string
  customer_name: string | null
  assigned_sales_rep_name: string | null
  order_id: string | null
  order_line_no: number | null
  customer_po_number: string | null
  part_id: string | null
  part_description: string | null
  product_code: string | null
  shipped_qty: number
  unit_price: number | null
  trade_discount_pct: number | null
  /** Packlist value of the line: qty × price net of trade discount. Not revenue. */
  shipped_value: number
  invoice_id: string | null
  invoice_status: string | null
  ship_via: string | null
  tracking_number: string | null
  ship_to_name: string | null
  ship_to_city: string | null
  ship_to_state: string | null
}

function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

function numOrNull(value: unknown): number | null {
  if (value == null) return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function str(value: unknown): string | null {
  return value == null || value === '' ? null : String(value)
}

/** PostgREST row → OpenOrderLine; numerics can arrive as strings. */
export function mapOpenOrderLine(r: Record<string, unknown>): OpenOrderLine {
  return {
    customer_key: String(r.customer_key),
    customer_id: str(r.customer_id),
    customer_name: str(r.customer_name),
    customer_reporting_name: str(r.customer_reporting_name),
    assigned_sales_rep_id: str(r.assigned_sales_rep_id),
    assigned_sales_rep_name: str(r.assigned_sales_rep_name),
    order_id: String(r.order_id),
    line_num: num(r.line_num),
    order_date: str(r.order_date),
    customer_po_number: str(r.customer_po_number),
    order_status: str(r.order_status),
    order_status_desc: str(r.order_status_desc),
    desired_ship_date: str(r.desired_ship_date),
    promise_date: str(r.promise_date),
    part_key: str(r.part_key),
    part_id: str(r.part_id),
    part_description: str(r.part_description),
    product_code: str(r.product_code),
    product_family: str(r.product_family),
    upc: str(r.upc),
    program_code: str(r.program_code),
    unit_price: numOrNull(r.unit_price),
    trade_discount_pct: numOrNull(r.trade_discount_pct),
    backlog_qty: num(r.backlog_qty),
    backlog_amount: num(r.backlog_amount),
    credit_status: str(r.credit_status),
    is_rma: r.is_rma === true,
    is_non_part: r.is_non_part === true,
    is_past_want: r.is_past_want === true,
    is_past_promise: r.is_past_promise === true,
  }
}

/** PostgREST row → BookShipmentLine. */
export function mapBookShipmentLine(r: Record<string, unknown>): BookShipmentLine {
  return {
    packlist_id: String(r.packlist_id),
    line_num: num(r.line_num),
    ship_date: str(r.ship_date),
    customer_key: String(r.customer_key),
    customer_name: str(r.customer_name),
    assigned_sales_rep_name: str(r.assigned_sales_rep_name),
    order_id: str(r.order_id),
    order_line_no: numOrNull(r.order_line_no),
    customer_po_number: str(r.customer_po_number),
    part_id: str(r.part_id),
    part_description: str(r.part_description),
    product_code: str(r.product_code),
    shipped_qty: num(r.shipped_qty),
    unit_price: numOrNull(r.unit_price),
    trade_discount_pct: numOrNull(r.trade_discount_pct),
    shipped_value: num(r.shipped_value),
    invoice_id: str(r.invoice_id),
    invoice_status: str(r.invoice_status),
    ship_via: str(r.ship_via),
    tracking_number: str(r.tracking_number),
    ship_to_name: str(r.ship_to_name),
    ship_to_city: str(r.ship_to_city),
    ship_to_state: str(r.ship_to_state),
  }
}

/* ---------------------------------------------------------- shared */

const naturally = (a: string, b: string) =>
  a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' })

/** Released / Firmed / Hold from the ERP code; the ERP's own words otherwise. */
export function orderStatusLabel(code: string | null, desc?: string | null): string {
  switch ((code ?? '').trim().toUpperCase()) {
    case 'R':
      return 'Released'
    case 'F':
      return 'Firmed'
    case 'H':
      return 'Hold'
  }
  return desc?.trim() || code?.trim() || '—'
}

/** One figure in a book list's totals strip (components/BookListCard.vue). */
export interface BookListTotal {
  label: string
  value: string
}

export interface SelectOption {
  value: string
  label: string
}

/**
 * The distinct non-blank values of one field, for a filter dropdown, sorted
 * by label (numbers in number order). `label` defaults to the value.
 */
export function distinctOptions<T>(
  rows: readonly T[],
  value: (r: T) => string | null | undefined,
  label: (r: T) => string = (r) => value(r) ?? '',
): SelectOption[] {
  const seen = new Map<string, string>()
  for (const r of rows) {
    const v = (value(r) ?? '').trim()
    if (v && !seen.has(v)) seen.set(v, label(r) || v)
  }
  return [...seen.entries()]
    .map(([v, l]) => ({ value: v, label: l }))
    .sort((a, b) => naturally(a.label, b.label))
}

/**
 * The options, plus the active choice when the data no longer has it — a
 * new shipment window without the account the rep had picked. Without it
 * the dropdown would show "All" while its filter still empties the list.
 */
export function withActive(options: SelectOption[], active: string): SelectOption[] {
  if (!active || options.some((o) => o.value === active)) return options
  return [...options, { value: active, label: active }]
}

/**
 * The rows that start a group, in the order shown: a row whose key differs
 * from the row above it. The grid is flat (and the rep can re-sort it), so
 * "grouped by account → order" is drawn by printing the account and order
 * only on the first row of each run. Sort by something else and the runs
 * break up — every row then names its own account, which is what a re-sorted
 * list should do. Rows are compared by identity: pass the very rows the grid
 * emitted.
 */
export function groupStarts<T>(rows: readonly T[], key: (r: T) => string): Set<T> {
  const out = new Set<T>()
  let previous: string | undefined
  rows.forEach((r, i) => {
    const k = key(r)
    if (i === 0 || k !== previous) out.add(r)
    previous = k
  })
  return out
}

/* ------------------------------------------------------ open orders */

export interface OpenOrderFilters {
  /** customer_key, or '' for every account. */
  account: string
  /** assigned_sales_rep_id, or '' for every rep. */
  rep: string
  /** product_code, or ''. */
  productLine: string
  /** 'Released' | 'Firmed' | 'Hold' (orderStatusLabel), or ''. */
  status: string
  /** Only lines whose want date has passed. */
  pastWantOnly: boolean
  /** Drop RMA / warranty lines — on by default: a return is not a sale to chase. */
  hideRma: boolean
  /** Drop discount / credit lines (no real part). Off by default: the book's
   *  open total is net of them, the same as the Overview's Open Orders tile. */
  hideNonPart: boolean
}

export const DEFAULT_OPEN_ORDER_FILTERS: Readonly<OpenOrderFilters> = {
  account: '',
  rep: '',
  productLine: '',
  status: '',
  pastWantOnly: false,
  hideRma: true,
  hideNonPart: false,
}

export function filterOpenOrders(
  rows: readonly OpenOrderLine[],
  f: OpenOrderFilters,
): OpenOrderLine[] {
  return rows.filter(
    (r) =>
      (!f.account || r.customer_key === f.account) &&
      (!f.rep || r.assigned_sales_rep_id === f.rep) &&
      (!f.productLine || r.product_code === f.productLine) &&
      (!f.status || orderStatusLabel(r.order_status, r.order_status_desc) === f.status) &&
      (!f.pastWantOnly || r.is_past_want) &&
      (!f.hideRma || !r.is_rma) &&
      (!f.hideNonPart || !r.is_non_part),
  )
}

/** Account (by id, then name), then order number, then line: the grouped order. */
export function sortOpenOrders(rows: readonly OpenOrderLine[]): OpenOrderLine[] {
  return [...rows].sort(
    (a, b) =>
      naturally(a.customer_id ?? a.customer_key, b.customer_id ?? b.customer_key) ||
      naturally(a.customer_key, b.customer_key) ||
      naturally(a.order_id, b.order_id) ||
      a.line_num - b.line_num,
  )
}

export const orderKey = (r: Pick<OpenOrderLine, 'customer_key' | 'order_id'>) =>
  `${r.customer_key}|${r.order_id}`

export interface OpenOrderTotals {
  lines: number
  orders: number
  accounts: number
  qty: number
  amount: number
  /** Open $ on lines whose want date has passed. */
  pastWantAmount: number
}

export function openOrderTotals(rows: readonly OpenOrderLine[]): OpenOrderTotals {
  const orders = new Set<string>()
  const accounts = new Set<string>()
  let qty = 0
  let amount = 0
  let pastWantAmount = 0
  for (const r of rows) {
    orders.add(orderKey(r))
    accounts.add(r.customer_key)
    qty += r.backlog_qty
    amount += r.backlog_amount
    if (r.is_past_want) pastWantAmount += r.backlog_amount
  }
  return { lines: rows.length, orders: orders.size, accounts: accounts.size, qty, amount, pastWantAmount }
}

/** Per-account and per-order subtotals, for the first row of each group. */
export function openOrderSubtotals(rows: readonly OpenOrderLine[]): {
  byAccount: Map<string, { orders: number; lines: number; amount: number }>
  byOrder: Map<string, { lines: number; amount: number }>
} {
  const accountOrders = new Map<string, Set<string>>()
  const byAccount = new Map<string, { orders: number; lines: number; amount: number }>()
  const byOrder = new Map<string, { lines: number; amount: number }>()
  for (const r of rows) {
    const a = byAccount.get(r.customer_key) ?? { orders: 0, lines: 0, amount: 0 }
    const set = accountOrders.get(r.customer_key) ?? new Set<string>()
    set.add(r.order_id)
    accountOrders.set(r.customer_key, set)
    a.lines += 1
    a.amount += r.backlog_amount
    a.orders = set.size
    byAccount.set(r.customer_key, a)
    const k = orderKey(r)
    const o = byOrder.get(k) ?? { lines: 0, amount: 0 }
    o.lines += 1
    o.amount += r.backlog_amount
    byOrder.set(k, o)
  }
  return { byAccount, byOrder }
}

/* -------------------------------------------------------- shipments */

export type ShipmentPreset = 'ytd' | 'last-year' | 'qtd' | 'mtd' | 'last-week' | 'custom'

export const SHIPMENT_PRESETS: readonly { value: ShipmentPreset; label: string }[] = [
  { value: 'ytd', label: 'This year' },
  { value: 'last-year', label: 'Last year' },
  { value: 'qtd', label: 'Quarter to date' },
  { value: 'mtd', label: 'Month to date' },
  { value: 'last-week', label: 'Last week' },
  { value: 'custom', label: 'Custom' },
]

export interface DateRange {
  /** yyyy-MM-dd, inclusive. */
  from: string
  /** yyyy-MM-dd, inclusive. */
  to: string
}

const ymd = (d: Date) => format(d, 'yyyy-MM-dd')

/**
 * The window a preset means on `today`, in the rep's own calendar. "Last
 * week" is the previous Monday to Sunday — the week a dealer means when they
 * say it, not the trailing seven days. Custom has no window of its own; the
 * page passes the two dates the rep picked (see rangeProblem).
 */
export function presetRange(preset: Exclude<ShipmentPreset, 'custom'>, today: Date): DateRange {
  switch (preset) {
    case 'ytd':
      return { from: ymd(startOfYear(today)), to: ymd(today) }
    case 'last-year': {
      const y = today.getFullYear() - 1
      return { from: `${y}-01-01`, to: `${y}-12-31` }
    }
    case 'qtd':
      return { from: ymd(startOfQuarter(today)), to: ymd(today) }
    case 'mtd':
      return { from: ymd(startOfMonth(today)), to: ymd(today) }
    case 'last-week': {
      const thisMonday = startOfWeek(today, { weekStartsOn: 1 })
      const lastMonday = addDays(thisMonday, -7)
      return { from: ymd(lastMonday), to: ymd(addDays(lastMonday, 6)) }
    }
  }
}

/**
 * The longest custom window, in days counted inclusively (Jan 1 to Jan 1 is
 * one day). The function refuses a span over 400 days (the 8 s statement
 * timeout, and a principal's book over several years is too many rows for a
 * phone). 400 inclusive days is a 399-day difference, so however the
 * function counts its span, a window this page allows never comes back as a
 * server error.
 */
export const MAX_SHIPMENT_SPAN_DAYS = 400

/** Why a custom window can't be asked for, or null when it can. */
export function rangeProblem(from: string, to: string): string | null {
  if (!from || !to) return 'Pick a start and an end date.'
  const a = parseISO(from)
  const b = parseISO(to)
  if (Number.isNaN(a.getTime()) || Number.isNaN(b.getTime())) return 'Those dates are not valid.'
  const days = differenceInCalendarDays(b, a) + 1
  if (days < 1) return 'The start date is after the end date.'
  if (days > MAX_SHIPMENT_SPAN_DAYS) {
    return `Pick ${MAX_SHIPMENT_SPAN_DAYS} days or fewer. For longer, export one year at a time.`
  }
  return null
}

export interface ShipmentFilters {
  /** customer_key, or ''. */
  account: string
  /** assigned_sales_rep_name, or '' (the function carries the name, not the id). */
  rep: string
  /** product_code, or ''. */
  productLine: string
}

export function filterShipments(
  rows: readonly BookShipmentLine[],
  f: ShipmentFilters,
): BookShipmentLine[] {
  return rows.filter(
    (r) =>
      (!f.account || r.customer_key === f.account) &&
      (!f.rep || r.assigned_sales_rep_name === f.rep) &&
      (!f.productLine || r.product_code === f.productLine),
  )
}

/** Newest ship date first, then packlist and line: a total order. */
export function sortShipments(rows: readonly BookShipmentLine[]): BookShipmentLine[] {
  return [...rows].sort(
    (a, b) =>
      (b.ship_date ?? '').localeCompare(a.ship_date ?? '') ||
      naturally(b.packlist_id, a.packlist_id) ||
      a.line_num - b.line_num,
  )
}

/** One packlist, rolled up from its lines — the "Packlist" grain. */
export interface PacklistRow {
  key: string
  packlist_id: string
  customer_key: string
  customer_name: string | null
  assigned_sales_rep_name: string | null
  ship_date: string | null
  /** Distinct values, comma-joined, in line order. */
  order_ids: string
  customer_po_numbers: string
  product_codes: string
  invoice_ids: string
  /** Lines on the packlist with no invoice yet. */
  uninvoiced_lines: number
  tracking_numbers: string
  ship_via: string | null
  ship_to_name: string | null
  ship_to_city: string | null
  ship_to_state: string | null
  line_count: number
  shipped_qty: number
  shipped_value: number
}

function joinDistinct(values: (string | null)[]): string {
  return [...new Set(values.flatMap((v) => (v ?? '').split(',').map((x) => x.trim())).filter(Boolean))].join(', ')
}

/**
 * Lines → one row per packlist, in the order the packlists first appear
 * (so a list sorted newest-first stays newest-first). Done here, not in
 * SQL: the lines are already on the phone for the Line grain, and the
 * toggle should cost nothing. Filters apply to lines first — a packlist
 * filtered by product line totals only that product line's lines.
 */
export function groupPacklists(rows: readonly BookShipmentLine[]): PacklistRow[] {
  const byKey = new Map<string, { head: BookShipmentLine; lines: BookShipmentLine[] }>()
  for (const r of rows) {
    const key = `${r.customer_key}|${r.packlist_id}`
    const g = byKey.get(key)
    if (g) g.lines.push(r)
    else byKey.set(key, { head: r, lines: [r] })
  }
  return [...byKey.entries()].map(([key, { head, lines }]) => ({
    key,
    packlist_id: head.packlist_id,
    customer_key: head.customer_key,
    customer_name: head.customer_name,
    assigned_sales_rep_name: head.assigned_sales_rep_name,
    ship_date: lines.reduce<string | null>(
      (min, l) => (l.ship_date && (!min || l.ship_date < min) ? l.ship_date : min),
      null,
    ),
    order_ids: joinDistinct(lines.map((l) => l.order_id)),
    customer_po_numbers: joinDistinct(lines.map((l) => l.customer_po_number)),
    product_codes: joinDistinct(lines.map((l) => l.product_code)),
    invoice_ids: joinDistinct(lines.map((l) => l.invoice_id)),
    uninvoiced_lines: lines.filter((l) => !l.invoice_id).length,
    tracking_numbers: joinDistinct(lines.map((l) => l.tracking_number)),
    ship_via: head.ship_via,
    ship_to_name: head.ship_to_name,
    ship_to_city: head.ship_to_city,
    ship_to_state: head.ship_to_state,
    line_count: lines.length,
    shipped_qty: lines.reduce((a, l) => a + l.shipped_qty, 0),
    shipped_value: lines.reduce((a, l) => a + l.shipped_value, 0),
  }))
}

export interface ShipmentTotals {
  lines: number
  packlists: number
  accounts: number
  qty: number
  value: number
}

/** Totals over either grain: a packlist row counts its line_count, a line counts 1. */
export function shipmentTotals(
  rows: readonly (Pick<BookShipmentLine, 'customer_key' | 'packlist_id' | 'shipped_qty' | 'shipped_value'> & {
    line_count?: number
  })[],
): ShipmentTotals {
  const packlists = new Set<string>()
  const accounts = new Set<string>()
  let lines = 0
  let qty = 0
  let value = 0
  for (const r of rows) {
    packlists.add(`${r.customer_key}|${r.packlist_id}`)
    accounts.add(r.customer_key)
    lines += r.line_count ?? 1
    qty += r.shipped_qty
    value += r.shipped_value
  }
  return { lines, packlists: packlists.size, accounts: accounts.size, qty, value }
}

/** "Plano, TX" from whatever parts are present; the name leads when asked. */
export function shipToText(
  r: Pick<BookShipmentLine, 'ship_to_name' | 'ship_to_city' | 'ship_to_state'>,
  withName = true,
): string {
  const place = [r.ship_to_city, r.ship_to_state].filter(Boolean).join(', ')
  return [withName ? r.ship_to_name : null, place].filter(Boolean).join(' · ')
}
