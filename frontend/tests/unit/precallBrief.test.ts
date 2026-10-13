/**
 * Unit tests for lib/precallBrief.ts — the sentences in the account page's
 * "Before you call" card.
 *
 * Run with:  npm run test:unit
 *
 * No test framework: the repo has none, and adding vitest to assert a dozen
 * pure-function cases would be a bigger change than the thing under test.
 * This runs under vite-node (already transitively available through vite) and
 * exits non-zero on failure, which is all CI needs. Playwright is configured
 * to ignore this directory.
 *
 * Why these exist: this card is the first thing a rep reads before ringing
 * a dealer, and the owed line does date arithmetic on strings — a late line
 * read as on time, or "1 open orders", is the kind of slip a rep repeats
 * down the phone.
 */
import { boughtLine, lastOrderLine, owedLines } from '../../src/lib/precallBrief'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(
      `FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`,
    )
  }
}

const TODAY = '2026-10-13'

/* ---------------------------------------------------------------- owed */

t('nothing open → null', owedLines({ open_order_count: 0, open_order_value: 0, backlog_qty: 0 }, [], TODAY), null)
t('no summary → null', owedLines(null, null, TODAY), null)

t(
  'headline only while the rows load',
  owedLines({ open_order_count: 2, open_order_value: 18900, backlog_qty: 6 }, undefined, TODAY),
  { headline: '2 open orders · $18,900 · 6 units', detail: '' },
)
t(
  'one order, singular, no units when backlog_qty is 0',
  owedLines({ open_order_count: 1, open_order_value: 4200, backlog_qty: 0 }, [], TODAY)?.headline,
  '1 open order · $4,200',
)
t(
  'fractional units round',
  owedLines({ open_order_count: 1, open_order_value: 10, backlog_qty: 2.6 }, null, TODAY)?.headline,
  '1 open order · $10 · 3 units',
)

const rows = [
  { backlog_amount: 5697, earliest_promise_date: '2026-10-09' }, // late
  { backlog_amount: 4798, earliest_promise_date: '2026-10-23' }, // next
  { backlog_amount: 1299, earliest_promise_date: '2026-10-04' }, // late
  { backlog_amount: 5394, earliest_promise_date: null }, // no promise: never late
  { backlog_amount: 900, earliest_promise_date: '2026-11-30' },
]
t(
  'next promise is the earliest today-or-later; late = before today',
  owedLines({ open_order_count: 2, open_order_value: 18088, backlog_qty: 12 }, rows, TODAY)?.detail,
  'Next promise Oct 23 · 2 items past promise ($6,996)',
)
t(
  'a promise dated today is the next promise, not late',
  owedLines(
    { open_order_count: 1, open_order_value: 100, backlog_qty: 1 },
    [{ backlog_amount: 100, earliest_promise_date: TODAY }],
    TODAY,
  )?.detail,
  'Next promise Oct 13',
)
t(
  'all late, one item: singular, no next promise',
  owedLines(
    { open_order_count: 1, open_order_value: 100, backlog_qty: 1 },
    [{ backlog_amount: 100, earliest_promise_date: '2026-09-01' }],
    TODAY,
  )?.detail,
  '1 item past promise ($100)',
)
t(
  'no promise dates at all: no detail',
  owedLines(
    { open_order_count: 1, open_order_value: 100, backlog_qty: 1 },
    [{ backlog_amount: 100, earliest_promise_date: null }],
    TODAY,
  )?.detail,
  '',
)

/* ----------------------------------------------------------- last order */

const order = {
  order_id: 'SO-88412',
  order_date: '2026-10-08',
  order_state: 'R',
  order_status_desc: 'RELEASED',
  line_count: 3,
  bookings: 13693,
  open_line_count: 2,
  backlog_qty: 5,
  customer_po_number: 'PO-1001',
}
t(
  'open order: id, value, lines, PO, what is still open',
  lastOrderLine(order, '2026-10-08'),
  'SO-88412 · $13,693 · 3 lines · their PO PO-1001 · 5 units still open',
)
t(
  'closed order, one line, no PO: the status, humanized',
  lastOrderLine(
    { ...order, line_count: 1, open_line_count: 0, customer_po_number: null, order_state: 'CLOSED' },
    '2026-10-08',
  ),
  'SO-88412 · $13,693 · 1 line · Closed',
)
t(
  'the order date leads when it is not the date shown above it',
  lastOrderLine(order, '2026-10-11'),
  'Oct 8, 2026 · SO-88412 · $13,693 · 3 lines · their PO PO-1001 · 5 units still open',
)
t(
  'one unit still open: singular',
  lastOrderLine({ ...order, backlog_qty: 1 }, '2026-10-08'),
  'SO-88412 · $13,693 · 3 lines · their PO PO-1001 · 1 unit still open',
)
t('no order yet → empty', lastOrderLine(null, '2026-10-08'), '')

/* --------------------------------------------------------------- bought */

t(
  'bought line',
  boughtLine({ last_qty: 6, last_bought_month: '2026-07-01', ats_qty: 40 }),
  'Bought 6 in Jul 2026 · 40 available',
)
t(
  'thousands separators',
  boughtLine({ last_qty: 1200, last_bought_month: '2025-10-01', ats_qty: 2500 }),
  'Bought 1,200 in Oct 2025 · 2,500 available',
)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
