/**
 * Unit tests for the load-tier freshness work (refresh tiers, 2026-10-27):
 * the clock stamp (lib/format.ts clockStamp), the stock staleness rule
 * (lib/stockFreshness.ts), the in-stock query allow-list and its stamp
 * (isAtsQueryKey, atsStamp in lib/queryClient.ts), the late-restore check
 * (lib/queryPersist.ts) and the heartbeat's second stamp
 * (composables/useDataFreshness.ts).
 *
 * Run with:  npm run test:unit -- freshness
 *
 * The property that matters most: the 15-minute stock load refreshes the
 * in-stock reads and NOTHING else. freshnessStamp must not move with
 * ats_loaded_at, or every stock load (52 a day) would throw away every
 * account page on every phone.
 */
import { createApp, effectScope, nextTick } from 'vue'
import { VueQueryPlugin } from '@tanstack/vue-query'
import { clockStamp } from '../../src/lib/format'
import {
  ATS_STALE_AFTER_MS,
  inStockLoadWindow,
  isAtsStale,
  newestLoadedAt,
} from '../../src/lib/stockFreshness'
import {
  ATS_STALE_TIME,
  atsStamp,
  freshnessStamp,
  isAtsQueryKey,
  isErpQueryKey,
  qk,
  queryClient,
} from '../../src/lib/queryClient'
import { lateRestoreInvalidation } from '../../src/lib/queryPersist'
import { HEARTBEAT_MS, useErpHeartbeat } from '../../src/composables/useDataFreshness'
import { accountMetricsKeys } from '../../src/composables/useAccountMetrics'
import { reorderCandidatesKey } from '../../src/composables/useReorderCandidates'

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

/* --- clockStamp: "Loaded 4:43 AM" ---------------------------------------- */
// Local-time constructors on both sides, so this holds in any test zone.
const monMorning = new Date(2026, 9, 26, 10, 0) // Mon Oct 26 2026, 10:00
t('today: the clock time alone', clockStamp(new Date(2026, 9, 26, 4, 43), monMorning), '4:43 AM')
t('today, from an ISO string', clockStamp(new Date(2026, 9, 26, 9, 15).toISOString(), monMorning), '9:15 AM')
t('yesterday', clockStamp(new Date(2026, 9, 25, 17, 12), monMorning), 'yesterday 5:12 PM')
t('this week: the weekday', clockStamp(new Date(2026, 9, 22, 17, 12), monMorning), 'Thu 5:12 PM')
t('older: month and day', clockStamp(new Date(2026, 9, 1, 17, 12), monMorning), 'Oct 1, 5:12 PM')
t('a phone clock running slow reads as today', clockStamp(new Date(2026, 9, 26, 10, 5), monMorning), '10:05 AM')
t('nothing to stamp', clockStamp(null, monMorning), '—')
t('not a date', clockStamp('not a date', monMorning), '—')

/* --- isAtsStale: ember after three missed loads, in loading hours --------- */
// Late October 2026 is MDT (UTC-6); December is MST (UTC-7).
const minutesAgo = (now: string, m: number) => new Date(Date.parse(now) - m * 60_000).toISOString()
const monday0915 = '2026-10-26T15:15:00Z' // Mon 09:15 Denver
t('45 minutes is three loads', ATS_STALE_AFTER_MS, 45 * 60_000)
t('weekday morning, 60 minutes old: stale', isAtsStale(minutesAgo(monday0915, 60), new Date(monday0915)), true)
t('weekday morning, 30 minutes old: fine', isAtsStale(minutesAgo(monday0915, 30), new Date(monday0915)), false)
t('exactly 45 minutes: not yet', isAtsStale(minutesAgo(monday0915, 45), new Date(monday0915)), false)
t(
  'Saturday, Friday 5:45 PM stamp: expected, not stale',
  isAtsStale('2026-10-23T23:45:00Z', new Date('2026-10-24T16:00:00Z')),
  false,
)
t(
  'Monday 05:15, Friday stamp: before the window opens',
  isAtsStale('2026-10-23T23:45:00Z', new Date('2026-10-26T11:15:00Z')),
  false,
)
t(
  'Monday 05:45, still Friday\'s stamp: the morning loads are missing',
  isAtsStale('2026-10-23T23:45:00Z', new Date('2026-10-26T11:45:00Z')),
  true,
)
t(
  'weekday 18:30: loads are done for the day',
  isAtsStale('2026-10-26T23:45:00Z', new Date('2026-10-27T00:30:00Z')),
  false,
)
t('MST: 05:20 in December is before the window', inStockLoadWindow(new Date('2026-12-07T12:20:00Z')), false)
t('MST: 05:40 in December is inside it', inStockLoadWindow(new Date('2026-12-07T12:40:00Z')), true)
t('17:59 Denver is inside', inStockLoadWindow(new Date('2026-10-26T23:59:00Z')), true)
t('no stamp is not stale', isAtsStale(null, new Date(monday0915)), false)
t('an unparseable stamp is not stale', isAtsStale('soon', new Date(monday0915)), false)

/* --- newestLoadedAt: the fallback stamp ----------------------------------- */
t(
  'the newest loaded_at on the rows',
  newestLoadedAt([
    { loaded_at: '2026-10-26T15:00:00Z' },
    { loaded_at: null },
    { loaded_at: '2026-10-26T15:15:00Z' },
    { loaded_at: '2026-10-26T14:45:00Z' },
  ]),
  '2026-10-26T15:15:00Z',
)
t('no rows, no stamp', newestLoadedAt([]), null)

