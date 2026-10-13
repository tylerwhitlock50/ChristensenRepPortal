/**
 * Download the code for the pages a rep opens next before they ask for it.
 *
 * The account page's chunk only started downloading after the tap, and its
 * queries only after that chunk had arrived and mounted. Two ways to get it
 * here first, both just the code (no data — the page's own composables
 * still own their queries):
 *
 *   - warmLikelyPages(): once the first page has painted and the phone is
 *     idle, the Accounts list and the account page.
 *   - warmForLink(): on pointerdown/touchstart of a link to an account,
 *     100-200 ms before the click lands on a phone.
 *
 * import() is cached, so the router's own import later gets the same
 * promise; warming twice costs nothing.
 *
 * A warm-up that fails is nobody's business: it must not trigger main.ts's
 * reload-on-new-build (that is for a page the rep actually asked for, which
 * the router reports itself), so failures here are flagged as quiet.
 */
const pages = {
  account: () => import('@/pages/AccountView.vue'),
  accounts: () => import('@/pages/AccountsView.vue'),
} as const

let quiet = 0

/** True while a warm-up import is in flight (main.ts's preloadError check). */
export function isWarming(): boolean {
  return quiet > 0
}

/** The rep asked to save data, or the connection is the slowest kind: don't. */
function sparingConnection(): boolean {
  const c = (navigator as Navigator & {
    connection?: { saveData?: boolean; effectiveType?: string }
  }).connection
  return !!c && (c.saveData === true || /(^|-)2g$/.test(c.effectiveType ?? ''))
}

function warm(page: keyof typeof pages) {
  quiet++
  void pages[page]()
    .catch(() => {})
    .finally(() => quiet--)
}

export function warmLikelyPages(): void {
  if (sparingConnection()) return
  const whenIdle =
    window.requestIdleCallback ??
    ((cb: () => void) => window.setTimeout(cb, 1_500))
  whenIdle(
    () => {
      warm('accounts')
      warm('account')
    },
    { timeout: 5_000 },
  )
}

const ACCOUNT_PATH = /^\/accounts\/[^/]+\/?$/
const ACCOUNTS_PATH = /^\/accounts\/?$/

/** For a delegated pointerdown/touchstart: warm the page the link goes to. */
export function warmForLink(event: Event): void {
  const link = (event.target as Element | null)?.closest?.('a[href]')
  if (!link) return
  let path: string
  try {
    const url = new URL((link as HTMLAnchorElement).href, window.location.href)
    if (url.origin !== window.location.origin) return
    path = url.pathname
  } catch {
    return
  }
  if (ACCOUNT_PATH.test(path)) warm('account')
  else if (ACCOUNTS_PATH.test(path)) warm('accounts')
}
