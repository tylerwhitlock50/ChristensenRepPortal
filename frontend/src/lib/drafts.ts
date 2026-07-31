/**
 * Offline draft store — TECH_STACK §2.5.
 *
 * "Every keystroke in the visit survey writes to IndexedDB under a draft key.
 *  If the app is killed, backgrounded by a phone call, or loses signal, the
 *  draft survives."
 *
 * Scope discipline, straight from the §2.5 in-v1 / not-in-v1 table:
 *   IN  — draft written to IndexedDB on change (debounced ~500ms), restored if
 *         the app is killed or backgrounded.
 *   OUT — offline *reading*, service workers, Background Sync, conflict
 *         resolution. A draft belongs to one device and one rep; the last
 *         write on that device wins, and there is nothing to merge.
 *
 * Values are stored as plain JSON. Vue reactive state is a Proxy and a Proxy
 * cannot be structured-cloned into IndexedDB (DataCloneError), so `useDraft`
 * round-trips through JSON before writing — which also gives us free change
 * detection. Blobs therefore do NOT belong here; photo blobs live in
 * `submitQueue.ts` (`stashDraftPhotos`), which keeps them intact.
 */

import { createStore, del, entries, get, set } from 'idb-keyval'
import {
  onScopeDispose,
  ref,
  toValue,
  watch,
  type MaybeRefOrGetter,
  type Ref,
} from 'vue'
import { useEventListener, watchDebounced } from '@vueuse/core'

/**
 * One idb-keyval store per *database*. idb-keyval's `createStore` opens the DB
 * without a version, so a second store name inside the same DB name would
 * never be created and every transaction against it would throw
 * NotFoundError. Each store gets its own database name for that reason.
 */
const draftStore = createStore('sep-drafts', 'kv')

/** What actually lands in IndexedDB. */
export interface DraftRecord<T = unknown> {
  key: string
  value: T
  /** ISO timestamp of the last write — powers "Saved 2 minutes ago". */
  updatedAt: string
}

/** Draft keys are namespaced by kind so `listDrafts()` stays readable. */
export function visitDraftKey(customerKey: string): string {
  return `visit:${customerKey}`
}

/**
 * Private-mode Safari and a couple of Android WebViews throw the moment you
 * touch IndexedDB. Losing persistence is bad; taking the survey down with it
 * is worse, so we degrade to an in-memory map and keep going.
 */
const memory = new Map<string, DraftRecord>()
let idbUsable = true

function idbFailed(op: string, err: unknown): void {
  if (idbUsable) {
    idbUsable = false
    console.warn(
      `[drafts] IndexedDB unavailable during ${op}; drafts will only survive ` +
        'until this tab closes.',
      err,
    )
  }
}

function isRecord(value: unknown): value is DraftRecord {
  return (
    typeof value === 'object' &&
    value !== null &&
    'value' in value &&
    'updatedAt' in value
  )
}

/** Write a draft. Overwrites whatever was there — drafts are single-slot. */
export async function saveDraft(key: string, value: unknown): Promise<void> {
  const record: DraftRecord = {
    key,
    value,
    updatedAt: new Date().toISOString(),
  }
  memory.set(key, record)
  if (!idbUsable) return
  try {
    await set(key, record, draftStore)
    memory.delete(key)
  } catch (err) {
    idbFailed('saveDraft', err)
  }
}

/** The stored record, including when it was last written. */
export async function loadDraftRecord<T>(
  key: string,
): Promise<DraftRecord<T> | null> {
  const cached = memory.get(key)
  if (cached) return cached as DraftRecord<T>
  if (!idbUsable) return null
  try {
    const stored = await get<unknown>(key, draftStore)
    return isRecord(stored) ? (stored as DraftRecord<T>) : null
  } catch (err) {
    idbFailed('loadDraft', err)
    return null
  }
}

/** The draft body, or null when there isn't one. */
export async function loadDraft<T>(key: string): Promise<T | null> {
  const record = await loadDraftRecord<T>(key)
  return record ? record.value : null
}

export async function clearDraft(key: string): Promise<void> {
  memory.delete(key)
  if (!idbUsable) return
  try {
    await del(key, draftStore)
  } catch (err) {
    idbFailed('clearDraft', err)
  }
}

/** Every saved draft, newest first. Use it to offer "resume where you left off". */
export async function listDrafts(): Promise<DraftRecord[]> {
  const found = new Map<string, DraftRecord>(memory)
  if (idbUsable) {
    try {
      for (const [key, value] of await entries<string, unknown>(draftStore)) {
        if (isRecord(value) && !found.has(key)) found.set(key, value)
      }
    } catch (err) {
      idbFailed('listDrafts', err)
    }
  }
  return [...found.values()].sort((a, b) =>
    a.updatedAt < b.updatedAt ? 1 : -1,
  )
}