/* --- isAtsQueryKey: the in-stock reads, and only those -------------------- */
const k = 'FIX-1'
const ats: [string, readonly unknown[]][] = [
  ['the In stock list', qk.intel.ats()],
  ['sku gaps (the ATS page asks for 100)', [...qk.account.skuGaps(k), 100]],
  ['reorder candidates', reorderCandidatesKey(k, 10)],
  ['header search products', ['global-search', 'products', 'mpr']],
]
for (const [label, key] of ats) t(`ATS: ${label}`, isAtsQueryKey(key), true)
const notAts: [string, readonly unknown[]][] = [
  ['backlog', qk.intel.backlog()],
  ['open orders', qk.intel.openOrders()],
  ['book shipments', qk.intel.bookShipments('2026-01-01', '2026-10-26')],
  ['account summary', accountMetricsKeys.summary(k)],
  ['account sku sales', qk.account.skuSales(k)],
  ['freshness itself', qk.freshness()],
  ['header search dealers', ['global-search', 'dealers', 'mpr']],
  ['account key with a non-string customer', ['account', 7, 'reorders']],
]
for (const [label, key] of notAts) t(`not ATS: ${label}`, isAtsQueryKey(key), false)
t('the stock reads that persist are ERP keys too', ats.slice(0, 3).every(([, key]) => isErpQueryKey(key)), true)
t('ATS_STALE_TIME is one stock load', ATS_STALE_TIME, 15 * 60_000)
t('the heartbeat checks every 5 minutes', HEARTBEAT_MS, 5 * 60_000)

/* --- the two stamps --------------------------------------------------------- */
const row = {
  data_loaded_at: '2026-10-26T16:05:00Z',
  data_through: '2026-10-23',
  orders_through: '2026-10-26',
  ats_loaded_at: '2026-10-26T16:15:00Z',
}
t(
  'freshnessStamp ignores ats_loaded_at',
  freshnessStamp({ ...row, ats_loaded_at: '2026-10-26T16:30:00Z' }) === freshnessStamp(row),
  true,
)
t(
  'atsStamp moves with ats_loaded_at',
  atsStamp({ ...row, ats_loaded_at: '2026-10-26T16:30:00Z' }) === atsStamp(row),
  false,
)
t(
  'atsStamp ignores the other three',
  atsStamp({ ...row, data_loaded_at: null, data_through: null }) === atsStamp(row),
  true,
)
t('atsStamp: no row yet is undefined', atsStamp(undefined), undefined)
t(
  'atsStamp: a database without the column reads as null, consistently',
  atsStamp({ data_loaded_at: row.data_loaded_at }) === atsStamp({ ats_loaded_at: null }),
  true,
)

/* --- late restore: which restored queries go stale ------------------------- */
t('late restore: nothing moved', lateRestoreInvalidation(row, { ...row }), null)
t(
  'late restore: a full/hourly load since the copy → every ERP query',
  lateRestoreInvalidation(row, { ...row, data_loaded_at: '2026-10-26T17:05:00Z' }) === isErpQueryKey,
  true,
)
t(
  'late restore: only a stock load since the copy → only the in-stock reads',
  lateRestoreInvalidation(row, { ...row, ats_loaded_at: '2026-10-26T16:45:00Z' }) === isAtsQueryKey,
  true,
)
t(
  'late restore: a copy with no freshness row → every ERP query',
  lateRestoreInvalidation(undefined, row) === isErpQueryKey,
  true,
)

/* --- the heartbeat's second stamp ------------------------------------------ */
// No network: the freshness query is switched off and its data written by hand.
queryClient.setQueryDefaults(qk.freshness(), { enabled: false })
const stamp = (loaded: string, atsAt: string) => ({ ...row, data_loaded_at: loaded, ats_loaded_at: atsAt })
const keys = {
  ats: qk.intel.ats(),
  reorders: reorderCandidatesKey(k, 10),
  search: ['global-search', 'products', 'mpr'] as const,
  summary: accountMetricsKeys.summary(k),
}
const seed = () => {
  for (const key of Object.values(keys)) queryClient.setQueryData(key, { seeded: true })
}
const invalidated = () =>
  Object.fromEntries(
    Object.entries(keys).map(([name, key]) => [name, queryClient.getQueryState(key)?.isInvalidated ?? null]),
  )
const settle = async () => {
  await nextTick()
  await nextTick()
}

queryClient.setQueryData(qk.freshness(), stamp('L1', 'A1'))
seed()
const app = createApp({})
app.use(VueQueryPlugin, { queryClient })
const scope = effectScope()
app.runWithContext(() => scope.run(() => useErpHeartbeat()))
await settle()
t('first stamps seen: nothing invalidated', invalidated(), {
  ats: false,
  reorders: false,
  search: false,
  summary: false,
})

queryClient.setQueryData(qk.freshness(), stamp('L1', 'A2'))
await settle()
t('a stock load: the in-stock reads only', invalidated(), {
  ats: true,
  reorders: true,
  search: true,
  summary: false,
})

seed()
queryClient.setQueryData(qk.freshness(), stamp('L2', 'A2'))
await settle()
t('an hourly load without a stock move: ERP reads, not the header search', invalidated(), {
  ats: true,
  reorders: true,
  search: false,
  summary: true,
})

seed()
queryClient.setQueryData(qk.freshness(), stamp('L3', 'A3'))
await settle()
t('a full load (both stamps): everything, once', invalidated(), {
  ats: true,
  reorders: true,
  search: true,
  summary: true,
})

seed()
queryClient.setQueryData(qk.freshness(), stamp('L3', 'A3'))
await settle()
t('the same stamps again: nothing', invalidated(), {
  ats: false,
  reorders: false,
  search: false,
  summary: false,
})

scope.stop()
queryClient.clear()

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
