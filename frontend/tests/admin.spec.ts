import { test } from '@playwright/test'
import { findOverflow, findSmallTargets, signIn, watchErrors } from './audit'

/**
 * The four admin routes added by the missions/admin work. Desk-first by design,
 * but the PRD's admin "also stands in a warehouse holding a phone", so they get
 * the same phone audit as the rep screens.
 */
const EMAIL = process.env.E2E_ADMIN_EMAIL ?? process.env.E2E_EMAIL ?? ''
const PASSWORD = process.env.E2E_ADMIN_PASSWORD ?? process.env.E2E_PASSWORD ?? ''

test.skip(!EMAIL || !PASSWORD, 'set E2E_EMAIL / E2E_PASSWORD')

const ROUTES = [
  { path: '/admin', name: 'execution' },
  { path: '/admin/users', name: 'users' },
  { path: '/admin/missions', name: 'missions' },
  { path: '/admin/activity', name: 'activity' },
]

for (const route of ROUTES) {
  test(`admin ${route.name} on a phone`, async ({ page }, testInfo) => {
    const errors = watchErrors(page)
    await signIn(page, EMAIL, PASSWORD)
    await page.goto(route.path)
    await page.waitForLoadState('networkidle').catch(() => {})
    await page.waitForTimeout(2500)

    const overflow = await findOverflow(page)
    const small = await findSmallTargets(page)
    await page.screenshot({
      path: testInfo.outputPath(`admin-${route.name}.png`),
      fullPage: true,
    })

    console.log(
      `[${testInfo.project.name}] ${route.path} — overflow:${overflow.length} smallTargets:${small.length} errors:${errors.length}`,
    )
    if (overflow.length) console.log('OVERFLOW', JSON.stringify(overflow, null, 2))
    if (small.length) console.log('SMALL', JSON.stringify(small, null, 2))
    if (errors.length) console.log('ERRORS', errors.join('\n'))
  })
}
