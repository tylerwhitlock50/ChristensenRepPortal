import { expect, test } from '@playwright/test'
import {
  findCoveredByBottomNav,
  findOverflow,
  findSmallTargets,
  signIn,
  watchErrors,
} from './audit'

const EMAIL = process.env.E2E_EMAIL ?? ''
const PASSWORD = process.env.E2E_PASSWORD ?? ''
const ADMIN_EMAIL = process.env.E2E_ADMIN_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.E2E_ADMIN_PASSWORD ?? ''

/**
 * These report rather than fail-fast on the layout probes: the point of the run
 * is a list of everything wrong on a phone, not the first thing wrong. Hard
 * assertions are reserved for "the page did not work at all".
 */

test.describe('login screen', () => {
  test('renders and fits the viewport', async ({ page }, testInfo) => {
    const errors = watchErrors(page)
    await page.goto('/login')
    await expect(page.getByRole('button', { name: /sign in/i })).toBeVisible()

    const overflow = await findOverflow(page)
    const small = await findSmallTargets(page)
    await page.screenshot({
      path: testInfo.outputPath('login.png'),
      fullPage: true,
    })

    await testInfo.attach('findings', {
      body: JSON.stringify({ overflow, small, errors }, null, 2),
      contentType: 'application/json',
    })
    console.log(
      `[${testInfo.project.name}] /login — overflow:${overflow.length} smallTargets:${small.length} errors:${errors.length}`,
    )
    if (overflow.length) console.log(JSON.stringify(overflow, null, 2))
    if (small.length) console.log(JSON.stringify(small, null, 2))
    if (errors.length) console.log(errors.join('\n'))
  })
})

