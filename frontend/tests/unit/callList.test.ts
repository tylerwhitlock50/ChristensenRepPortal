/**
 * Unit tests for the call list and the classifier behind it:
 * useOverview.ts observeAccount / worthInvestigating, useCallList.ts
 * (reaction windows, the ranked list, the fallback), the Accounts page's
 * ranked sorts, the plan, the usage ping and the quick call log's pure parts.
 *
 * Run with:  npm run test:unit -- callList
 *
 * No test framework (see ffl.test.ts for why). Only the pure exports are
 * exercised; the queries around them are covered by the smoke harness.
 */
import {
  observeAccount,
  worthInvestigating,
  type TerritoryAccountRow,
} from '../../src/composables/useOverview'
import type { AccountSignalRow } from '../../src/composables/useAccountSignals'
import {
  buildCallList,
  fallbackCallList,
  hiddenByReaction,
  type CallListFeedbackRow,
  type CallListSignal,
} from '../../src/composables/useCallList'
import { rankAccountRows, type AccountTableRow } from '../../src/composables/useAccounts'
import { MAX_PLAN, togglePlanKey } from '../../src/composables/usePlan'
import { isPingDue, PING_INTERVAL_MS } from '../../src/composables/useUsagePing'
import { isOutcomeDue, outcomeNote, OUTCOME_WINDOW_MS } from '../../src/composables/useQuickCallLog'
import { parseFactors } from '../../src/lib/scoreReasons'

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

const TODAY = new Date('2026-10-13T12:00:00')
const DAY = 86_400_000
const isoDaysAgo = (n: number) => new Date(TODAY.getTime() - n * DAY).toISOString().slice(0, 10)

function territory(over: Partial<TerritoryAccountRow> & { customer_key: string }): TerritoryAccountRow {
  return {
    customer_name: over.customer_key,
    sold_to_city: 'BOZEMAN',
    sold_to_state: 'MT',
    yearly_sales_goal: null,
    revenue_ytd: 20_000,
    revenue_prior_ytd: 20_000,
    revenue_trailing_12m: 24_000,
    last_invoice_date: isoDaysAgo(10),
    open_order_value: 0,
    backlog_qty: 0,
    backlog_amount: 0,
    ...over,
  }
}

function signal(over: Partial<CallListSignal> & { customer_key: string }): CallListSignal {
  return {
    cadence_days: null,
    cadence_confident: false,
    days_since_order: 10,
    last_order_date: isoDaysAgo(10),
    order_days_24m: 5,
    families_12m: 3,
    families_prior_12m: 3,
    families_dropped: 0,
    yoy_change: 0,
    revenue_12m: 24_000,
    revenue_percentile: 0.5,
    score: 60,
    priority: 'normal',
    factors: {},
    ...over,
  }
}

/* --- observeAccount: one account, the loudest thing --------------------- */
const confident: AccountSignalRow = signal({
  customer_key: 'A',
  cadence_days: 20,
  cadence_confident: true,
  days_since_order: 45,
})
t(
  'cadence: late against its own rhythm',
  observeAccount(territory({ customer_key: 'A' }), confident, TODAY)?.chip,
  'Usually orders every 20 days — 45 since the last one',
)
t(
  'cadence needs $5,000 of trailing revenue',
  observeAccount(territory({ customer_key: 'A', revenue_trailing_12m: 4_000 }), confident, TODAY),
  null,
)
t(
  'dormant: the flat 90-day rule without a confident rhythm',
  observeAccount(territory({ customer_key: 'B', last_invoice_date: isoDaysAgo(120) }), null, TODAY)?.chip,
  'No invoice in 120 days',
)
t(
  'dormant is skipped when a confident rhythm says it is not late',
  observeAccount(
    territory({ customer_key: 'B', last_invoice_date: isoDaysAgo(120) }),
    signal({ customer_key: 'B', cadence_days: 180, cadence_confident: true, days_since_order: 120 }),
    TODAY,
  ),
  null,
)
t(
  'decline: under half of last year to date',
  observeAccount(territory({ customer_key: 'C', revenue_ytd: 9_800, revenue_prior_ytd: 31_000 }), null, TODAY)?.chip,
  'Down 68% vs this time last year',
)
t(
  'backlog: $10,000+ past promise',
  observeAccount(territory({ customer_key: 'D', backlog_amount: 14_000 }), null, TODAY)?.chip,
  '$14,000 past promise date',
)
t('nothing stands out: null', observeAccount(territory({ customer_key: 'E' }), null, TODAY), null)

