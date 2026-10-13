/**
 * The ERP read cache, kept on the phone between app opens (IndexedDB).
 *
 * A cold open used to re-download everything: the Overview's territory, the
 * signals, every account the rep looked at in the parking lot. This saves the
 * queries that only change with the nightly load (isErpQueryKey) plus the
 * feature flags and the freshness stamp, and puts them back into the query
 * cache before the first page renders. useErpHeartbeat then compares the
 * restored freshness stamp with the server's and refreshes anything that
 * predates a newer load.
 *
 * Who gets one — security first, because this is a book of revenue on a
 * device that may be a shared truck iPad:
 *
 *   - Reps only. Admins and order-entry users never persist: an admin's
 *     cache is the whole company, and only admins can view-as, which is the
 *     one way a cache could end up holding someone else's book under your
 *     name. Never while viewing-as, either, belt and braces.
 *   - Keyed to the user and the build (the buster). Another user, or a new
 *     deploy whose data shapes may differ, finds nothing to restore.
 *   - At most 24 hours old (MAX_AGE).
 *   - Deleted on sign-out, on a sign-out from another tab or a revoked
 *     refresh token, on a user switch, and when a boot finds nobody signed
 *     in. The session store calls in here beside each queryClient.clear().
 *   - A write that was already queued when persisting stopped is dropped
 *     at the last moment (see `serialize`), so a sign-out cannot be undone
 *     by a save that was waiting out its throttle.
 *
 * And it must never cost the rep anything: the restore gets RESTORE_BUDGET_MS
 * and boot carries on without it after that; every IndexedDB failure
 * (private mode, quota, a browser that evicted the store) is swallowed and
 * logged once, and the app simply behaves as it did before this existed.
 */
import { createStore, del, get, set, type UseStore } from 'idb-keyval'
import { createAsyncStoragePersister } from '@tanstack/query-async-storage-persister'
import {
  persistQueryClientSave,
  type PersistedClient,
} from '@tanstack/query-persist-client-core'
import { hydrate, type QueryCacheNotifyEvent } from '@tanstack/vue-query'
import { isErpQueryKey, qk, queryClient } from '@/lib/queryClient'

/** Replaced at build time (vite.config.ts): the deploy's commit, or a build stamp. */
declare const __BUILD_ID__: string

export const MAX_AGE_MS = 24 * 60 * 60_000
export const RESTORE_BUDGET_MS = 300
const CACHE_KEY = 'query-cache'
const IDENTITY_KEY = 'offline-identity'
/** Coalesce saves: a page load fires dozens of cache events in a second. */
const SAVE_THROTTLE_MS = 2_000

const buildId = typeof __BUILD_ID__ === 'string' ? __BUILD_ID__ : 'dev'
export const busterFor = (userId: string) => `${userId}:${buildId}`

/* ------------------------------------------------------------- storage */

let warned = false
function warnOnce(what: string, error: unknown) {
  if (warned) return
  warned = true
  console.warn(`[cache] ${what}; carrying on without the saved copy.`, error)
}

/**
 * Its own database, like the draft and queue stores (see lib/drafts.ts for
 * why idb-keyval needs one database per store). Opened on first use, not at
 * import: this module is on the boot path, and a browser with IndexedDB
 * switched off must still boot.
 */
let store: UseStore | null | undefined
export function cacheStore(): UseStore | null {
  if (store === undefined) {
    try {
      store = createStore('sep-read-cache', 'kv')
    } catch (error) {
      warnOnce('IndexedDB is not available', error)
      store = null
    }
  }
  return store
}

const storage = {
  getItem: async (key: string): Promise<string | null> => {
    const s = cacheStore()
    if (!s) return null
    try {
      return (await get<string>(key, s)) ?? null
    } catch (error) {
      warnOnce('could not read the saved data', error)
      return null
    }
  },
  setItem: async (key: string, value: string): Promise<void> => {
    const s = cacheStore()
    if (!s) return
    try {
      await set(key, value, s)
    } catch (error) {
      warnOnce('could not save data for next time', error)
    }
  },
  removeItem: async (key: string): Promise<void> => {
    const s = cacheStore()
    if (!s) return
    try {
      await del(key, s)
    } catch (error) {
      warnOnce('could not clear the saved data', error)
    }
  },
}

/* -------------------------------------------------------------- policy */

/** Who the cache is being saved for right now; null = not saving. */
let persistingFor: string | null = null
let unsubscribe: (() => void) | null = null