export interface UseDraftOptions<T> {
  /** Empty-form shape. A function is called fresh each time, so no shared refs. */
  initial: T | (() => T)
  /** §2.5 says ~500ms. Lower it only with a real reason. */
  debounceMs?: number
  /** Stop persisting without unmounting — e.g. after a successful submit. */
  enabled?: MaybeRefOrGetter<boolean>
}

export interface UseDraftReturn<T> {
  /** Bind the form to this. Every change is persisted, debounced. */
  state: Ref<T>
  /** True until the first read off disk settles. Don't submit before it's false. */
  restoring: Ref<boolean>
  /** True when `state` came off disk rather than from `initial`. */
  restored: Ref<boolean>
  /** ISO timestamp of the last successful write, or null. */
  savedAt: Ref<string | null>
  /** Persist right now, skipping the debounce. */
  flush: () => Promise<void>
  /** Delete the draft and reset `state` to `initial`. Call after a real submit. */
  discard: () => Promise<void>
}

/**
 * Debounced, self-restoring draft binding.
 *
 * ```ts
 * const { state, restored, discard } = useDraft(
 *   computed(() => visitDraftKey(customerKey.value)),
 *   { initial: () => emptySurvey() },
 * )
 * ```
 *
 * The key may be a ref/getter: switching accounts saves the old draft and
 * loads the new one.
 */
export function useDraft<T>(
  key: MaybeRefOrGetter<string>,
  options: UseDraftOptions<T>,
): UseDraftReturn<T> {
  const makeInitial = (): T =>
    typeof options.initial === 'function'
      ? (options.initial as () => T)()
      : structuredCloneish(options.initial as T)

  const state = ref(makeInitial()) as Ref<T>
  const restoring = ref(true)
  const restored = ref(false)
  const savedAt = ref<string | null>(null)

  /**
   * The last snapshot we wrote, as JSON. Comparing against it does two jobs:
   * it stops the restore itself from being persisted straight back, and it
   * skips no-op writes (Vue fires deep watchers on identical assignments).
   */
  let lastPersisted = ''
  let loadedKey = ''

  const isEnabled = (): boolean =>
    options.enabled === undefined ? true : !!toValue(options.enabled)

  async function load(k: string): Promise<void> {
    loadedKey = k
    restoring.value = true
    restored.value = false
    try {
      const record = k ? await loadDraftRecord<T>(k) : null
      // The key can change while the read is in flight — ignore a stale answer.
      if (loadedKey !== k) return
      if (record) {
        state.value = record.value
        savedAt.value = record.updatedAt
        restored.value = true
      } else {
        state.value = makeInitial()
        savedAt.value = null
      }
      lastPersisted = JSON.stringify(state.value)
    } finally {
      if (loadedKey === k) restoring.value = false
    }
  }

  async function persist(): Promise<void> {
    const k = toValue(key)
    if (!k || restoring.value || !isEnabled()) return
    const snapshot = JSON.stringify(state.value)
    if (snapshot === lastPersisted) return
    lastPersisted = snapshot
    // JSON.parse gives a plain, proxy-free deep copy. Writing the reactive
    // object directly throws DataCloneError — a Proxy is not cloneable.
    await saveDraft(k, JSON.parse(snapshot))
    savedAt.value = new Date().toISOString()
  }

  watch(() => toValue(key), (k) => void load(k), { immediate: true })

  watchDebounced(state, () => void persist(), {
    debounce: options.debounceMs ?? 500,
    // Nothing gets held back for more than a second, however fast the typing.
    maxWait: 2000,
    deep: true,
  })

  /**
   * The debounce is the one hole in "the draft survives being killed": a phone
   * call arriving 200ms after the last keystroke would drop it. Both of these
   * fire before the tab is frozen, so the write is issued in time.
   */
  useEventListener(window, 'pagehide', () => void persist())
  useEventListener(document, 'visibilitychange', () => {
    if (document.visibilityState === 'hidden') void persist()
  })
  onScopeDispose(() => void persist())

  async function discard(): Promise<void> {
    const k = toValue(key)
    if (k) await clearDraft(k)
    state.value = makeInitial()
    lastPersisted = JSON.stringify(state.value)
    savedAt.value = null
    restored.value = false
  }

  return { state, restoring, restored, savedAt, flush: persist, discard }
}

/** Deep copy without dragging in a dependency; drafts are JSON by contract. */
function structuredCloneish<T>(value: T): T {
  return value === undefined ? value : (JSON.parse(JSON.stringify(value)) as T)
}
