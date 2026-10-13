/// <reference types="vite-plugin-pwa/vanillajs" />
/**
 * Service worker registration and the "new version" signal for AppShell's
 * toast. The worker itself is configured in vite.config.ts.
 *
 * Registered from main.ts on every page, sign-in included, so the app is
 * cached for offline use from the very first visit. A new deploy is never
 * applied behind the rep's back: `updateReady` turns true, AppShell offers
 * "Refresh", and only that tap swaps the code (and reloads).
 *
 * An open app looks for a new deploy when it comes back to the foreground
 * and hourly while visible — one small request for sw.js, which Vercel
 * serves uncached (vercel.json).
 */
import { ref } from 'vue'

const CHECK_EVERY_MS = 60 * 60_000

/** Replaced at build time (vite.config.ts): true on a Vercel preview build. */
declare const __AUTO_UPDATE__: boolean
const autoUpdate = typeof __AUTO_UPDATE__ === 'boolean' && __AUTO_UPDATE__

/** A new version is downloaded and waiting for the rep's go-ahead. */
export const updateReady = ref(false)

let applyUpdate: ((reload?: boolean) => Promise<void>) | null = null

export async function registerServiceWorker(): Promise<void> {
  if (!('serviceWorker' in navigator)) return
  // workbox-window loads here, after first paint, not in the entry chunk.
  const { registerSW } = await import('virtual:pwa-register')
  applyUpdate = registerSW({
    immediate: true,
    onNeedRefresh() {
      // Preview builds only: take the new deploy straight away, so a plain
      // reload after a push shows the push (see vite.config.ts).
      if (autoUpdate && applyUpdate) {
        void applyUpdate(true)
        return
      }
      updateReady.value = true
    },
    onRegisteredSW(_url, registration) {
      if (!registration) return
      const check = () => {
        if (document.visibilityState !== 'visible' || navigator.onLine === false) return
        registration.update().catch(() => {
          /* no signal; next time */
        })
      }
      setInterval(check, CHECK_EVERY_MS)
      document.addEventListener('visibilitychange', check)
    },
    onRegisterError(error) {
      // The app works the same without it, just not offline.
      console.warn('[pwa] service worker registration failed', error)
    },
  })
}

/** The toast's Refresh: activate the waiting worker and reload onto it. */
export async function reloadToUpdate(): Promise<void> {
  updateReady.value = false
  if (applyUpdate) await applyUpdate(true)
  else window.location.reload()
}

/**
 * The toast's ×: hide it for now. The new version also takes over by itself
 * the next time the app is fully closed and reopened.
 */
export function dismissUpdate(): void {
  updateReady.value = false
}