/** Dropped, not saved: persisting stopped (or changed hands) since it was queued. */
class StaleSave extends Error {}

const persister = createAsyncStoragePersister({
  storage,
  key: CACHE_KEY,
  throttleTime: SAVE_THROTTLE_MS,
  // Runs when the throttled save actually executes, which can be seconds
  // after the cache event that queued it. Check the owner here, not there.
  serialize: (client) => {
    if (!persistingFor || client.buster !== busterFor(persistingFor)) {
      throw new StaleSave()
    }
    return JSON.stringify(client)
  },
})

const PERSISTED_ROOTS = new Set<unknown>([qk.settings()[0], qk.freshness()[0]])

/** Successful ERP reads, the feature flags and the freshness stamp. Nothing else. */
export function shouldPersistQuery(query: {
  queryKey: readonly unknown[]
  state: { status: string }
}): boolean {
  if (query.state.status !== 'success') return false
  return isErpQueryKey(query.queryKey) || PERSISTED_ROOTS.has(query.queryKey[0])
}

/* --------------------------------------------------------------- reads */

let pendingRead: { userId: string; read: Promise<PersistedClient | null> } | null = null

/**
 * Start reading the saved cache for `userId`. Called the moment a stored
 * session is known, so the IndexedDB read overlaps the profile round trip
 * instead of following it. Nothing is applied until restorePersistedCache()
 * has checked who this user turned out to be.
 */
export function readPersistedCache(userId: string): void {
  if (pendingRead?.userId === userId) return
  pendingRead = {
    userId,
    read: storage
      .getItem(CACHE_KEY)
      .then((raw) => (raw ? (JSON.parse(raw) as PersistedClient) : null))
      .catch((error) => {
        warnOnce('the saved data was unreadable', error)
        return null
      }),
  }
}

/**
 * Put a valid saved cache for `userId` into the query cache. An invalid one
 * (another user, another build, too old) is deleted — but only when saving
 * has not started yet, or the delete could land on top of a fresh save.
 */
function apply(userId: string, saved: PersistedClient | null): boolean {
  if (!saved) return false
  const valid =
    saved.buster === busterFor(userId) &&
    typeof saved.timestamp === 'number' &&
    Date.now() - saved.timestamp <= MAX_AGE_MS
  if (!valid) {
    if (!persistingFor) void storage.removeItem(CACHE_KEY)
    return false
  }
  try {
    // hydrate() only overwrites a query whose cached data is older than the
    // saved copy, so a late restore never clobbers a fresh network answer.
    hydrate(queryClient, saved.clientState)
    return true
  } catch (error) {
    warnOnce('the saved data could not be restored', error)
    if (!persistingFor) void storage.removeItem(CACHE_KEY)
    return false
  }
}

/**
 * Restore the saved cache for `userId`, waiting at most RESTORE_BUDGET_MS
 * (or `budgetMs`).
 * Call before anything mounts (the session store does, inside init()), so
 * restored data is in place before any query decides to fetch.
 *
 * If IndexedDB is slower than the budget, boot goes on without it and the
 * copy is applied when it arrives — still only for this user, and only if
 * they are still the one being persisted for.
 */
export async function restorePersistedCache(
  userId: string,
  opts: { budgetMs?: number; applyLate?: () => boolean } = {},
): Promise<boolean> {
  readPersistedCache(userId)
  const pending = pendingRead!
  const read = pending.read
  // One restore per read: a later restore (back online, a re-init) reads
  // the store again rather than replaying this answer.
  void read.finally(() => {
    if (pendingRead === pending) pendingRead = null
  })
  let timer: ReturnType<typeof setTimeout> | undefined
  const late = Symbol('late')
  const first = await Promise.race([
    read,
    new Promise<typeof late>((resolve) => {
      timer = setTimeout(() => resolve(late), opts.budgetMs ?? RESTORE_BUDGET_MS)
    }),
  ])
  clearTimeout(timer)
  if (first !== late) return apply(userId, first)

  const stillWanted = opts.applyLate ?? (() => persistingFor === userId)
  void read.then((saved) => {
    if (!stillWanted()) return
    // By now the heartbeat may already have seen today's load stamp, so it
    // would never flag this copy as older. Compare here instead.
    const stamp = (data: unknown) =>
      (data as { data_loaded_at?: string | null } | undefined)?.data_loaded_at
    const current = queryClient.getQueryData(qk.freshness())
    const savedFreshness = saved?.clientState.queries.find(
      (q) => q.queryKey[0] === qk.freshness()[0],
    )
    if (!apply(userId, saved)) return
    if (current !== undefined && stamp(savedFreshness?.state.data) !== stamp(current)) {
      void queryClient.invalidateQueries({
        predicate: (q) => isErpQueryKey(q.queryKey),
        refetchType: 'none',
      })
    }
  })
  return false
}

