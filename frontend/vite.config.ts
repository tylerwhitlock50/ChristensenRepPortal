import { createHash } from 'node:crypto'
import { readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

/**
 * The saved read cache is keyed to this (lib/queryPersist.ts) so a phone
 * never restores data shaped for an older build. It is a hash of the code
 * that shapes what is saved — every query function and mapper lives in
 * src/composables and src/lib — not the commit: keyed to the commit, every
 * deploy (copy, a button, a page layout) threw the copy away, and the
 * first cold open after one with no signal had nothing to show. A deploy
 * that touches any of those files still starts the copy over.
 */
function hashSources(dirs: string[]): string {
  const hash = createHash('sha256')
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
      a.name < b.name ? -1 : a.name > b.name ? 1 : 0,
    )) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) walk(path)
      else if (/\.(ts|vue)$/.test(entry.name)) {
        hash.update(path)
        hash.update(readFileSync(path))
      }
    }
  }
  for (const dir of dirs) walk(fileURLToPath(new URL(dir, import.meta.url)))
  return hash.digest('hex').slice(0, 12)
}
const cacheSchema = hashSources(['./src/composables', './src/lib'])

/**
 * The installable app TECH_STACK §1 promised. What the service worker does,
 * and — as importantly — what it doesn't:
 *
 *   - Precaches the app itself (HTML, JS, CSS, fonts, icons) so it opens
 *     from the home screen with no signal. All of it, admin pages included
 *     (about 45 kB gzip, and only the chunks a deploy changed are fetched
 *     again): until the rep taps Refresh, the worker keeps serving the
 *     previous build's index.html, and that build's chunks are gone from
 *     Vercel after a deploy. A chunk left out of the precache 404s, and a
 *     page that needs it never opens, not even after a reload.
 *   - Serves index.html for any navigation, so a deep link (or the password
 *     reset link, /reset-password?token_hash=…) opens offline too; the query
 *     string and hash are untouched and the page handles them as before.
 *   - Never touches Supabase. There is no runtime route for it at all, so
 *     API and auth requests never pass through the worker and nothing from
 *     them is ever cached by it: data caching is TanStack Query's job
 *     (lib/queryPersist.ts), which knows whose data it is.
 *   - Updates by asking (registerType 'prompt'): a new deploy waits until the
 *     rep taps Refresh on the toast in AppShell, so code is never swapped
 *     under a half-filled visit survey.
 */
const pwa = VitePWA({
  registerType: 'prompt',
  // lib/pwa.ts registers it, from main.ts.
  injectRegister: false,
  // The manifest is fetched with cookies, so a password-protected Vercel
  // preview can still be installed (same origin; changes nothing in prod).
  useCredentials: true,
  includeAssets: ['favicon.svg', 'apple-touch-icon-180x180.png'],
  manifest: {
    name: 'Rep Portal',
    short_name: 'Rep Portal',
    description: 'Accounts, orders and sales intel for Christensen Arms field reps.',
    start_url: '/',
    scope: '/',
    display: 'standalone',
    // The ink header and the canvas behind every page (style.css tokens).
    theme_color: '#12130F',
    background_color: '#F4F2ED',
    icons: [
      { src: '/pwa-192x192.png', sizes: '192x192', type: 'image/png' },
      { src: '/pwa-512x512.png', sizes: '512x512', type: 'image/png' },
      {
        src: '/pwa-maskable-512x512.png',
        sizes: '512x512',
        type: 'image/png',
        purpose: 'maskable',
      },
    ],
  },
  workbox: {
    globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
    // Install-only icons; the page never asks for them.
    globIgnores: ['**/pwa-512x512.png', '**/pwa-maskable-512x512.png'],
    navigateFallback: '/index.html',
    // Static files are never answered with the app shell: a missing chunk
    // should fail as a missing chunk. Matched on the path only, so a query
    // string with a dot in it (a reset token, ?redirect=…) still opens the app.
    navigateFallbackDenylist: [
      /^[^?]*\.(?:js|mjs|css|map|json|webmanifest|png|jpe?g|svg|ico|woff2?|txt|xml)(?:\?.*)?$/i,
    ],
    cleanupOutdatedCaches: true,
    clientsClaim: false,
    skipWaiting: false,
  },
})

// https://vite.dev/config/
export default defineConfig({
  plugins: [vue(), tailwindcss(), pwa],
  define: {
    __CACHE_SCHEMA__: JSON.stringify(cacheSchema),
    // A Vercel PREVIEW build applies a new deploy as soon as it finds one
    // (lib/pwa.ts): someone testing a branch pushes a fix and reloads, and
    // the waiting-worker rule meant the reload served the old build until
    // they spotted the toast. Production keeps asking.
    __AUTO_UPDATE__: JSON.stringify(process.env.VERCEL_ENV === 'preview'),
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
})
