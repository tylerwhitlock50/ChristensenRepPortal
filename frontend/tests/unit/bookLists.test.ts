/**
 * Unit tests for lib/bookLists.ts — the Open orders (G03) and Shipments
 * (G04) lists on Sales Intel.
 *
 * Run with:  npm run test:unit -- bookLists
 *
 * Pinned: the default filters (RMA/warranty hidden, discount/credit lines
 * kept so the total matches the Overview), the account → order grouping, the
 * totals the strip and the CSV show, the shipment date windows (including
 * "last week" = the previous Monday to Sunday and the 400-day guard), and the
 * packlist roll-up.
 */
import {
  DEFAULT_OPEN_ORDER_FILTERS,
  distinctOptions,
  filterOpenOrders,
  filterShipments,
  groupPacklists,
  groupStarts,
  mapBookShipmentLine,
  mapOpenOrderLine,
  MAX_SHIPMENT_SPAN_DAYS,
  openOrderSubtotals,
  openOrderTotals,
  orderKey,
  orderStatusLabel,
  presetRange,
  rangeProblem,
  shipmentTotals,
  shipToText,
  sortOpenOrders,
  withActive,
  sortShipments,
  type BookShipmentLine,
  type OpenOrderLine,
} from '../../src/lib/bookLists'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(`FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`)
  }
}

/* ---- open orders ------------------------------------------------------- */

const line = (over: Partial<OpenOrderLine>): OpenOrderLine => ({
  customer_key: 'SCHE INC',
  customer_id: 'SCHE INC',
  customer_name: 'Scheels',
  customer_reporting_name: null,
  assigned_sales_rep_id: 'TANY MCDO',
  assigned_sales_rep_name: 'Tanya',
  order_id: 'SO-100',
  line_num: 1,
  order_date: '2026-09-01',
  customer_po_number: 'PO-1',
  order_status: 'R',
  order_status_desc: 'Released',
  desired_ship_date: '2026-11-01',
  promise_date: '2026-11-05',
  part_key: 'P1',
  part_id: 'MPR-65',
  part_description: 'MPR 6.5 Creedmoor',
  product_code: 'FG-RIFLE',
  product_family: 'MPR',
  upc: null,
  program_code: null,
  unit_price: 1999,
  trade_discount_pct: 0,
  backlog_qty: 2,
  backlog_amount: 3998,
  credit_status: null,
  is_rma: false,
  is_non_part: false,
  is_past_want: false,
  is_past_promise: false,
  ...over,
})

t('status: Released / Firmed / Hold from the code', [
  orderStatusLabel('R'),
  orderStatusLabel('f'),
  orderStatusLabel('H', 'On hold'),
], ['Released', 'Firmed', 'Hold'])
t('status: anything else is the ERP\'s own words', orderStatusLabel('Z', 'Odd'), 'Odd')
t('status: nothing at all', orderStatusLabel(null, null), '—')

t(
  'mapping: numerics from strings, flags only when true',
  (({ line_num, backlog_qty, backlog_amount, unit_price, is_rma, is_past_want }) => ({
    line_num,
    backlog_qty,
    backlog_amount,
    unit_price,
    is_rma,
    is_past_want,
  }))(
    mapOpenOrderLine({
      customer_key: 'X',
      order_id: 'SO-1',
      line_num: '3',
      backlog_qty: '4',
      backlog_amount: '1234.50',
      unit_price: null,
      is_rma: 'yes',
      is_past_want: true,
    }),
  ),
  { line_num: 3, backlog_qty: 4, backlog_amount: 1234.5, unit_price: null, is_rma: false, is_past_want: true },
)

const book: OpenOrderLine[] = [
  line({ order_id: 'SO-100', line_num: 2, backlog_amount: 1000, is_past_want: true }),
  line({ order_id: 'SO-100', line_num: 1, backlog_amount: 3998 }),
  line({ order_id: 'SO-99', line_num: 1, order_status: 'H', backlog_amount: 500 }),
  line({ order_id: 'SO-101', line_num: 1, is_rma: true, customer_po_number: 'RMA 77', backlog_amount: 900 }),
  line({ order_id: 'SO-100', line_num: 3, is_non_part: true, part_id: null, backlog_qty: 0, backlog_amount: -200 }),
  line({
    customer_key: 'BIGS SKY',
    customer_id: 'BIGS SKY',
    customer_name: 'Big Sky',
    assigned_sales_rep_id: 'JIM HALL',
    assigned_sales_rep_name: 'Jim',
    order_id: 'SO-7',
    product_code: 'FG-BARACT',
    order_status: 'F',
    backlog_amount: 700,
  }),
]