/* --- worthInvestigating keeps its old contract on top of it ------------- */
const book = [
  territory({ customer_key: 'BIG-DORMANT', revenue_trailing_12m: 90_000, last_invoice_date: isoDaysAgo(100) }),
  territory({ customer_key: 'DECLINE', revenue_ytd: 5_000, revenue_prior_ytd: 30_000 }),
  territory({ customer_key: 'BACKLOG', backlog_amount: 12_000 }),
  territory({ customer_key: 'QUIET' }),
]
t(
  'worthInvestigating ranks by dollar weight across kinds',
  worthInvestigating(book, 6, TODAY).map((o) => `${o.kind}:${o.customer_key}`),
  ['dormant:BIG-DORMANT', 'decline:DECLINE', 'backlog:BACKLOG'],
)
t('worthInvestigating caps at n', worthInvestigating(book, 2, TODAY).length, 2)

/* --- reaction windows --------------------------------------------------- */
const now = TODAY.getTime()
const fb = (customer_key: string, reaction: CallListFeedbackRow['reaction'], daysAgo: number): CallListFeedbackRow => ({
  id: Math.round(Math.random() * 1e6),
  customer_key,
  reaction,
  reason: null,
  created_at: new Date(now - daysAgo * DAY).toISOString(),
})
t(
  'on_it hides for 3 days, handled 14, not_relevant 45',
  [...hiddenByReaction(
    [
      fb('ON-2', 'on_it', 2),
      fb('ON-4', 'on_it', 4),
      fb('H-13', 'handled', 13),
      fb('H-15', 'handled', 15),
      fb('NR-44', 'not_relevant', 44),
      fb('NR-46', 'not_relevant', 46),
    ],
    now,
  )].sort(),
  ['H-13', 'NR-44', 'ON-2'],
)
t(
  'any reaction still inside its window hides the account',
  [...hiddenByReaction([fb('X', 'on_it', 10), fb('X', 'not_relevant', 20)], now)],
  ['X'],
)
t('a bad timestamp hides nothing', hiddenByReaction([{ ...fb('Y', 'handled', 1), created_at: 'nope' }], now).size, 0)

/* --- buildCallList ------------------------------------------------------ */
const FACTORS = parseFactors({
  cadence: { value: 100, weight: 30, contribution: 30, why: 'Usually orders every 20 days — 45 since the last one' },
  value: { value: 80, weight: 20, contribution: 16, why: '$90,000 trailing 12 months' },
})
const terr = new Map(
  [
    territory({ customer_key: 'S1', customer_name: 'Top Dealer', backlog_amount: 14_000 }),
    territory({ customer_key: 'S2', customer_name: 'Second' }),
    territory({ customer_key: 'S4', customer_name: 'Hidden' }),
  ].map((r) => [r.customer_key, r]),
)
const sigs = [
  signal({ customer_key: 'S1', score: 88, priority: 'high', factors: FACTORS }),
  signal({ customer_key: 'S2', score: 60, priority: 'normal', factors: {} }),
  signal({ customer_key: 'S3', score: 55, priority: 'normal' }), // not in the territory rows
  signal({ customer_key: 'S4', score: 50, priority: 'normal' }), // reacted to
  signal({ customer_key: 'S5', score: 20, priority: 'low' }),
]
const list = buildCallList(sigs, terr, new Set(['S4']), TODAY)
t('ranked list drops low, hidden and out-of-book rows, keeps score order', list.map((r) => r.customer_key), ['S1', 'S2'])
t(
  'a ranked row carries the score reason and the classifier fact the score lacks',
  list[0]!.chips.map((c) => c.label),
  ['Usually orders every 20 days — 45 since the last one', '$14,000 past promise date'],
)
t('money and town come from the territory row', [list[0]!.revenue_ytd, list[0]!.place], [20_000, 'Bozeman, MT'])
t(
  'before the territory rows load nothing is dropped for being missing',
  buildCallList(sigs, null, new Set(), TODAY).map((r) => r.customer_key),
  ['S1', 'S2', 'S3', 'S4'],
)
t('the limit holds', buildCallList(sigs, null, new Set(), TODAY, 2).length, 2)

