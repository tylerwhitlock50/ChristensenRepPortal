/**
 * Unit tests for the ERP cache policy: isErpQueryKey() and the key-based
 * defaults in lib/queryClient.ts, and useErpHeartbeat() in
 * composables/useDataFreshness.ts.
 *
 * Run with:  npm run test:unit -- erpCache
 *
 * The allow-list is the safety property here. A key on it holds its data for
 * hours, skips refetch-on-focus and is written to the phone's IndexedDB; a
 * rep-written read wrongly on it would hide the rep's own edit until the
 * next nightly load. So this pins both sides: the real keys the ERP
 * composables build ARE on it, and the rep-written / mixed reads that sit
 * right next to them are NOT.
 */
import { createApp, effectScope, nextTick } from 'vue'
import { VueQueryPlugin } from '@tanstack/vue-query'
import {
  ERP_GC_TIME,
  ERP_STALE_TIME,
  isErpQueryKey,
  qk,
  queryClient,
} from '../../src/lib/queryClient'
import { accountMetricsKeys } from '../../src/composables/useAccountMetrics'
import { reorderCandidatesKey } from '../../src/composables/useReorderCandidates'
import { bestContactsKeys } from '../../src/composables/useBestContacts'
import { taskKeys } from '../../src/composables/useTasks'
import { useErpHeartbeat } from '../../src/composables/useDataFreshness'

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

/* --- ERP: what the composables actually build ---------------------------- */
const k = 'FIX-1'
const erp: [string, readonly unknown[]][] = [
  ['territory yoy', qk.intel.territoryYoy()],
  ['territory recent orders', qk.intel.territoryRecentOrders()],
  ['territory sku', qk.intel.territorySku()],
  ['backlog', qk.intel.backlog()],
  ['ats', qk.intel.ats()],
  ['global, any window', qk.intel.global(24)],
  ['book signals', qk.intel.signals()],
  ['account detail (dim_customer)', qk.account.detail(k)],
  ['account summary', accountMetricsKeys.summary(k)],
  ['account revenue by month', accountMetricsKeys.revenueMonthly(k)],
  ['order headers', accountMetricsKeys.orderHeaders(k)],
  ['order lines', accountMetricsKeys.orderLines(k, 'SO-1')],
  ['shipment headers', accountMetricsKeys.shipmentHeaders(k)],
  ['shipment lines', accountMetricsKeys.shipmentLines(k, 'P-1')],
  ['account sku sales', qk.account.skuSales(k)],
  ['account backlog', qk.account.backlogSku(k)],
  ['account signals', qk.account.signals(k)],
  ['sku gaps (with limit)', [...qk.account.skuGaps(k), 25]],
  ['reorder candidates', reorderCandidatesKey(k, 10)],
]
for (const [label, key] of erp) t(`ERP: ${label}`, isErpQueryKey(key), true)

/* --- NOT ERP: rep-written, mixed, or the heartbeat itself ---------------- */
const notErp: [string, readonly unknown[]][] = [
  ['data freshness (the heartbeat)', qk.freshness()],
  ['app settings', qk.settings()],
  ['accounts list', qk.me.accounts()],
  ['accounts table (joins goals)', [...qk.me.accounts(), 'table', { active: true }]],
  ['account goal', [...qk.account.goal(k), 2026]],
  ['goals rollup', qk.goals.rollup(2026)],
  ['goals behind', qk.goals.behind(2026)],
  ['contacts', qk.account.contacts(k)],
  ['best contacts for the page', bestContactsKeys.account(k)],
  ['best contacts, book', bestContactsKeys.forKeys([k])],
  ['notes', qk.account.notes(k)],
  ['visits', qk.account.visits(k)],
  ['ai summary', qk.account.aiSummary(k)],
  ['account status (deactivation)', qk.account.status(k)],
  ['recommendations', qk.account.recommendations(k)],
  ['account root (an invalidation prefix, not a query)', qk.account.root(k)],
  ['ai brief', qk.aiBrief('territory')],
  ['tasks', taskKeys.due('u1')],
  ['admin channels (joins account_goals)', qk.admin.channels()],
  ['admin rep groups (joins actions, profiles)', qk.admin.repGroupPerformance()],
  ['an intel key nobody vetted', ['intel', 'something-new']],
  ['an account key nobody vetted', ['account', k, 'something-new']],
  ['account key with a non-string customer', ['account', 7, 'summary']],
]
for (const [label, key] of notErp) t(`not ERP: ${label}`, isErpQueryKey(key), false)

