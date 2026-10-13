import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

/**
 * One id per deploy. The saved read cache is keyed to it (lib/queryPersist.ts)
 * so a phone never restores data shaped for an older build. Vercel provides
 * the commit; anywhere else a build stamp does the same job.
 */
const buildId = process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 12) || `local-${Date.now()}`

/**
 * The installable app TECH_STACK §1 promised. What the service worker does,
 * and — as importantly — what it doesn't:
 *
 *   - Precaches the app itself (HTML, JS, CSS, fonts, icons) so it opens
 *     from the home screen with no signal. Admin pages are left out; reps
 *     never open them and it is bytes over their LTE on every deploy.
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
    globIgnores: ['**/Admin*.js', '**/pwa-512x512.png', '**/pwa-maskable-512x512.png'],
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
    __BUILD_ID__: JSON.stringify(buildId),
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
})
