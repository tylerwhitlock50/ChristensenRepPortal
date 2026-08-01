import { defineConfig, devices } from '@playwright/test'

/**
 * Mobile UI audit harness.
 *
 * Points at a running instance rather than building one, because the app is a
 * thin Supabase client — there is no server to boot and no fixture data worth
 * faking. Set these before running:
 *
 *   E2E_BASE_URL   https://<your-app>.vercel.app   (or http://localhost:5173)
 *   E2E_EMAIL      a rep account to sign in as
 *   E2E_PASSWORD
 *   E2E_ADMIN_EMAIL / E2E_ADMIN_PASSWORD   optional — unlocks /admin
 *
 * Phone-only on purpose: the desk-bound Execution page is the one screen that
 * widens past 1024px, and everything else is built for a truck (§2.4).
 */
const baseURL = process.env.E2E_BASE_URL ?? 'http://localhost:5173'

export default defineConfig({
  testDir: './tests',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'off',
  },
  projects: [
    {
      // 390x844 — the smallest screen the PRD's "one hand, in a store" case has
      // to survive.
      name: 'iphone-13',
      use: { ...devices['iPhone 13'] },
    },
    {
      // 393x851 Android, plus a 3-tab bottom bar with a gesture inset.
      name: 'pixel-7',
      use: { ...devices['Pixel 7'] },
    },
  ],
})