/** When the saved copy was written, for the offline banner; null if none. */
export async function savedCacheTimestamp(userId: string): Promise<number | null> {
  const raw = await storage.getItem(CACHE_KEY)
  try {
    const saved = raw ? (JSON.parse(raw) as PersistedClient) : null
    return saved && saved.buster === busterFor(userId) ? saved.timestamp : null
  } catch {
    return null
  }
}

/* -------------------------------------------------------------- writes */

/**
 * Cache events that change what would be saved: a persisted query's data
 * arriving, being invalidated or written, or the query coming or going. A
 * fetch starting, an observer mounting, any non-persisted query: none of
 * those touch the saved copy, so they don't re-serialize it.
 */
function changesSavedCopy(event: QueryCacheNotifyEvent): boolean {
  const key = event.query.queryKey
  if (!isErpQueryKey(key) && !PERSISTED_ROOTS.has(key[0])) return false
  if (event.type === 'added' || event.type === 'removed') return true
  if (event.type !== 'updated') return false
  const action = event.action.type
  return action === 'success' || action === 'invalidate' || action === 'setState'
}

/** Keep the cache saved for `userId` from now on. Idempotent. */
export function startPersisting(userId: string): void {
  if (persistingFor === userId && unsubscribe) return
  stopPersisting()
  if (!cacheStore()) return
  persistingFor = userId
  const options = {
    queryClient,
    persister,
    buster: busterFor(userId),
    dehydrateOptions: {
      shouldDehydrateQuery: shouldPersistQuery,
      shouldDehydrateMutation: () => false,
    },
  }
  unsubscribe = queryClient.getQueryCache().subscribe((event) => {
    if (changesSavedCopy(event)) void persistQueryClientSave(options)
  })
}

export function stopPersisting(): void {
  unsubscribe?.()
  unsubscribe = null
  persistingFor = null
}

/**
 * Stop saving and delete what is saved. Stopping is synchronous, so a
 * queryClient.clear() straight after this cannot be saved as an empty
 * cache (or, worse, race a queued save of the old one).
 */
export function wipePersistedCache(): Promise<void> {
  stopPersisting()
  pendingRead = null
  return Promise.all([
    storage.removeItem(CACHE_KEY),
    storage.removeItem(IDENTITY_KEY),
  ]).then(() => undefined)
}

/* ------------------------------------------------- offline identity */

/** The profile row as the session store holds it; only these fields matter here. */
export interface OfflineProfile {
  user_id: string
  role: string | null
  active: boolean | null
  [column: string]: unknown
}

export interface OfflineIdentity<P extends OfflineProfile = OfflineProfile> {
  profile: P
  savedAt: number
}

/**
 * Who the saved cache belongs to, kept beside it so the app can open on it
 * with no signal at all (session.ts, offline cold open). Written only for
 * the user being persisted for — i.e. a verified, active rep, online — and
 * deleted with the cache.
 */
export function saveOfflineIdentity(userId: string, profile: OfflineProfile): void {
  if (persistingFor !== userId || profile.user_id !== userId) return
  const record = { buster: busterFor(userId), savedAt: Date.now(), profile }
  void storage.setItem(IDENTITY_KEY, JSON.stringify(record))
}

/**
 * The saved identity for `userId`, only if it is still good enough to open
 * the app on: same user and build, under MAX_AGE, and an active rep. Null
 * otherwise — including whenever IndexedDB is unavailable.
 */
export async function readOfflineIdentity<P extends OfflineProfile>(
  userId: string,
): Promise<OfflineIdentity<P> | null> {
  const raw = await storage.getItem(IDENTITY_KEY)
  if (!raw) return null
  try {
    const record = JSON.parse(raw) as { buster?: string; savedAt?: number; profile?: P }
    const p = record.profile
    const fresh =
      typeof record.savedAt === 'number' && Date.now() - record.savedAt <= MAX_AGE_MS
    if (
      record.buster !== busterFor(userId) ||
      !fresh ||
      !p ||
      p.user_id !== userId ||
      p.role !== 'rep' ||
      p.active !== true
    ) {
      return null
    }
    return { profile: p, savedAt: record.savedAt! }
  } catch {
    return null
  }
}
