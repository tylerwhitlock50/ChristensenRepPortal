/**
 * Unit tests for lib/queryPersist.ts — the ERP read cache saved on the phone.
 *
 * Run with:  npm run test:unit -- queryPersist
 *
 * IndexedDB comes from fake-indexeddb (an in-memory implementation of the
 * same API), so this exercises the real idb-keyval and TanStack persister
 * code paths. What is pinned is the security behaviour: only ERP reads,
 * flags and the freshness stamp are written; a saved copy only comes back
 * for the same user and build and only for 24 hours; a wipe deletes it; and
 * a save that was already queued when persisting stopped does NOT land
 * afterwards (the sign-out-then-throttled-save race).
 */
import 'fake-indexeddb/auto'
import { get } from 'idb-keyval'
import {
  busterFor,
  cacheStore,
  MAX_AGE_MS,
  readOfflineIdentity,
  readPersistedCache,
  restorePersistedCache,
  saveOfflineIdentity,
  shouldPersistQuery,
  startPersisting,
  stopPersisting,
  wipePersistedCache,
} from '../../src/lib/queryPersist'
import { qk, queryClient } from '../../src/lib/queryClient'
import { accountMetricsKeys } from '../../src/composables/useAccountMetrics'

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

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const saved = async () => {
  const raw = await get<string>('query-cache', cacheStore()!)
  return raw ? JSON.parse(raw) : null
}
const savedKeys = async () =>
  ((await saved())?.clientState.queries ?? []).map((q: { queryKey: unknown[] }) => q.queryKey[0] === 'account' ? q.queryKey[2] : q.queryKey[0] + '/' + (q.queryKey[1] ?? ''))

const summaryKey = accountMetricsKeys.summary('FIX-1')
const goalKey = [...qk.account.goal('FIX-1'), 2026]

/* --- what is eligible ---------------------------------------------------- */
const now = Date.now()
const ok = (status: string, dataUpdatedAt = now) => ({ status, dataUpdatedAt })
t('ERP success is saved', shouldPersistQuery({ queryKey: summaryKey, state: ok('success') }), true)
t('ERP error is not', shouldPersistQuery({ queryKey: summaryKey, state: ok('error') }), false)
t('ERP pending is not', shouldPersistQuery({ queryKey: summaryKey, state: ok('pending', 0) }), false)
t('flags are saved', shouldPersistQuery({ queryKey: qk.settings(), state: ok('success') }), true)
t('freshness is saved', shouldPersistQuery({ queryKey: qk.freshness(), state: ok('success') }), true)
t('a goal is not', shouldPersistQuery({ queryKey: goalKey, state: ok('success') }), false)
t('contacts are not', shouldPersistQuery({ queryKey: qk.account.contacts('FIX-1'), state: ok('success') }), false)
t('tasks are not', shouldPersistQuery({ queryKey: ['tasks', 'due', 'u1'], state: ok('success') }), false)
t('an ERP read fetched more than 24h ago is not',
  shouldPersistQuery({ queryKey: summaryKey, state: ok('success', now - MAX_AGE_MS - 60_000) }), false)
t('…nor one with no fetch time',
  shouldPersistQuery({ queryKey: summaryKey, state: { status: 'success' } }), false)

/* --- save for rep A ------------------------------------------------------ */
startPersisting('rep-a')
queryClient.setQueryData(summaryKey, { revenue_ytd: 84250 })
queryClient.setQueryData(goalKey, { target_amount: 100000 })
queryClient.setQueryData(qk.freshness(), { data_loaded_at: '2026-10-13T06:00:00Z' })
await sleep(2_300) // one throttle window
const first = await saved()
t('saved under rep A and this build', first?.buster, busterFor('rep-a'))
t('only eligible queries were written', (await savedKeys()).sort(), ['data-freshness/', 'summary'])

/* --- restore: same user ---------------------------------------------------- */
stopPersisting()
queryClient.clear()
readPersistedCache('rep-a')
t('restore for rep A succeeds', await restorePersistedCache('rep-a'), true)
t('…and the data is back', queryClient.getQueryData(summaryKey), { revenue_ytd: 84250 })
t('…with its original timestamp, so staleness is honest',
  (queryClient.getQueryState(summaryKey)?.dataUpdatedAt ?? 0) <= first.timestamp, true)

/* --- restore: another user on the same device ----------------------------- */
queryClient.clear()
readPersistedCache('rep-b')
t('rep B gets nothing from rep A', await restorePersistedCache('rep-b'), false)
t('…nothing in the cache', queryClient.getQueryData(summaryKey), undefined)
await sleep(50)
t("…and rep A's copy is deleted", await saved(), null)

/* --- too old ------------------------------------------------------------- */
startPersisting('rep-a')
queryClient.setQueryData(summaryKey, { revenue_ytd: 1 })
await sleep(2_300)
stopPersisting()
{
  const s = await saved()
  s.timestamp = Date.now() - MAX_AGE_MS - 60_000
  const { set } = await import('idb-keyval')
  await set('query-cache', JSON.stringify(s), cacheStore()!)
}
queryClient.clear()
readPersistedCache('rep-a-again') // a different pending read than before
t('a copy older than 24h is not restored', await restorePersistedCache('rep-a'), false)