const defaults = filterOpenOrders(book, DEFAULT_OPEN_ORDER_FILTERS)
t('defaults: RMA/warranty hidden, discount/credit lines kept', defaults.length, 5)
t('defaults: the credit line nets the total', openOrderTotals(defaults).amount, 1000 + 3998 + 500 - 200 + 700)
t(
  'hide discount/credit lines',
  filterOpenOrders(book, { ...DEFAULT_OPEN_ORDER_FILTERS, hideNonPart: true }).some((r) => r.is_non_part),
  false,
)
t(
  'show RMA/warranty when asked',
  filterOpenOrders(book, { ...DEFAULT_OPEN_ORDER_FILTERS, hideRma: false }).length,
  6,
)
t(
  'past want date only',
  filterOpenOrders(book, { ...DEFAULT_OPEN_ORDER_FILTERS, pastWantOnly: true }).map((r) => r.line_num),
  [2],
)
t(
  'by status label',
  filterOpenOrders(book, { ...DEFAULT_OPEN_ORDER_FILTERS, status: 'Hold' }).map((r) => r.order_id),
  ['SO-99'],
)
t(
  'by account, rep and product line together',
  filterOpenOrders(book, {
    ...DEFAULT_OPEN_ORDER_FILTERS,
    account: 'BIGS SKY',
    rep: 'JIM HALL',
    productLine: 'FG-BARACT',
  }).map((r) => r.order_id),
  ['SO-7'],
)

const sorted = sortOpenOrders(defaults)
t(
  'grouped order: account, then order number (numerically), then line',
  sorted.map((r) => `${r.customer_id}/${r.order_id}/${r.line_num}`),
  ['BIGS SKY/SO-7/1', 'SCHE INC/SO-99/1', 'SCHE INC/SO-100/1', 'SCHE INC/SO-100/2', 'SCHE INC/SO-100/3'],
)

const accountStarts = groupStarts(sorted, (r) => r.customer_key)
const orderStarts = groupStarts(sorted, orderKey)
t('account printed on the first row of each run', sorted.map((r) => accountStarts.has(r)), [
  true,
  true,
  false,
  false,
  false,
])
t('order printed on the first row of each run', sorted.map((r) => orderStarts.has(r)), [
  true,
  true,
  true,
  false,
  false,
])
const resorted = [sorted[2]!, sorted[0]!, sorted[3]!]
t(
  're-sorted: runs break up, every row names its account again',
  resorted.map((r) => groupStarts(resorted, (x) => x.customer_key).has(r)),
  [true, true, true],
)
t('an empty list has no group starts', groupStarts([], (x: string) => x).size, 0)

const totals = openOrderTotals(sorted)
t('totals: lines, orders, accounts, qty, $ and the late slice', totals, {
  lines: 5,
  orders: 3,
  accounts: 2,
  qty: 2 + 2 + 2 + 0 + 2,
  amount: 5998,
  pastWantAmount: 1000,
})
const sub = openOrderSubtotals(sorted)
t('subtotal per account', sub.byAccount.get('SCHE INC'), { orders: 2, lines: 4, amount: 5298 })
t('subtotal per order', sub.byOrder.get('SCHE INC|SO-100'), { lines: 3, amount: 4798 })

t(
  'options: distinct, sorted by label, blanks dropped',
  distinctOptions(
    [...book, line({ product_code: null }), line({ product_code: '  ' })],
    (r) => r.product_code,
  ).map((o) => o.value),
  ['FG-BARACT', 'FG-RIFLE'],
)
t(
  'options: a label of its own',
  distinctOptions(book, (r) => r.assigned_sales_rep_id, (r) => r.assigned_sales_rep_name ?? ''),
  [
    { value: 'JIM HALL', label: 'Jim' },
    { value: 'TANY MCDO', label: 'Tanya' },
  ],
)

t('active choice kept in its dropdown when the data drops it', withActive([{ value: 'A', label: 'A' }], 'Z'), [
  { value: 'A', label: 'A' },
  { value: 'Z', label: 'Z' },
])
t('no active choice: options as they are', withActive([{ value: 'A', label: 'A' }], '').length, 1)

/* ---- shipment windows -------------------------------------------------- */

const mon = new Date(2026, 9, 26) // Monday Oct 26 2026
t('This year', presetRange('ytd', mon), { from: '2026-01-01', to: '2026-10-26' })
t('Last year', presetRange('last-year', mon), { from: '2025-01-01', to: '2025-12-31' })
t('Quarter to date', presetRange('qtd', mon), { from: '2026-10-01', to: '2026-10-26' })
t('Month to date', presetRange('mtd', mon), { from: '2026-10-01', to: '2026-10-26' })
t('Last week from a Monday: the Monday-Sunday before', presetRange('last-week', mon), {
  from: '2026-10-19',
  to: '2026-10-25',
})
t('Last week from a Sunday: still the previous full week', presetRange('last-week', new Date(2026, 10, 1)), {
  from: '2026-10-19',
  to: '2026-10-25',
})
t('Quarter to date in February', presetRange('qtd', new Date(2026, 1, 14)), {
  from: '2026-01-01',
  to: '2026-02-14',
})

