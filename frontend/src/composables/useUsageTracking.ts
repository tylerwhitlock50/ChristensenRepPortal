import { onBeforeUnmount, onMounted, watch } from 'vue'
import { useRouter } from 'vue-router'
import { useSessionStore } from '@/stores/session'
import {
  configureUsage,
  flushUsage,
  pageViewFor,
  REVIEW_AFTER_MS,
  setCurrentPage,
  trackUsage,
  viewKey,
} from '@/lib/usage'

/**
 * Wires lib/usage.ts to the app, once, from App.vue: a page view per screen,
 * for Admin › Usage.
 *
 * A "view" is a change of screen (route + params), not of query string. A
 * screen that sat in a hidden tab and is looked at again after half an hour
 * counts once more: a rep who leaves In stock open all day and checks it
 * before each call is using it each time.
 */
export function useUsageTracking() {
  const session = useSessionStore()
  const router = useRouter()

  // Nothing is recorded until the person has agreed to the Privacy Policy
  // that describes it (session.legalAccepted, lib/legal.ts).
  const canTrack = () =>
    session.ready && session.isSignedIn && !session.isViewingAs && session.legalAccepted
  configureUsage(canTrack)

  let lastKey = ''
  let lastAt = 0

  function record(force = false) {
    const route = router.currentRoute.value
    const view = pageViewFor(route)
    setCurrentPage(view)
    // Not use of the portal (sign-in, the agreement screen): forget the last
    // screen, so coming back to it afterwards counts.
    if (!view) {
      lastKey = ''
      return
    }
    const key = viewKey(route)
    if (!force && key === lastKey) return
    // Not signed in yet (boot, the redirect to the sign-in page), or not
    // agreed yet: leave the key unset so the same screen is counted once the
    // session is there and the agreement is made.
    if (!canTrack()) return
    lastKey = key
    lastAt = Date.now()
    trackUsage(view)
  }

  const stop = router.afterEach((_to, _from, failure) => {
    if (!failure) record()
  })

  // The first screen after sign-in, after the agreement, and after an admin
  // stops viewing as a rep.
  watch(
    () => [session.ready, session.isSignedIn, session.isViewingAs, session.legalAccepted] as const,
    () => record(),
  )

  function onVisibility() {
    if (document.visibilityState === 'hidden') return flushUsage()
    if (lastKey && Date.now() - lastAt >= REVIEW_AFTER_MS) record(true)
  }

  onMounted(() => {
    // The screen the app opened on: main.ts mounts after the first
    // navigation has finished, so afterEach never fires for it.
    record()
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('pagehide', flushUsage)
  })
  onBeforeUnmount(() => {
    stop()
    document.removeEventListener('visibilitychange', onVisibility)
    window.removeEventListener('pagehide', flushUsage)
  })
}
