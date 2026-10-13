import { createApp } from 'vue'
import { createPinia } from 'pinia'
import { VueQueryPlugin } from '@tanstack/vue-query'

// Self-hosted Barlow, latin only, the nine faces style.css asks for. They
// used to come from Google Fonts: a render-blocking stylesheet on a third
// origin, two extra DNS + TLS handshakes before text drew right on LTE, and
// not something a service worker could keep for a store with no signal.
import '@fontsource/barlow/latin-400.css'
import '@fontsource/barlow/latin-500.css'
import '@fontsource/barlow/latin-600.css'
import '@fontsource/barlow/latin-700.css'
import '@fontsource/barlow-condensed/latin-500.css'
import '@fontsource/barlow-condensed/latin-600.css'
import '@fontsource/barlow-condensed/latin-700.css'
import '@fontsource/barlow-semi-condensed/latin-500.css'
import '@fontsource/barlow-semi-condensed/latin-600.css'
import './style.css'
import App from './App.vue'
import router from './router'
import { queryClient } from './lib/queryClient'
import { registerServiceWorker } from './lib/pwa'
import { isWarming } from './lib/warmPages'
import { useSessionStore } from './stores/session'

/**
 * Start fetching the code for the page being opened while the session store
 * waits on the database. The router would otherwise ask for it only after
 * the profile round trip, one more serial step on a morning open. Calling a
 * lazy route's loader early is free: import() is cached, so the router's own
 * call later gets the same promise.
 */
function warmRoute() {
  const { pathname, search, hash } = window.location
  for (const record of router.resolve(pathname + search + hash).matched) {
    for (const component of Object.values(record.components ?? {})) {
      // Every route here is `() => import(...)`; an already-resolved
      // component is an object and is skipped.
      if (typeof component !== 'function') continue
      try {
        void Promise.resolve((component as () => unknown)()).catch(() => {})
      } catch {
        /* the router will load it the usual way */
      }
    }
  }
}

/**
 * After a deploy, a tab opened on the previous build still asks for that
 * build's chunk names, which Vercel no longer serves, and the next page the
 * rep taps fails to load. One reload picks up the new build and lands them
 * where they were going. The stamp stops a reload loop when the chunk is
 * missing for some other reason, and nothing reloads while offline: a
 * reload with no signal is the browser's dinosaur, not the app.
 */
const RELOADED_AT_KEY = 'rep-portal:chunk-reload-at'

function reloadForNewBuild(path?: string): boolean {
  if (navigator.onLine === false) return false
  try {
    const last = Number(sessionStorage.getItem(RELOADED_AT_KEY) ?? 0)
    if (Date.now() - last < 60_000) return false
    sessionStorage.setItem(RELOADED_AT_KEY, String(Date.now()))
  } catch {
    // No sessionStorage, no loop guard — let the error surface instead.
    return false
  }
  if (path) window.location.assign(path)
  else window.location.reload()
  return true
}

function isChunkLoadError(error: unknown): boolean {
  return /dynamically imported module|importing a module script failed|unable to preload css/i.test(
    (error as { message?: string } | null)?.message ?? '',
  )
}

window.addEventListener('vite:preloadError', (event) => {
  // A background warm-up (lib/warmPages.ts) failing is not worth a reload;
  // if the rep then taps through, the router's hook below handles it.
  if (isWarming()) return
  if (reloadForNewBuild()) event.preventDefault()
})

// Not every lazy import goes through Vite's preload helper; a route
// component that fails to load surfaces here instead.
router.onError((error, to) => {
  if (isChunkLoadError(error)) reloadForNewBuild(to.fullPath)
})

async function bootstrap() {
  const app = createApp(App)

  app.use(createPinia())
  app.use(VueQueryPlugin, { queryClient })

  // Resolve the session before the router mounts, so a deep link never flashes
  // the login screen on its way to the page the user actually asked for.
  await useSessionStore().init({ onSession: warmRoute })

  app.use(router)
  await router.isReady()
  app.mount('#app')

  // After the first paint, not before: installing the offline copy of the
  // app competes with the page's own requests on a slow connection.
  void registerServiceWorker().catch(() => {})
}

void bootstrap()