test.describe('signed in', () => {
  test.skip(!EMAIL || !PASSWORD, 'set E2E_EMAIL and E2E_PASSWORD')

  /**
   * The routes a rep actually reaches under the shipped feature flags.
   *
   * Was: `/` labelled "today" and `/tasks`. Both were wrong — `/` is the
   * Overview, and `/tasks` is gated on feature.tasks (disabled by default),
   * so that probe measured the Overview twice and called one of them Tasks.
   * The four Intel tabs and the account page carry the heaviest layouts in
   * the app (DataGrid, charts) and were never probed at all; the account
   * page has its own test below, so the grids are what this list adds.
   */
  const routes = [
    { path: '/', name: 'overview' },
    { path: '/accounts', name: 'accounts' },
    { path: '/intel/sku-sales', name: 'intel-sku-sales' },
    { path: '/intel/backlog', name: 'intel-backlog' },
    { path: '/intel/ats', name: 'intel-ats' },
    { path: '/intel/global', name: 'intel-global' },
  ]

  for (const route of routes) {
    test(`${route.name} on a phone`, async ({ page }, testInfo) => {
      const errors = watchErrors(page)
      await signIn(page, EMAIL, PASSWORD)
      await page.goto(route.path)
      // Let queries settle so the audit sees real content, not skeletons.
      await page.waitForLoadState('networkidle').catch(() => {})
      await page.waitForTimeout(1500)

      const overflow = await findOverflow(page)
      const small = await findSmallTargets(page)
      const covered = await findCoveredByBottomNav(page)
      await page.screenshot({
        path: testInfo.outputPath(`${route.name}.png`),
        fullPage: true,
      })

      await testInfo.attach('findings', {
        body: JSON.stringify({ overflow, small, covered, errors }, null, 2),
        contentType: 'application/json',
      })
      console.log(
        `[${testInfo.project.name}] ${route.path} — overflow:${overflow.length} smallTargets:${small.length} covered:${covered.length} errors:${errors.length}`,
      )
      if (overflow.length) console.log('OVERFLOW', JSON.stringify(overflow, null, 2))
      if (small.length) console.log('SMALL', JSON.stringify(small, null, 2))
      if (covered.length) console.log('COVERED', JSON.stringify(covered, null, 2))
      if (errors.length) console.log('ERRORS', errors.join('\n'))
    })
  }

  test('account detail + visit survey', async ({ page }, testInfo) => {
    const errors = watchErrors(page)
    await signIn(page, EMAIL, PASSWORD)
    await page.goto('/accounts')
    await page.waitForLoadState('networkidle').catch(() => {})
    await page.waitForTimeout(1500)

    const firstAccount = page.locator('a[href^="/accounts/"]').first()
    const count = await page.locator('a[href^="/accounts/"]').count()
    test.skip(count === 0, 'this rep has no accounts to open')

    await firstAccount.click()
    await page.waitForURL(/\/accounts\/.+/)
    await page.waitForLoadState('networkidle').catch(() => {})
    await page.waitForTimeout(2000)

    const accountOverflow = await findOverflow(page)
    const accountSmall = await findSmallTargets(page)
    await page.screenshot({
      path: testInfo.outputPath('account.png'),
      fullPage: true,
    })

    // The 60-second survey is acceptance criterion #5 — audit it open.
    const surveyButton = page
      .getByRole('button', { name: /log a visit|visit|survey/i })
      .first()
    let surveyOverflow: unknown[] = []
    let surveySmall: unknown[] = []
    if (await surveyButton.isVisible().catch(() => false)) {
      await surveyButton.click()
      await page.waitForTimeout(1000)
      surveyOverflow = await findOverflow(page)
      surveySmall = await findSmallTargets(page)
      await page.screenshot({
        path: testInfo.outputPath('visit-survey.png'),
        fullPage: true,
      })
    }

    await testInfo.attach('findings', {
      body: JSON.stringify(
        { accountOverflow, accountSmall, surveyOverflow, surveySmall, errors },
        null,
        2,
      ),
      contentType: 'application/json',
    })
    console.log(
      `[${testInfo.project.name}] /accounts/:key — overflow:${accountOverflow.length} smallTargets:${accountSmall.length} | survey overflow:${surveyOverflow.length} smallTargets:${surveySmall.length} errors:${errors.length}`,
    )
    if (accountOverflow.length)
      console.log('ACCOUNT OVERFLOW', JSON.stringify(accountOverflow, null, 2))
    if (surveyOverflow.length)
      console.log('SURVEY OVERFLOW', JSON.stringify(surveyOverflow, null, 2))
    if (accountSmall.length)
      console.log('ACCOUNT SMALL', JSON.stringify(accountSmall, null, 2))
    if (errors.length) console.log('ERRORS', errors.join('\n'))
  })

  test('account menu is reachable and sign out works', async ({ page }) => {
    await signIn(page, EMAIL, PASSWORD)
    const menu = page.getByRole('button', { name: /account menu/i })
    await expect(menu).toBeVisible()
    const box = await menu.boundingBox()
    expect(box?.height ?? 0, 'account menu button height').toBeGreaterThanOrEqual(44)
    await menu.click()
    await expect(page.getByRole('menuitem', { name: /sign out/i })).toBeVisible()
  })
})

test.describe('admin execution on a phone', () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'set E2E_ADMIN_EMAIL/E2E_ADMIN_PASSWORD')

  test('execution page', async ({ page }, testInfo) => {
    const errors = watchErrors(page)
    await signIn(page, ADMIN_EMAIL, ADMIN_PASSWORD)
    await page.goto('/admin')
    await page.waitForLoadState('networkidle').catch(() => {})
    await page.waitForTimeout(2500)

    const overflow = await findOverflow(page)
    const small = await findSmallTargets(page)
    await page.screenshot({
      path: testInfo.outputPath('admin.png'),
      fullPage: true,
    })

    await testInfo.attach('findings', {
      body: JSON.stringify({ overflow, small, errors }, null, 2),
      contentType: 'application/json',
    })
    console.log(
      `[${testInfo.project.name}] /admin — overflow:${overflow.length} smallTargets:${small.length} errors:${errors.length}`,
    )
    if (overflow.length) console.log('OVERFLOW', JSON.stringify(overflow, null, 2))
    if (small.length) console.log('SMALL', JSON.stringify(small, null, 2))
    if (errors.length) console.log('ERRORS', errors.join('\n'))
  })
})