/* --- the defaults land where they should --------------------------------- */
const summary = queryClient.defaultQueryOptions({ queryKey: accountMetricsKeys.summary(k) })
t('ERP default staleTime', summary.staleTime, ERP_STALE_TIME)
t('ERP default gcTime', summary.gcTime, ERP_GC_TIME)
t('ERP queries skip refetch on focus', summary.refetchOnWindowFocus, false)
t('…but still refetch on reconnect when stale', summary.refetchOnReconnect, true)

const explicit = queryClient.defaultQueryOptions({
  queryKey: reorderCandidatesKey(k, 10),
  staleTime: 10 * 60_000,
})
t("a query's own staleTime still wins", explicit.staleTime, 10 * 60_000)
t('…while the rest of the ERP defaults apply', explicit.refetchOnWindowFocus, false)

const goal = queryClient.defaultQueryOptions({ queryKey: [...qk.account.goal(k), 2026] })
t('non-ERP keeps the client default staleTime', goal.staleTime, 60_000)
t('non-ERP keeps refetch on focus', goal.refetchOnWindowFocus, true)

const freshness = queryClient.defaultQueryOptions({ queryKey: qk.freshness() })
t('freshness is not given ERP defaults', freshness.refetchOnWindowFocus, true)

/* --- the heartbeat -------------------------------------------------------- */
// No network: the freshness query is switched off (it sets no `enabled` of
// its own, so setQueryDefaults reaches it) and its data is written by hand.
queryClient.setQueryDefaults(qk.freshness(), { enabled: false })
const stamp = (loaded: string | null) => ({
  data_loaded_at: loaded,
  data_through: '2026-10-12',
  orders_through: '2026-10-12',
})
const summaryKey = accountMetricsKeys.summary(k)
const goalKey = [...qk.account.goal(k), 2026]
const seed = () => {
  queryClient.setQueryData(summaryKey, { revenue_ytd: 1 })
  queryClient.setQueryData(goalKey, { target_amount: 1 })
}
const invalidated = (key: readonly unknown[]) =>
  queryClient.getQueryState(key)?.isInvalidated ?? null

// Last night's stamp is what the cache was built under (restored from disk).
queryClient.setQueryData(qk.freshness(), stamp('2026-10-12T06:10:00Z'))
seed()

const app = createApp({})
app.use(VueQueryPlugin, { queryClient })
const scope = effectScope()
app.runWithContext(() => scope.run(() => useErpHeartbeat()))
await nextTick()
t('first stamp seen: nothing invalidated', invalidated(summaryKey), false)

queryClient.setQueryData(qk.freshness(), stamp('2026-10-12T06:10:00Z'))
await nextTick()
t('same stamp again: nothing invalidated', invalidated(summaryKey), false)

queryClient.setQueryData(qk.freshness(), stamp('2026-10-13T06:05:00Z'))
await nextTick()
await nextTick()
t('new load: ERP queries invalidated', invalidated(summaryKey), true)
t('new load: rep-written queries untouched', invalidated(goalKey), false)

seed()
queryClient.setQueryData(qk.freshness(), stamp(null))
await nextTick()
await nextTick()
t('stamp cleared (no ETL record) counts as a change', invalidated(summaryKey), true)

scope.stop()
queryClient.clear()

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
