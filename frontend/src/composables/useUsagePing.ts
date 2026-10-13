import { onBeforeUnmount, onMounted, watch } from 'vue'
import { supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'

/**
 * "Is the field actually using this?" — counted from app opens, not just
 * password sign-ins.
 *
 * login_events (006) feeds Last active / logins 30d in v_rep_activity and
 * rep_execution_summary, but until now only signIn() wrote a row. A rep on a
 * persisted session who opens the app every morning, or comes back to a
 * Safari tab that has been sitting there for a week, never signs in, so they
 * looked inactive — and "is it a habit yet?" is the question that decides
 * when the capture features come back.
 *
 * So this calls the same log_login() RPC when the app boots with a session
 * and whenever the tab comes back into view, at most once per four hours per
 * user. The RPC is the sanctioned write path (security definer, auth.uid()
 * only, no client insert policy), so nothing here can log anyone else.
 *
 * Never while an admin is viewing as a rep: the row would be the admin's own
 * (log_login reads auth.uid()), but browsing a rep's book is support work,
 * not use of the portal, and it should not move anybody's activity numbers.
 */

/** One open per this window counts. A morning and an afternoon session = 2. */
export const PING_INTERVAL_MS = 4 * 60 * 60_000

const STAMP_PREFIX = 'rep-portal:usage-ping:'

/**
 * The fallback when localStorage throws (private mode, blocked site data):
 * still at most one ping per window for this page load.
 */
const memoryStamps = new Map<string, number>()

function readStamp(userId: string): number {
  try {
    const raw = localStorage.getItem(STAMP_PREFIX + userId)
    const n = raw == null ? NaN : Number(raw)
    if (Number.isFinite(n)) return n
  } catch {
    /* storage unavailable — memory below */
  }
  return memoryStamps.get(userId) ?? 0
}

function writeStamp(userId: string, at: number) {
  memoryStamps.set(userId, at)
  try {
    localStorage.setItem(STAMP_PREFIX + userId, String(at))
  } catch {
    /* memory copy above still dedupes this page load */
  }
}

/** Pure: should an open at `now` be logged, given the last stamp? */
export function isPingDue(lastStamp: number, now: number): boolean {
  // A stamp from the future (clock moved back) counts as stale, not as
  // "logged forever".
  return !(lastStamp > 0 && lastStamp <= now && now - lastStamp < PING_INTERVAL_MS)
}

/**
 * Wire once, from App.vue. Everything is fire-and-forget: a failed log must
 * never cost the rep a frame.
 */
export function useUsagePing() {
  const session = useSessionStore()

  /**
   * True once this page load has seen nobody signed in. The next sign-in
   * after that is signIn(), which writes its own login_events row — so that
   * one only stamps, or a password sign-in would count twice.
   */
  let sawSignedOut = false

  function maybePing(reason: 'open' | 'signed-in') {
    if (!session.ready || !session.isSignedIn || session.isViewingAs) return
    const userId = session.user?.id
    if (!userId) return
    const now = Date.now()
    if (!isPingDue(readStamp(userId), now)) return
    // Stamped before the request, like the brief guard on the Overview: a
    // log that fails must not retry on every tab switch.
    writeStamp(userId, now)
    if (reason === 'signed-in') return
    void supabase.rpc('log_login').then(
      () => {},
      () => {},
    )
  }

  watch(
    () => [session.ready, session.isSignedIn, session.isViewingAs, session.user?.id] as const,
    ([ready, signedIn]) => {
      if (!ready) return
      if (!signedIn) {
        sawSignedOut = true
        return
      }
      maybePing(sawSignedOut ? 'signed-in' : 'open')
    },
    { immediate: true },
  )

  function onVisibility() {
    if (document.visibilityState === 'visible') maybePing('open')
  }

  onMounted(() => document.addEventListener('visibilitychange', onVisibility))
  onBeforeUnmount(() => document.removeEventListener('visibilitychange', onVisibility))
}
