import { computed, ref, watch, type Ref } from 'vue'
import type { RouteLocationNormalized, Router } from 'vue-router'
import type { QueryClient } from '@tanstack/vue-query'
import { qk } from '@/lib/queryClient'

/**
 * The dealers this rep opened lately — what the header search shows before
 * anything is typed. Most "find" moments are a return trip ("the dealer I
 * was just on the phone with"), and a list of eight beats retyping a name.
 *
 * Recorded by a router.afterEach hook on the 'account' route (installed by
 * the header search, so no edit to the router is needed), kept in
 * localStorage per user id — a shared truck iPad must not show the next
 * rep the last one's dealers. The name comes from whatever the query cache
 * already holds; a key opened cold is stored without one and named the next
 * time it is seen (or by the search sheet, which can look it up).
 */

export interface RecentAccount {
  customer_key: string
  customer_name: string | null
  /** ISO timestamp of the visit. */
  at: string
}

export const MAX_RECENT_ACCOUNTS = 8

const STORAGE_PREFIX = 'rp:recent-accounts:'

/** Most recent first, one entry per key, at most MAX_RECENT_ACCOUNTS. Pure. */
export function withRecentAccount(
  list: readonly RecentAccount[],
  entry: RecentAccount,
): RecentAccount[] {
  const previous = list.find((r) => r.customer_key === entry.customer_key)
  const merged: RecentAccount = {
    ...entry,
    // A visit before the name loaded must not erase a name we already had.
    customer_name: entry.customer_name ?? previous?.customer_name ?? null,
  }
  return [merged, ...list.filter((r) => r.customer_key !== entry.customer_key)].slice(
    0,
    MAX_RECENT_ACCOUNTS,
  )
}

/** Whatever localStorage holds, defensively: it is user-editable state. */
export function parseRecentAccounts(raw: string | null): RecentAccount[] {
  if (!raw) return []
  try {
    const value: unknown = JSON.parse(raw)
    if (!Array.isArray(value)) return []
    return value
      .filter(
        (r): r is RecentAccount =>
          !!r &&
          typeof r === 'object' &&
          typeof (r as RecentAccount).customer_key === 'string' &&
          (r as RecentAccount).customer_key !== '',
      )
      .map((r) => ({
        customer_key: r.customer_key,
        customer_name: typeof r.customer_name === 'string' ? r.customer_name : null,
        at: typeof r.at === 'string' ? r.at : '',
      }))
      .slice(0, MAX_RECENT_ACCOUNTS)
  } catch {
    return []
  }
}

function read(userId: string): RecentAccount[] {
  try {
    return parseRecentAccounts(localStorage.getItem(STORAGE_PREFIX + userId))
  } catch {
    return []
  }
}

function write(userId: string, list: RecentAccount[]): void {
  try {
    localStorage.setItem(STORAGE_PREFIX + userId, JSON.stringify(list))
  } catch {
    // Private mode or full storage: recents are a convenience, not state.
  }
}

/**
 * A dealer's name from the reads the app has already made: the account
 * page's own dim_customer row, then the Overview's book. Null when neither
 * has it yet.
 */
export function cachedAccountName(client: QueryClient, customerKey: string): string | null {
  const detail = client.getQueryData<{ customer_name?: string | null } | null>(
    qk.account.detail(customerKey),
  )
  if (detail?.customer_name) return detail.customer_name
  const book = client.getQueryData<{ customer_key: string; customer_name: string | null }[]>(
    qk.intel.territoryYoy(),
  )
  return book?.find((r) => r.customer_key === customerKey)?.customer_name ?? null
}

/* One list per page load, shared by every caller; re-read when the user
   changes (sign-out, sign-in as someone else on the same tab). */
const recents: Ref<RecentAccount[]> = ref([])
let loadedFor: string | null = null

function ensureLoaded(userId: string) {
  if (loadedFor === userId) return
  loadedFor = userId
  recents.value = userId ? read(userId) : []
}

/** Record one visit for this user; a no-op without a user. */
export function recordRecentAccount(
  userId: string | null | undefined,
  customerKey: string,
  customerName: string | null,
): void {
  if (!userId || !customerKey) return
  ensureLoaded(userId)
  recents.value = withRecentAccount(recents.value, {
    customer_key: customerKey,
    customer_name: customerName,
    at: new Date().toISOString(),
  })
  write(userId, recents.value)
}

/** Fill in names learned later, without reordering anything. */
export function nameRecentAccounts(
  userId: string | null | undefined,
  names: Record<string, string>,
): void {
  if (!userId) return
  ensureLoaded(userId)
  let changed = false
  const next = recents.value.map((r) => {
    const name = names[r.customer_key]
    if (!r.customer_name && name) {
      changed = true
      return { ...r, customer_name: name }
    }
    return r
  })
  if (changed) {
    recents.value = next
    write(userId, next)
  }
}

let installed = false

/**
 * Register the afterEach hook once per app. `getUserId` is read at each
 * navigation, so a sign-in later in the session records under the right id.
 * The current route counts too: the hook arrives after the first
 * navigation, which may already have been an account page (a deep link).
 */
export function installRecentAccountsTracking(
  router: Router,
  client: QueryClient,
  getUserId: () => string | null | undefined,
): void {
  if (installed) return
  installed = true
  const visit = (to: RouteLocationNormalized) => {
    if (to.name !== 'account') return
    const key = typeof to.params.customerKey === 'string' ? to.params.customerKey : ''
    if (key) recordRecentAccount(getUserId(), key, cachedAccountName(client, key))
  }
  router.afterEach((to, _from, failure) => {
    if (!failure) visit(to)
  })
  visit(router.currentRoute.value)
}

/** The list for the signed-in user, reactive; follows a change of user. */
export function useRecentAccounts(getUserId: () => string | null | undefined) {
  watch(getUserId, (uid) => ensureLoaded(uid ?? ''), { immediate: true })
  return { recents: computed(() => recents.value) }
}
