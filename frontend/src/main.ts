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
}

void bootstrap()
