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
  readPersistedCache,
  restorePersistedCache,
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
t('ERP success is saved', shouldPersistQuery({ queryKey: summaryKey, state: { status: 'success' } }), true)
t('ERP error is not', shouldPersistQuery({ queryKey: summaryKey, state: { status: 'error' } }), false)
t('ERP pending is not', shouldPersistQuery({ queryKey: summaryKey, state: { status: 'pending' } }), false)
t('flags are saved', shouldPersistQuery({ queryKey: qk.settings(), state: { status: 'success' } }), true)
t('freshness is saved', shouldPersistQuery({ queryKey: qk.freshness(), state: { status: 'success' } }), true)
t('a goal is not', shouldPersistQuery({ queryKey: goalKey, state: { status: 'success' } }), false)
t('contacts are not', shouldPersistQuery({ queryKey: qk.account.contacts('FIX-1'), state: { status: 'success' } }), false)
t('tasks are not', shouldPersistQuery({ queryKey: ['tasks', 'due', 'u1'], state: { status: 'success' } }), false)

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

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail > 0 ? 1 : 0)