/* --- fallbackCallList --------------------------------------------------- */
const fallback = fallbackCallList(book, new Set(['DECLINE']), new Set(['BACKLOG']), TODAY)
t('fallback: classifier order, minus reacted and deactivated', fallback.map((r) => r.customer_key), ['BIG-DORMANT'])
t('fallback rows carry the observation as their one chip', fallback[0]!.chips.map((c) => c.label), ['No invoice in 100 days'])
t('fallback rows have no score', fallback[0]!.score, null)

/* --- Accounts page ranked sorts ----------------------------------------- */
function acct(over: Partial<AccountTableRow> & { customer_key: string }): AccountTableRow {
  return {
    customer_name: over.customer_key,
    sold_to_city: null,
    sold_to_state: null,
    active_flag: 'Y',
    assigned_sales_rep_name: null,
    last_order_date: isoDaysAgo(30),
    last_invoice_date: null,
    revenue_ytd: 0,
    revenue_prior_ytd: 0,
    revenue_prior_full: 0,
    bookings_ytd: 0,
    bookings_prior_ytd: 0,
    open_order_value: 0,
    open_order_count: 0,
    goal_amount: null,
    goal_source: null,
    attainment_pct: null,
    on_track: null,
    deactivated_at: null,
    ...over,
  }
}
const accts = [
  acct({ customer_key: 'A', revenue_ytd: 50_000, revenue_prior_ytd: 80_000, last_order_date: isoDaysAgo(200) }),
  acct({ customer_key: 'B', revenue_ytd: 90_000, revenue_prior_ytd: 70_000, last_order_date: isoDaysAgo(5) }),
  acct({ customer_key: 'C', revenue_ytd: 10_000, revenue_prior_ytd: 15_000, last_order_date: isoDaysAgo(800) }),
  acct({ customer_key: 'D', revenue_ytd: 90_000, revenue_prior_ytd: 90_000, last_order_date: null }),
]
t('biggest: YTD desc, name breaks ties', rankAccountRows(accts, 'biggest', TODAY).map((r) => r.customer_key), ['B', 'D', 'A', 'C'])
t('slipping: only those behind, biggest dollar drop first', rankAccountRows(accts, 'slipping', TODAY).map((r) => r.customer_key), ['A', 'C'])
t(
  'quiet: ordered in the last two years, longest first',
  rankAccountRows(accts, 'quiet', TODAY).map((r) => r.customer_key),
  ['A', 'B'],
)

/* --- plan --------------------------------------------------------------- */
t('star adds at the end', togglePlanKey(['A'], 'B'), ['A', 'B'])
t('unstar removes, order kept', togglePlanKey(['A', 'B', 'C'], 'B'), ['A', 'C'])
t(
  'a full plan does not grow',
  togglePlanKey(Array.from({ length: MAX_PLAN }, (_, i) => `K${i}`), 'NEW').length,
  MAX_PLAN,
)

/* --- usage ping --------------------------------------------------------- */
t('first open is due', isPingDue(0, now), true)
t('an hour later is not', isPingDue(now - 3_600_000, now), false)
t('four hours later is', isPingDue(now - PING_INTERVAL_MS, now), true)
t('a stamp from the future does not block forever', isPingDue(now + DAY, now), true)

/* --- quick call log ----------------------------------------------------- */
t('note names who was reached', outcomeNote('reached', 'Dana Buyer'), 'Reached Dana Buyer')
t('note for a message', outcomeNote('left_message', 'Dana Buyer'), 'Left Dana Buyer a message')
t('note with nobody named', outcomeNote('no_answer', '  '), 'No answer')
t('an outcome is due within half an hour', isOutcomeDue(now - 10 * 60_000, now), true)
t('not after it', isOutcomeDue(now - OUTCOME_WINDOW_MS - 1, now), false)
t('not for a tap in the future', isOutcomeDue(now + 1, now), false)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
