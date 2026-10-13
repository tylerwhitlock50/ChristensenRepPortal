/**
 * Unit tests for composables/useActivityFeed.ts — how the Overview's
 * "Recent activity" groups the feed, and the "new since you last looked"
 * rule.
 *
 * Run with:  npm run test:unit -- activityFeed
 */
import {
  groupActivity,
  isNewSince,
  mapActivityRow,
  mapFallbackOrder,
  type ActivityEvent,
} from '../../src/composables/useActivityFeed'

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

const ev = (over: Partial<ActivityEvent>): ActivityEvent => ({
  customer_key: 'FIX-1',
  customer_name: 'Fixture Outfitters',
  kind: 'order_new',
  occurred_on: '2026-10-10',
  order_id: 'SO-1',
  customer_po_number: null,
  packlist_id: null,
  line_no: null,
  part_id: null,
  part_description: null,
  amount: null,
  qty: null,
  line_count: null,
  tracking_numbers: null,
  ship_via: null,
  promise_before: null,
  promise_after: null,
  has_backlog: null,
  event_id: null,
  ...over,
})

/* ---- mapping ----------------------------------------------------------- */

t('a view row maps, numerics from strings',
  mapActivityRow({ customer_key: 'FIX-1', kind: 'shipped', occurred_on: '2026-10-10', amount: '1899.00', line_no: null, has_backlog: null })?.amount,
  1899)
t('an unknown kind is dropped, not rendered', mapActivityRow({ customer_key: 'FIX-1', kind: 'line_shipped' }), null)
t('the 029 fallback row becomes a new order',
  (({ kind, occurred_on, amount, line_count, has_backlog }) => ({ kind, occurred_on, amount, line_count, has_backlog }))(
    mapFallbackOrder({ customer_key: 'FIX-2', order_id: 'SO-9', order_date: '2026-10-12', order_amount: 6200, line_count: 3, has_backlog: true }),
  ),
  { kind: 'order_new', occurred_on: '2026-10-12', amount: 6200, line_count: 3, has_backlog: true })

/* ---- grouping ---------------------------------------------------------- */

const events: ActivityEvent[] = [
  ev({ kind: 'order_new', order_id: 'SO-5', occurred_on: '2026-10-12', amount: 5100 }),
  ev({ kind: 'order_new', order_id: 'SO-4', occurred_on: '2026-10-08', amount: 900 }),
  // A shipment, and the capture's note that a backorder went out on it.
  ev({ kind: 'shipped', order_id: 'SO-1', packlist_id: 'PL-1', occurred_on: '2026-10-11', tracking_numbers: '1ZB, 1ZA', amount: 5700 }),
  ev({ kind: 'backorder_shipped', order_id: 'SO-1', line_no: 1, part_description: 'MPR 308', occurred_on: '2026-10-12', tracking_numbers: '1ZA' }),
  ev({ kind: 'backorder_shipped', order_id: 'SO-1', line_no: 2, part_description: 'MPR 308', occurred_on: '2026-10-12' }),
  // A backorder event with no shipment row in the window.
  ev({ customer_key: 'FIX-2', customer_name: 'Big Sky', kind: 'backorder_shipped', order_id: 'SO-2', line_no: 3, part_id: 'CA-MESA', occurred_on: '2026-10-09', tracking_numbers: '1ZC' }),
  // A plain shipment.
  ev({ kind: 'shipped', order_id: 'SO-3', packlist_id: 'PL-3', occurred_on: '2026-10-07', tracking_numbers: null }),
  // Two slips on one order, one on another.
  ev({ kind: 'promise_slipped', order_id: 'SO-6', line_no: 1, part_description: 'Ridgeline', promise_before: '2026-10-20', promise_after: '2026-10-27', occurred_on: '2026-10-11' }),
  ev({ kind: 'promise_slipped', order_id: 'SO-6', line_no: 2, part_id: 'CA-TRAV', promise_before: '2026-10-20', promise_after: '2026-11-03', occurred_on: '2026-10-12' }),
  ev({ kind: 'promise_slipped', order_id: 'SO-7', line_no: 1, promise_before: '2026-10-15', promise_after: '2026-10-18', occurred_on: '2026-10-10' }),
]

const g = groupActivity(events)

t('shipped: one item per shipment plus one for the orphan backorder, newest first',
  g.shipped.map((s) => s.order_id), ['SO-1', 'SO-2', 'SO-3'])
t('the shipment carries its tracking, de-duplicated',
  g.shipped[0]!.tracking, ['1ZB', '1ZA'])
t('…and is flagged a backorder, its part named once',
  [g.shipped[0]!.backorder, g.shipped[0]!.backorderParts], [true, ['MPR 308']])
t('the orphan backorder stands alone with its own tracking and the part id',
  [g.shipped[1]!.backorder, g.shipped[1]!.tracking, g.shipped[1]!.backorderParts, g.shipped[1]!.amount],
  [true, ['1ZC'], ['CA-MESA'], null])
t('a plain shipment is not a backorder', g.shipped[2]!.backorder, false)
t('new orders newest first', g.newOrders.map((o) => o.order_id), ['SO-5', 'SO-4'])
t('slips grouped per order, newest first', g.headsUp.map((p) => p.order_id), ['SO-6', 'SO-7'])
t('a grouped slip keeps every line and the latest date',
  [g.headsUp[0]!.occurred_on, g.headsUp[0]!.lines.map((l) => [l.part, l.after])],
  ['2026-10-12', [['Ridgeline', '2026-10-27'], ['CA-TRAV', '2026-11-03']]])
t('a slip with no part names its line', g.headsUp[1]!.lines[0]!.part, 'Line 1')
t('an empty feed groups to nothing',
  groupActivity([]), { shipped: [], newOrders: [], headsUp: [] })

/* ---- new since you last looked ------------------------------------------ */

// Last looked at 8 AM on Oct 12, on this machine's clock (the rule is the
// rep's calendar day, so the test must not depend on the runner's zone).
const seen = new Date(2026, 9, 12, 8, 0).toISOString()
t('dated the day of the last look: new (the evening load brings that day)', isNewSince('2026-10-12', seen), true)
t('dated after it: new', isNewSince('2026-10-13', seen), true)
t('dated before it: not new', isNewSince('2026-10-11', seen), false)
t('never looked: nothing is marked', isNewSince('2026-10-13', null), false)
t('no date: not marked', isNewSince(null, seen), false)
t('a garbage timestamp marks nothing', isNewSince('2026-10-13', 'not a date'), false)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
