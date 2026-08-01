import type { Page } from '@playwright/test'

/**
 * Shared in-page probes for the mobile audit.
 *
 * The overflow probe deliberately does NOT use `document.scrollWidth >
 * clientWidth`. `src/style.css` sets `html { overflow-x: hidden }`, which
 * silences that signal at the document level while individual elements still
 * spill past the viewport and get clipped — the rep loses the right-hand end of
 * an account name or a number and never learns there was more. Measuring each
 * element's own box against the viewport is what actually finds those.
 */

export interface Overflow {
  tag: string
  cls: string
  text: string
  right: number
  width: number
}

/** Elements whose painted box extends past the right edge of the viewport. */
export async function findOverflow(page: Page, slack = 1): Promise<Overflow[]> {
  return page.evaluate((slackPx) => {
    const vw = document.documentElement.clientWidth
    const out: Overflow[] = []
    for (const el of Array.from(document.body.querySelectorAll<HTMLElement>('*'))) {
      const style = getComputedStyle(el)
      if (style.display === 'none' || style.visibility === 'hidden') continue
      // An element inside its own horizontal scroller is allowed to be wide —
      // DataGrid's table is exactly that, on purpose.
      let inScroller = false
      for (let p = el.parentElement; p; p = p.parentElement) {
        const ov = getComputedStyle(p).overflowX
        if (ov === 'auto' || ov === 'scroll') {
          inScroller = true
          break
        }
      }
      if (inScroller) continue

      const r = el.getBoundingClientRect()
      if (r.width === 0 || r.height === 0) continue
      if (r.right > vw + slackPx) {
        out.push({
          tag: el.tagName.toLowerCase(),
          cls: (el.className || '').toString().slice(0, 120),
          text: (el.textContent || '').trim().slice(0, 60),
          right: Math.round(r.right),
          width: Math.round(r.width),
        })
      }
    }
    return out
  }, slack)
}

export interface SmallTarget {
  tag: string
  label: string
  w: number
  h: number
}

/**
 * Interactive elements below the 44px floor. The design system claims 48px
 * ("gloves, trucks, cold hands" — style.css), so anything under 44 is both an
 * accessibility failure and a stated-intent failure.
 */
export async function findSmallTargets(page: Page, min = 44): Promise<SmallTarget[]> {
  return page.evaluate((minPx) => {
    const sel = 'a[href], button, input, select, textarea, [role="button"], [role="menuitem"]'
    const out: SmallTarget[] = []
    for (const el of Array.from(document.querySelectorAll<HTMLElement>(sel))) {
      const style = getComputedStyle(el)
      if (style.display === 'none' || style.visibility === 'hidden') continue
      if (el.hasAttribute('disabled')) continue
      const r = el.getBoundingClientRect()
      if (r.width === 0 || r.height === 0) continue
      // Inline links inside a sentence are not tap targets in the 44px sense.
      if (el.tagName === 'A' && style.display.startsWith('inline')) continue
      if (r.height < minPx || r.width < minPx) {
        out.push({
          tag: el.tagName.toLowerCase(),
          label: (
            el.getAttribute('aria-label') ||
            el.textContent ||
            el.getAttribute('placeholder') ||
            ''
          )
            .trim()
            .slice(0, 50),
          w: Math.round(r.width),
          h: Math.round(r.height),
        })
      }
    }
    return out
  }, min)
}

/** Content sitting under the fixed bottom nav — unreachable by tap. */
export async function findCoveredByBottomNav(page: Page): Promise<string[]> {
  return page.evaluate(() => {
    const nav = document.querySelector<HTMLElement>('nav.fixed')
    if (!nav) return []
    const navTop = nav.getBoundingClientRect().top
    const out: string[] = []
    const sel = 'a[href], button, input, select, textarea'
    for (const el of Array.from(document.querySelectorAll<HTMLElement>(sel))) {
      if (nav.contains(el)) continue
      const r = el.getBoundingClientRect()
      if (r.height === 0) continue
      // Only flag what is on screen right now and overlapped.
      if (r.top < window.innerHeight && r.bottom > navTop && r.top < navTop + 4) {
        out.push(
          `${el.tagName.toLowerCase()} "${(el.getAttribute('aria-label') || el.textContent || '').trim().slice(0, 40)}"`,
        )
      }
    }
    return out
  })
}

/** Collects console errors + uncaught exceptions for the life of the page. */
export function watchErrors(page: Page): string[] {
  const errors: string[] = []
  page.on('console', (msg) => {
    if (msg.type() === 'error') errors.push(`console: ${msg.text().slice(0, 200)}`)
  })
  page.on('pageerror', (err) => errors.push(`pageerror: ${String(err).slice(0, 200)}`))
  return errors
}

/** Sign in through the real login form and wait for the app shell. */
export async function signIn(
  page: Page,
  email: string,
  password: string,
): Promise<void> {
  await page.goto('/login')
  await page.getByLabel(/email/i).fill(email)
  await page.getByLabel(/password/i).fill(password)
  await page.getByRole('button', { name: /sign in/i }).click()
  await page.waitForURL((url) => !url.pathname.startsWith('/login'), {
    timeout: 30_000,
  })
}
