import { watch } from 'vue'
import { useRouter } from 'vue-router'
import { useSessionStore } from '@/stores/session'

/**
 * Keeps an open screen honest when the status changes under it: a version
 * published mid-visit (re-read when the app comes back to the foreground),
 * or a status that only arrives after the first page is up. The router
 * guard covers every navigation; this covers staying put. Wire once, from
 * App.vue.
 */
export function useLegalGate() {
  const session = useSessionStore()
  const router = useRouter()
  watch(
    () => [session.ready, session.isSignedIn, session.legalAccepted] as const,
    ([ready, signedIn, accepted]) => {
      if (!ready || !signedIn || accepted) return
      const current = router.currentRoute.value
      if (current.meta.public || current.name === 'agreements') return
      void router.replace({ name: 'agreements', query: { redirect: current.fullPath } })
    },
  )
}
