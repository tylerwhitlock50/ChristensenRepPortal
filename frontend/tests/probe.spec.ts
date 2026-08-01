import { test } from '@playwright/test'
import { signIn } from './audit'

/**
 * Follow-up probes for two findings the sweep surfaced but could not explain:
 * a 404 on the account routes, and content sitting under the fixed bottom nav.
 *
 * The bottom-nav check here is the honest version. Content scrolling *under* a
 * fixed bar mid-page is normal; the bug is only real if the LAST element on the
 * page still can't be cleared once you scroll all the way down.
 */

const EMAIL = process.env.E2E_EMAIL ?? ''
const PASSWORD = process.env.E2E_PASSWORD ?? ''

test.skip(!EMAIL || !PASSWORD, 'set E2E_EMAIL and E2E_PASSWORD')

test('what is 404ing', async ({ page }) => {
  const failed: string[] = []
  page.on('response', (r) => {
    if (r.status() >= 400) failed.push(`${r.status()} ${r.request().method()} ${r.url()}`)
  })
  page.on('requestfailed', (r) =>
    failed.push(`FAILED ${r.method()} ${r.url()} — ${r.failure()?.errorText}`),
  )

  await signIn(page, EMAIL, PASSWORD)
  await page.goto('/accounts')
  await page.waitForLoadState('networkidle').catch(() => {})
  await page.waitForTimeout(2000)

  const first = page.locator('a[href^="/accounts/"]').first()
  if (await first.isVisible().catch(() => false)) {
    await first.click()
    await page.waitForLoadState('networkidle').catch(() => {})
    await page.waitForTimeout(3000)
  }

  console.log('=== NON-OK RESPONSES ===')
  console.log(failed.length ? [...new Set(failed)].join('\n') : 'none')
})

test('can the last item clear the bottom nav', async ({ page }, testInfo) => {
  await signIn(page, EMAIL, PASSWORD)

  for (const path of ['/', '/tasks', '/accounts']) {
    await page.goto(path)
    await page.waitForLoadState('networkidle').catch(() => {})
    await page.waitForTimeout(2000)

    // Scroll fully to the bottom, then measure.
    await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight))
    await page.waitForTimeout(600)

    const result = await page.evaluate(() => {
      const nav = document.querySelector<HTMLElement>('nav.fixed')
      if (!nav) return { path: location.pathname, navFound: false, trapped: [] as string[] }
      const navTop = nav.getBoundingClientRect().top
      const trapped: string[] = []
      const sel = 'main a[href], main button, main input, main select, main textarea'
      for (const el of Array.from(document.querySelectorAll<HTMLElement>(sel))) {
        const r = el.getBoundingClientRect()
        if (r.height === 0) continue
        // On screen, and its centre is behind the nav -> genuinely untappable.
        const centre = r.top + r.height / 2
        if (r.bottom > 0 && r.top < window.innerHeight && centre > navTop) {
          trapped.push(
            `${el.tagName.toLowerCase()} "${(el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 45)}"`,
          )
        }
      }
      return { path: location.pathname, navFound: true, trapped }
    })

    console.log(`[${testInfo.project.name}] ${result.path} at page bottom — trapped:${result.trapped.length}`)
    if (result.trapped.length) console.log(result.trapped.join('\n'))

    await page.screenshot({
      path: testInfo.outputPath(`bottom${path.replace(/\//g, '_')}.png`),
    })
  }
})