t('custom: a year is fine', rangeProblem('2025-10-27', '2026-10-26'), null)
t('custom: one day is fine', rangeProblem('2026-10-26', '2026-10-26'), null)
t('custom: both dates needed', rangeProblem('2026-01-01', ''), 'Pick a start and an end date.')
t('custom: backwards', rangeProblem('2026-10-26', '2026-10-01'), 'The start date is after the end date.')
t('custom: the guard is 400 days', MAX_SHIPMENT_SPAN_DAYS, 400)
t('custom: exactly 400 days counted inclusively is allowed', rangeProblem('2025-09-22', '2026-10-26'), null)
t('custom: 401 days is refused', rangeProblem('2025-09-21', '2026-10-26') !== null, true)

/* ---- shipments ---------------------------------------------------------- */

const ship = (over: Partial<BookShipmentLine>): BookShipmentLine => ({
  packlist_id: 'PL-1',
  line_num: 1,
  ship_date: '2026-10-20',
  customer_key: 'SCHE INC',
  customer_name: 'Scheels',
  assigned_sales_rep_name: 'Tanya',
  order_id: 'SO-100',
  order_line_no: 1,
  customer_po_number: 'PO-1',
  part_id: 'MPR-65',
  part_description: 'MPR',
  product_code: 'FG-RIFLE',
  shipped_qty: 2,
  unit_price: 1999,
  trade_discount_pct: 0,
  shipped_value: 3998,
  invoice_id: 'INV-1',
  invoice_status: 'Open',
  ship_via: 'UPS Ground',
  tracking_number: '1ZA',
  ship_to_name: 'Scheels Fargo',
  ship_to_city: 'Fargo',
  ship_to_state: 'ND',
  ...over,
})

t(
  'shipment mapping: numerics from strings',
  (({ shipped_qty, shipped_value, order_line_no }) => ({ shipped_qty, shipped_value, order_line_no }))(
    mapBookShipmentLine({ packlist_id: 'PL', customer_key: 'X', shipped_qty: '3', shipped_value: '45.10', order_line_no: null }),
  ),
  { shipped_qty: 3, shipped_value: 45.1, order_line_no: null },
)

const shipped: BookShipmentLine[] = [
  ship({ packlist_id: 'PL-1', line_num: 2, order_id: 'SO-101', customer_po_number: 'PO-2', tracking_number: '1ZB, 1ZA', invoice_id: null, shipped_value: 500, shipped_qty: 1, product_code: 'ACC' }),
  ship({ packlist_id: 'PL-1', line_num: 1 }),
  ship({ packlist_id: 'PL-2', line_num: 1, ship_date: '2026-10-22', customer_key: 'BIGS SKY', customer_name: 'Big Sky', assigned_sales_rep_name: 'Jim', shipped_value: 700, shipped_qty: 1 }),
]
t(
  'sorted newest first, then packlist and line',
  sortShipments(shipped).map((r) => `${r.packlist_id}/${r.line_num}`),
  ['PL-2/1', 'PL-1/1', 'PL-1/2'],
)
t(
  'filters: account, rep, product line',
  [
    filterShipments(shipped, { account: 'BIGS SKY', rep: '', productLine: '' }).length,
    filterShipments(shipped, { account: '', rep: 'Tanya', productLine: '' }).length,
    filterShipments(shipped, { account: '', rep: '', productLine: 'ACC' }).length,
  ],
  [1, 2, 1],
)

const packlists = groupPacklists(sortShipments(shipped))
t('one row per packlist, in first-seen order', packlists.map((p) => p.packlist_id), ['PL-2', 'PL-1'])
const pl1 = packlists[1]!
t('a packlist sums its lines', [pl1.line_count, pl1.shipped_qty, pl1.shipped_value], [2, 3, 4498])
t('…joins its orders and POs once each', [pl1.order_ids, pl1.customer_po_numbers], ['SO-100, SO-101', 'PO-1, PO-2'])
t('…and its tracking numbers, de-duplicated', pl1.tracking_numbers, '1ZA, 1ZB')
t('…and counts what is not invoiced yet', [pl1.invoice_ids, pl1.uninvoiced_lines], ['INV-1', 1])
t(
  'product line filter applies to lines before the roll-up',
  groupPacklists(filterShipments(shipped, { account: '', rep: '', productLine: 'ACC' })).map((p) => [
    p.packlist_id,
    p.shipped_value,
  ]),
  [['PL-1', 500]],
)

t('totals over lines', shipmentTotals(shipped), { lines: 3, packlists: 2, accounts: 2, qty: 4, value: 5198 })
t('totals over packlists agree', shipmentTotals(packlists), { lines: 3, packlists: 2, accounts: 2, qty: 4, value: 5198 })
t('ship-to text', shipToText(shipped[0]!), 'Scheels Fargo · Fargo, ND')
t('ship-to text without the name', shipToText(shipped[0]!, false), 'Fargo, ND')
t('ship-to text with nothing', shipToText({ ship_to_name: null, ship_to_city: null, ship_to_state: null }), '')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
