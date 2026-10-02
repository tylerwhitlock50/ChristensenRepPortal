import { expect, test } from '@playwright/test'
import { signIn } from './audit'

const email = process.env.E2E_EMAIL ?? ''
const password = process.env.E2E_PASSWORD ?? ''

test.describe('shipment history discovery', () => {
  test.skip(!email || !password, 'set E2E_EMAIL and E2E_PASSWORD for a rep with an account')

  for (const width of [390, 1280]) {
    test(`find and reopen existing shipment history at ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 })
      await signIn(page, email, password)
      await page.goto('/')
      const discovery = page.getByRole('link', { name: 'Shipment history →', exact: true })
      await expect(discovery).toBeVisible()
      await expect(discovery).toHaveAttribute('href', '/accounts')
      await discovery.click()
      await expect(page).toHaveURL(/\/accounts$/)
      await expect(page.getByText('Looking for shipment history?', { exact: false })).toBeVisible()

      // Works for the default mobile cards and desktop table without an
      // account ID baked into the test or an additional shipment data source.
      const accountLink = page.locator('main a[href^="/accounts/"]').first()
      await expect(accountLink).toBeVisible()
      await accountLink.click()
      const shortcut = page.getByRole('button', { name: 'Shipment history ↓', exact: true })
      await expect(shortcut).toBeVisible()
      const shipments = page.getByRole('button', { name: /^Recent shipments/ })
      await expect(shipments).toHaveAttribute('aria-expanded', 'false')
      await shortcut.click()
      await expect(shipments).toHaveAttribute('aria-expanded', 'true')
      await expect(shipments).toBeInViewport()
      await expect(page.getByRole('button', { name: /^Recent orders/ })).toHaveAttribute('aria-expanded', 'false')
      await expect(page.getByRole('dialog')).toHaveCount(0)

      // The direct shortcut must also reopen a manually collapsed history.
      await shipments.click()
      await expect(shipments).toHaveAttribute('aria-expanded', 'false')
      await shortcut.click()
      await expect(shipments).toHaveAttribute('aria-expanded', 'true')
      await expect(shipments).toBeInViewport()
      await expect(page.locator('main')).toBeVisible()
      const shortcutBox = await shortcut.boundingBox()
      expect(shortcutBox?.height).toBeGreaterThanOrEqual(44)
    })
  }
})
