import { computed, ref, watch } from 'vue'
import { useSessionStore } from '@/stores/session'

/**
 * "My plan" — the accounts a rep has starred for the day's calls or drive,
 * in the order they starred them (the order "Route these" drives them).
 *
 * Per device and per user, in localStorage: a starred list is a scratchpad,
 * not a record anyone else reads, and it has to work in a store with no
 * signal. Keyed by user id so a shared truck iPad keeps two reps' plans
 * apart. Every storage access is wrapped — private mode and blocked site
 * data still get a working (in-memory) plan for the page load.
 *
 * Module-level state: the star on a card and the "My plan (n)" chip are
 * different components and must agree without a round trip.
 */

const PREFIX = 'rep-portal:plan:'
/** A day's plan, not a second account list. */
export const MAX_PLAN = 50

const byUser = ref<Record<string, string[]>>({})

function read(userId: string): string[] {
  try {
    const raw = localStorage.getItem(PREFIX + userId)
    const parsed: unknown = raw ? JSON.parse(raw) : []
    return Array.isArray(parsed)
      ? parsed.filter((k): k is string => typeof k === 'string' && !!k).slice(0, MAX_PLAN)
      : []
  } catch {
    return []
  }
}

function write(userId: string, keys: string[]) {
  try {
    if (keys.length) localStorage.setItem(PREFIX + userId, JSON.stringify(keys))
    else localStorage.removeItem(PREFIX + userId)
  } catch {
    /* the in-memory copy still works for this page load */
  }
}

/** Pure: star or unstar `key`, keeping star order and the cap. */
export function togglePlanKey(keys: readonly string[], key: string): string[] {
  if (keys.includes(key)) return keys.filter((k) => k !== key)
  if (keys.length >= MAX_PLAN) return [...keys]
  return [...keys, key]
}

export function usePlan() {
  const session = useSessionStore()
  /**
   * The plan belongs to whoever is signed in. While an admin views as a rep
   * it is the ADMIN's scratchpad — the rep's lives on the rep's phone.
   */
  const userId = computed(() => session.user?.id ?? '')

  watch(
    userId,
    (id) => {
      if (id && !(id in byUser.value)) byUser.value = { ...byUser.value, [id]: read(id) }
    },
    { immediate: true },
  )

  const keys = computed<string[]>(() => byUser.value[userId.value] ?? [])
  const keySet = computed(() => new Set(keys.value))
  const full = computed(() => keys.value.length >= MAX_PLAN)

  function set(next: string[]) {
    const id = userId.value
    if (!id) return
    byUser.value = { ...byUser.value, [id]: next }
    write(id, next)
  }

  return {
    keys,
    count: computed(() => keys.value.length),
    full,
    has: (key: string) => keySet.value.has(key),
    toggle: (key: string) => set(togglePlanKey(keys.value, key)),
    clear: () => set([]),
  }
}