/* --- an old read inside a fresh copy --------------------------------------- */
// The copy's timestamp is the last save; a read restored from an earlier
// copy rides along in memory and would be saved again. Neither the save
// nor the restore may carry it past 24 hours from its own fetch.
{
  const staleKey = accountMetricsKeys.summary('FIX-OLD')
  startPersisting('rep-a')
  queryClient.setQueryData(summaryKey, { revenue_ytd: 5 })
  queryClient.setQueryData(staleKey, { revenue_ytd: 6 }, { updatedAt: Date.now() - MAX_AGE_MS - 60_000 })
  await sleep(2_300)
  stopPersisting()
  const s = await saved()
  t('a read older than 24h is left out of the save',
    s.clientState.queries.map((q: { queryKey: unknown[] }) => q.queryKey[1]).includes('FIX-OLD'), false)
  // A copy written with one anyway (saved when it was still under 24h).
  s.clientState.queries.push({ ...s.clientState.queries.find((q: { queryKey: unknown[] }) => q.queryKey[1] === 'FIX-1'),
    queryKey: staleKey, queryHash: JSON.stringify(staleKey),
    state: { ...s.clientState.queries[0].state, data: { revenue_ytd: 6 }, dataUpdatedAt: Date.now() - MAX_AGE_MS - 60_000 } })
  const { set } = await import('idb-keyval')
  await set('query-cache', JSON.stringify(s), cacheStore()!)
  queryClient.clear()
  readPersistedCache('rep-a-old-read')
  t('the copy itself is restored', await restorePersistedCache('rep-a'), true)
  t('…with the fresh read', queryClient.getQueryData(summaryKey), { revenue_ytd: 5 })
  t('…but not the read older than 24h', queryClient.getQueryData(staleKey), undefined)
  queryClient.clear()
}

/* --- wipe, and the queued-save race --------------------------------------- */
startPersisting('rep-a')
queryClient.setQueryData(summaryKey, { revenue_ytd: 2 }) // leading save, immediate
await sleep(50)
queryClient.setQueryData(summaryKey, { revenue_ytd: 3 }) // queued behind the throttle
await wipePersistedCache() // sign-out: stop, then delete
queryClient.clear()
await sleep(2_500) // the queued save's moment comes and goes
t('a save queued before sign-out never lands after it', await saved(), null)

/* --- a new user after the wipe starts clean ------------------------------- */
startPersisting('rep-b')
queryClient.setQueryData(summaryKey, { revenue_ytd: 4 })
await sleep(2_300)
t('rep B saves under rep B', (await saved())?.buster, busterFor('rep-b'))
await wipePersistedCache()
t('wipe deletes it', await saved(), null)

/* --- the identity the offline open relies on ------------------------------ */
const rep = { user_id: 'rep-a', role: 'rep', active: true, full_name: 'Riley' }
const writeIdentity = async (record: object) => {
  const { set } = await import('idb-keyval')
  await set('offline-identity', JSON.stringify(record), cacheStore()!)
}

saveOfflineIdentity('rep-a', rep)
await sleep(50)
t('not saved unless that user is being persisted for', await readOfflineIdentity('rep-a'), null)

startPersisting('rep-a')
saveOfflineIdentity('rep-a', rep)
await sleep(50)
t('saved for the persisted rep', (await readOfflineIdentity('rep-a'))?.profile.full_name, 'Riley')
t('never handed to another user', await readOfflineIdentity('rep-b'), null)
saveOfflineIdentity('rep-a', { ...rep, user_id: 'rep-b' })
await sleep(50)
t("a profile that isn't the user's own is not saved", (await readOfflineIdentity('rep-a'))?.profile.user_id, 'rep-a')

const fresh = { buster: busterFor('rep-a'), savedAt: Date.now() }
await writeIdentity({ ...fresh, profile: { ...rep, role: 'admin' } })
t('an admin never opens offline', await readOfflineIdentity('rep-a'), null)
await writeIdentity({ ...fresh, profile: { ...rep, role: 'order_entry' } })
t('order entry never opens offline', await readOfflineIdentity('rep-a'), null)
await writeIdentity({ ...fresh, profile: { ...rep, active: false } })
t('a deactivated rep never opens offline', await readOfflineIdentity('rep-a'), null)
await writeIdentity({ ...fresh, savedAt: Date.now() - MAX_AGE_MS - 1, profile: rep })
t('older than 24h: no', await readOfflineIdentity('rep-a'), null)
await writeIdentity({ buster: 'rep-a:another-build', savedAt: Date.now(), profile: rep })
t('another build: no', await readOfflineIdentity('rep-a'), null)
await writeIdentity({ ...fresh, profile: rep })
t('…and the good one: yes', (await readOfflineIdentity('rep-a'))?.profile.role, 'rep')

await wipePersistedCache()
t('wipe deletes the identity too', await readOfflineIdentity('rep-a'), null)

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
