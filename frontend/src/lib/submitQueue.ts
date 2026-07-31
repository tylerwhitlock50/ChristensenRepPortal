/**
 * Visit-survey submit queue — TECH_STACK §2.5.
 *
 * "On submit failure, the payload (plus photo blobs) stays queued and retries
 *  on reconnect via a `navigator.onLine` listener. The UI says 'Saved — will
 *  sync when you're back online,' which is honest and stops the rep re-entering
 *  it."
 *
 * Scope is deliberately narrow. From the §2.5 not-in-v1 column: no Background
 * Sync API, no service worker, and **no queue for anything other than visit
 * surveys + their photos**. Notes, actions on recommendations and contact edits
 * all fail loudly instead — those are one tap to redo; a survey is not.
 *
 * Two rules this file exists to enforce:
 *
 *  1. Nothing is ever dropped. A row that keeps failing backs off, and after
 *     enough attempts it is surfaced as *stuck* — it is never deleted. A rep
 *     watching a survey vanish is the single biggest adoption risk in the PRD.
 *  2. A retry never duplicates. Each queued item records what already landed
 *     (`progress.actionId` / `visitId` / `photoIds`), so a submit that dies
 *     between the visit insert and the third photo resumes at the third photo.
 */

import { clear, createStore, del, entries, get, set } from 'idb-keyval'
import { onMounted, shallowRef, watch, type Ref, type ShallowRef } from 'vue'
import { useIntervalFn, useOnline } from '@vueuse/core'
import { useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { newPhotoId, uploadPhoto } from '@/lib/photos'
import { qk } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'
import type { TablesInsert } from '@/types/database.types'
import type { ActionType, PhotoCategory } from '@/types/domain'

/**
 * Separate database names, not separate stores inside one database:
 * idb-keyval's `createStore` opens the DB without a version, so a second store
 * name in an existing database is never created and every transaction against
 * it throws NotFoundError.
 */
const queueStore = createStore('sep-submit-queue', 'kv')
const draftPhotoStore = createStore('sep-draft-photos', 'kv')

/** After this many failures the item stops auto-retrying quietly and is surfaced. */
const STUCK_AFTER_ATTEMPTS = 5
const MAX_BACKOFF_MS = 15 * 60_000

/** A photo held in IndexedDB next to its draft, blob and all (§2.5). */
export interface QueuedPhoto {
  /** Stable across retries so a half-uploaded batch resumes instead of repeating. */
  id: string
  blob: Blob
  fileName: string
  contentType: string
  category: PhotoCategory | null
  caption: string | null
  /** True when the blob already went through `compressPhoto()`. */
  compressed: boolean
  /** Pre-compression size, kept only so the UI can show what was saved. */
  originalBytes: number | null
}

/** Everything needed to write one visit, offline, later, from cold storage. */
export interface VisitSubmission {
  /**
   * Who wrote it. IndexedDB is per-device, not per-user, so without this a
   * survey queued by one rep is flushed under the NEXT rep's JWT on a shared
   * truck iPad — misattributing the visit in rep_execution_summary and
   * account_coverage, or failing permanently if that rep doesn't share the
   * account. The flush refuses anything that isn't the signed-in user's.
   */
  userId: string
  customerKey: string
  /** `action_id` is filled in by the queue if `action` is present. */
  visit: Omit<TablesInsert<'visits'>, 'action_id'>
  /** The companion `actions` row, when the survey also logs the contact. */
  action?: {
    actionType: ActionType
    note?: string | null
    recommendationId?: number | null
    /**
     * The date the rep was in the store, NOT the date the phone reconnected.
     * account_coverage and rep_execution_summary both key off
     * actions.action_date, so letting it default to current_date at sync time
     * drops the contact out of the month it happened in.
     */
    actionDate?: string | null
    /**
     * An actions row a failed online submit already created. Reuse it —
     * inserting a second one double-counts coverage, and reps cannot delete
     * actions (admin-only policy), so nobody in the field can clean it up.
     */
    existingActionId?: number | null
  } | null
  photos: QueuedPhoto[]
}

export interface QueuedSubmit {
  id: string
  payload: VisitSubmission
  queuedAt: string
  attempts: number
  lastError: string | null
  lastAttemptAt: string | null
  /** ISO; the flush skips the item until then. Null means "try now". */
  nextAttemptAt: string | null
  progress: {
    actionId: number | null
    visitId: number | null
    /** `QueuedPhoto.id`s already in Storage + `public.photos`. */
    photoIds: string[]
  }
}

export interface FlushResult {
  sent: number
  failed: number
  remaining: number
  /** False when the flush was skipped because the device is offline. */
  attempted: boolean
  /**
   * Accounts that actually landed. The caller invalidates these — without it
   * the pending badge disappears while the account page still says "No
   * surveys yet", which is precisely the "my survey vanished" experience this
   * file exists to prevent.
   */
  customerKeys: string[]
}

/**
 * Shallow on purpose. A deep ref would hand out Vue Proxies, and a Proxy
 * cannot be structured-cloned into IndexedDB (DataCloneError) — the items have
 * to stay raw objects. Every mutation reassigns the array to trigger updates.
 */
const items = shallowRef<QueuedSubmit[]>([])
const isFlushing = shallowRef(false)
const lastFlushError = shallowRef<string | null>(null)
let hydrated = false
let inFlight: Promise<FlushResult> | null = null

function byQueuedAt(a: QueuedSubmit, b: QueuedSubmit): number {
  return a.queuedAt < b.queuedAt ? -1 : a.queuedAt > b.queuedAt ? 1 : 0
}

function looksQueued(value: unknown): value is QueuedSubmit {
  return (
    typeof value === 'object' &&
    value !== null &&
    'payload' in value &&
    'progress' in value
  )
}

/** Re-read the queue from IndexedDB into the shared reactive list. */
export async function refresh(): Promise<QueuedSubmit[]> {
  try {
    const rows = await entries<string, unknown>(queueStore)
    items.value = rows
      .map(([, value]) => value)
      .filter(looksQueued)
      .sort(byQueuedAt)
  } catch (err) {
    console.warn('[submitQueue] could not read the queue', err)
    items.value = []
  }
  hydrated = true
  return items.value
}

async function ensureHydrated(): Promise<void> {
  if (!hydrated) await refresh()
}

async function persist(item: QueuedSubmit): Promise<void> {
  await set(item.id, item, queueStore)
  items.value = [...items.value].sort(byQueuedAt)
}

/**
 * Park a visit survey for later. Call this when the submit failed *or* when
 * `navigator.onLine` is already false — the rep should never watch a spinner
 * they can't win.
 */
export async function enqueue(payload: VisitSubmission): Promise<QueuedSubmit> {
  await ensureHydrated()
  const item: QueuedSubmit = {
    id: newPhotoId(),
    payload,
    queuedAt: new Date().toISOString(),
    attempts: 0,
    lastError: null,
    lastAttemptAt: null,
    nextAttemptAt: null,
    progress: { actionId: null, visitId: null, photoIds: [] },
  }
  await set(item.id, item, queueStore)
  items.value = [...items.value, item].sort(byQueuedAt)
  return item
}

/** How many surveys are still waiting. Reads storage, not the cached list. */
export async function pendingCount(): Promise<number> {
  await refresh()
  return items.value.length
}

export async function removeQueued(id: string): Promise<void> {
  await del(id, queueStore)
  items.value = items.value.filter((i) => i.id !== id)
}

/** Admin/debug escape hatch. Never called on a failure path. */
export async function clearQueue(): Promise<void> {
  await clear(queueStore)
  items.value = []
}

function backoffMs(attempts: number): number {
  return Math.min(30_000 * 2 ** Math.max(0, attempts - 1), MAX_BACKOFF_MS)
}

function dueNow(item: QueuedSubmit, force: boolean): boolean {
  if (force || !item.nextAttemptAt) return true
  return item.nextAttemptAt <= new Date().toISOString()
}

/** Attempts >= STUCK_AFTER_ATTEMPTS: still queued, still safe, but worth saying so. */
export function isStuck(item: QueuedSubmit): boolean {
  return item.attempts >= STUCK_AFTER_ATTEMPTS
}

/**
 * Send one item, resuming from wherever the last attempt died. Each step is
 * persisted the moment it succeeds, so a mid-flight crash can't duplicate it.
 */
async function sendOne(item: QueuedSubmit): Promise<void> {
  const { payload } = item

  // An action the online path already created before it failed. Adopting it
  // is what stops the offline fallback from double-logging the same stop.
  if (payload.action?.existingActionId != null && item.progress.actionId == null) {
    item.progress.actionId = payload.action.existingActionId
    await persist(item)
  }

  if (payload.action && item.progress.actionId == null) {
    const { data, error } = await supabase
      .from('actions')
      .insert({
        customer_key: payload.customerKey,
        action_type: payload.action.actionType,
        note: payload.action.note?.trim() || null,
        recommendation_id: payload.action.recommendationId ?? null,
        // Explicit, never the current_date default — see VisitSubmission.
        ...(payload.action.actionDate
          ? { action_date: payload.action.actionDate }
          : {}),
      })
      .select('id')
      .single()
    if (error) throw error
    item.progress.actionId = data.id
    await persist(item)
  }

  if (item.progress.visitId == null) {
    const { data, error } = await supabase
      .from('visits')
      .insert({
        ...payload.visit,
        customer_key: payload.customerKey,
        action_id: item.progress.actionId,
      })
      .select('id')
      .single()
    if (error) throw error
    item.progress.visitId = data.id
    await persist(item)
  }

  for (const photo of payload.photos) {
    if (item.progress.photoIds.includes(photo.id)) continue
    await uploadPhoto({
      file: new File([photo.blob], photo.fileName, { type: photo.contentType }),
      customerKey: payload.customerKey,
      visitId: item.progress.visitId,
      category: photo.category,
      caption: photo.caption,
      skipCompression: photo.compressed,
    })
    item.progress.photoIds.push(photo.id)
    await persist(item)
  }
}

/**
 * Drain the queue oldest-first. Safe to call from anywhere and as often as you
 * like: concurrent calls share one in-flight run, and an offline device is a
 * no-op rather than a burst of doomed requests.
 */
export async function flush(options?: {
  force?: boolean
  /**
   * Only send items this user queued. Always pass it from a signed-in
   * context — see VisitSubmission.userId. Omitting it sends everything, which
   * is only correct in a test.
   */
  userId?: string
}): Promise<FlushResult> {
  if (inFlight) return inFlight
  inFlight = runFlush(options?.force ?? false, options?.userId).finally(() => {
    inFlight = null
  })
  return inFlight
}

async function runFlush(
  force: boolean,
  userId?: string,
): Promise<FlushResult> {
  await ensureHydrated()

  if (items.value.length === 0) {
    return { sent: 0, failed: 0, remaining: 0, attempted: true, customerKeys: [] }
  }
  if (typeof navigator !== 'undefined' && navigator.onLine === false) {
    return {
      sent: 0,
      failed: 0,
      remaining: items.value.length,
      attempted: false,
      customerKeys: [],
    }
  }

  isFlushing.value = true
  lastFlushError.value = null
  let sent = 0
  let failed = 0
  const customerKeys = new Set<string>()

  try {
    for (const item of [...items.value].sort(byQueuedAt)) {
      if (!dueNow(item, force)) continue
      // Never send another user's work under this user's JWT. Left in the
      // queue, not discarded — the original author may sign back in.
      if (userId && item.payload.userId && item.payload.userId !== userId) continue
      try {
        await sendOne(item)
        await removeQueued(item.id)
        sent += 1
        customerKeys.add(item.payload.customerKey)
      } catch (err) {
        failed += 1
        item.attempts += 1
        item.lastAttemptAt = new Date().toISOString()
        item.lastError = messageFor(err)
        item.nextAttemptAt = new Date(
          Date.now() + backoffMs(item.attempts),
        ).toISOString()
        lastFlushError.value = item.lastError
        await persist(item)
        // The connection dropped mid-drain; stop rather than burn the rest of
        // the queue's attempt counters on a network that isn't there.
        if (typeof navigator !== 'undefined' && navigator.onLine === false) break
      }
    }
  } finally {
    isFlushing.value = false
  }

  return {
    sent,
    failed,
    remaining: items.value.length,
    attempted: true,
    customerKeys: [...customerKeys],
  }
}

function messageFor(err: unknown): string {
  if (err && typeof err === 'object' && 'message' in err) {
    return String((err as { message: unknown }).message)
  }
  return 'Could not save that.'
}

/* ------------------------------------------------------------------------- *
 * Photo blobs held in IndexedDB alongside the draft (§2.5)
 *
 * The survey draft itself is JSON (see `lib/drafts.ts`), which would destroy a
 * Blob. Photos taken before the survey is submitted live here instead, keyed by
 * the same draft key, so closing the app mid-visit loses neither half.
 * ------------------------------------------------------------------------- */

/** Wrap a picked/compressed file so it can be persisted and replayed. */
export function toQueuedPhoto(
  file: File,
  meta: {
    category?: PhotoCategory | null
    caption?: string | null
    compressed?: boolean
    originalBytes?: number | null
  } = {},
): QueuedPhoto {
  return {
    id: newPhotoId(),
    blob: file,
    fileName: file.name || 'photo.jpg',
    contentType: file.type || 'image/jpeg',
    category: meta.category ?? null,
    caption: meta.caption ?? null,
    compressed: meta.compressed ?? false,
    originalBytes: meta.originalBytes ?? null,
  }
}

export async function stashDraftPhotos(
  draftKey: string,
  photos: QueuedPhoto[],
): Promise<void> {
  try {
    if (photos.length === 0) await del(draftKey, draftPhotoStore)
    else await set(draftKey, photos, draftPhotoStore)
  } catch (err) {
    console.warn('[submitQueue] could not stash draft photos', err)
  }
}

export async function loadDraftPhotos(draftKey: string): Promise<QueuedPhoto[]> {
  try {
    const stored = await get<unknown>(draftKey, draftPhotoStore)
    return Array.isArray(stored) ? (stored as QueuedPhoto[]) : []
  } catch (err) {
    console.warn('[submitQueue] could not read draft photos', err)
    return []
  }
}

export async function clearDraftPhotos(draftKey: string): Promise<void> {
  try {
    await del(draftKey, draftPhotoStore)
  } catch (err) {
    console.warn('[submitQueue] could not clear draft photos', err)
  }
}

/* ------------------------------------------------------------------------- */

export interface UseSubmitQueue {
  /** Every waiting survey, oldest first. */
  items: ShallowRef<QueuedSubmit[]>
  /** How many surveys are waiting. This is the whole sync UI budget (§2.5). */
  pending: ShallowRef<number>
  /** Waiting *and* repeatedly failing — worth telling someone about. */
  stuck: ShallowRef<number>
  isFlushing: ShallowRef<boolean>
  lastError: ShallowRef<string | null>
  online: Readonly<Ref<boolean>>
  /** Scoped to the signed-in user and invalidates whatever landed. */
  flush: (options?: { force?: boolean }) => Promise<FlushResult>
  refresh: typeof refresh
  remove: typeof removeQueued
}

/**
 * Reactive view of the queue that flushes when the phone comes back online.
 *
 * `navigator.onLine` only proves the radio is up, not that Supabase is
 * reachable, so a slow interval keeps retrying while anything is pending and
 * stops the moment the queue empties.
 */
export function useSubmitQueue(): UseSubmitQueue {
  const online = useOnline()
  const pending = shallowRef(items.value.length)
  const stuck = shallowRef(items.value.filter(isStuck).length)
  const session = useSessionStore()
  const qc = useQueryClient()

  /**
   * Every flush from a component goes through here so two things always
   * happen: it is scoped to the signed-in user, and whatever landed is
   * invalidated. Calling `flush()` bare from a component is the bug.
   */
  async function flushForUser(options?: { force?: boolean }) {
    const result = await flush({
      force: options?.force ?? false,
      userId: session.user?.id,
    })
    for (const customerKey of result.customerKeys) {
      void qc.invalidateQueries({ queryKey: qk.account.root(customerKey) })
    }
    if (result.customerKeys.length > 0) {
      void qc.invalidateQueries({ queryKey: qk.me.needsAttention() })
    }
    return result
  }

  const retry = useIntervalFn(
    () => {
      if (online.value) void flushForUser()
    },
    60_000,
    { immediate: false },
  )

  watch(
    items,
    (list) => {
      pending.value = list.length
      stuck.value = list.filter(isStuck).length
      if (list.length > 0 && online.value) retry.resume()
      else retry.pause()
    },
    { immediate: true },
  )

  // The reconnect trigger §2.5 actually asks for.
  watch(online, (isOnline) => {
    if (!isOnline) {
      retry.pause()
      return
    }
    if (items.value.length > 0) {
      retry.resume()
      void flushForUser({ force: true })
    }
  })

  onMounted(() => {
    void refresh().then(() => {
      if (online.value && items.value.length > 0) void flushForUser()
    })
  })

  return {
    items,
    pending,
    stuck,
    isFlushing,
    lastError: lastFlushError,
    online,
    flush: flushForUser,
    refresh,
    remove: removeQueued,
  }
}
