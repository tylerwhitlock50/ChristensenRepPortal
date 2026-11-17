/**
 * The consent screen's judgement calls, as pure functions (tests:
 * tests/unit/oauthConsent.test.ts).
 *
 * Background: Supabase Auth is the OAuth server for the MCP endpoint
 * (migration 20261116120000). When an app asks to connect, Auth sends the
 * person here, to /oauth/consent, and waits for a yes or no. The app that
 * asked is named by whoever registered it, and with dynamic client
 * registration on, anyone can register an app called "Claude". A name is
 * therefore worth nothing. What cannot be faked is where the approval gets
 * sent: the redirect URI, which Auth matches exactly against the app's
 * registration. So that is what this page reads, and what it shows.
 */

/**
 * Where an approval would be delivered.
 *
 *   claude       Claude's own callback (claude.ai, the desktop and mobile
 *                apps, Cowork: they all come back through it).
 *   this_device  A loopback address: an app running on the same computer as
 *                this browser. Claude Code and the MCP Inspector.
 *   listed       Named in VITE_MCP_OAUTH_REDIRECTS by whoever deploys the
 *                portal.
 *   unknown      Anything else. Not offered for approval.
 */
export type RedirectTrust = 'claude' | 'this_device' | 'listed' | 'unknown'

export interface RedirectTarget {
  trust: RedirectTrust
  /** Host (with a non-default port) for display; '' when the URI is unreadable. */
  host: string
}

/**
 * Both hosts are Anthropic's. The second is listed because Anthropic has
 * said the callback may move there; an approval going to either reaches the
 * same place.
 */
const CLAUDE_CALLBACKS = [
  'https://claude.ai/api/mcp/auth_callback',
  'https://claude.com/api/mcp/auth_callback',
]

const LOOPBACK_HOSTS = new Set(['localhost', '127.0.0.1', '[::1]'])

function parse(value: string): URL | null {
  try {
    return new URL(value)
  } catch {
    return null
  }
}

/** Origin plus path, no query, no fragment, no trailing slash. */
function target(url: URL): string {
  return `${url.origin}${url.pathname.replace(/\/+$/, '')}`
}

/**
 * Entries of VITE_MCP_OAUTH_REDIRECTS: comma or whitespace separated. A full
 * URL allows exactly that callback; a bare origin (`https://tools.example.com`)
 * allows any path on it. Anything that is not an https URL is dropped: the
 * setting widens who can receive access, so a typo must not widen it further.
 */
export function parseAllowedRedirects(raw: string | undefined | null): string[] {
  return (raw ?? '')
    .split(/[\s,]+/)
    .map((entry) => entry.trim())
    .filter(Boolean)
    .flatMap((entry) => {
      const url = parse(entry)
      if (!url || url.protocol !== 'https:') return []
      return [url.pathname === '/' ? url.origin : target(url)]
    })
}

export function classifyRedirect(redirectUri: string, allowed: string[] = []): RedirectTarget {
  const url = parse(redirectUri)
  if (!url || (url.protocol !== 'https:' && url.protocol !== 'http:')) {
    return { trust: 'unknown', host: '' }
  }
  // Credentials in a URL are how "https://claude.ai@evil.example/…" is made
  // to look right. Nothing legitimate sends one.
  if (url.username || url.password) return { trust: 'unknown', host: url.host }

  const where = target(url)
  if (url.protocol === 'https:' && CLAUDE_CALLBACKS.includes(where)) {
    return { trust: 'claude', host: url.host }
  }
  if (LOOPBACK_HOSTS.has(url.hostname)) return { trust: 'this_device', host: url.host }
  if (url.protocol === 'https:' && (allowed.includes(where) || allowed.includes(url.origin))) {
    return { trust: 'listed', host: url.host }
  }
  return { trust: 'unknown', host: url.host }
}

/**
 * Auth answers an approval (or a refusal) with the full URL to send the
 * browser to: the redirect URI plus a code or an error. This checks it is the
 * address the person was shown, before the page navigates anywhere.
 */
export function sameRedirectTarget(redirectUrl: string, redirectUri: string): boolean {
  const to = parse(redirectUrl)
  const shown = parse(redirectUri)
  if (!to || !shown) return false
  return target(to) === target(shown) && !to.username && !to.password
}

/**
 * What the requested OAuth scopes share with the app, in words. These are
 * the only scopes Supabase Auth has, and they are about identity: none of
 * them widens or narrows what the connection can read. Unknown scopes are
 * shown as they came, so nothing is hidden.
 */
export function describeScopes(scope: string | null | undefined): string[] {
  const requested = new Set((scope ?? '').split(/\s+/).filter(Boolean))
  const lines: string[] = []
  const identity = ['openid', 'email', 'profile', 'phone'].filter((s) => requested.has(s))
  if (identity.length) {
    const parts = [
      requested.has('email') || requested.has('openid') ? 'email address' : '',
      requested.has('profile') ? 'name' : '',
      requested.has('phone') ? 'phone number' : '',
    ].filter(Boolean)
    lines.push(`Your ${parts.join(', ').replace(/, ([^,]*)$/, ' and $1')}, so it knows who connected.`)
    identity.forEach((s) => requested.delete(s))
  }
  if (requested.delete('offline_access')) {
    lines.push('It stays connected until you disconnect it; you are not asked to sign in again each hour.')
  }
  for (const other of requested) lines.push(`"${other}"`)
  return lines
}

/** The opaque id Supabase Auth puts on the consent URL. It goes into a request
 *  path, so anything that is not a plain token is refused before it is used. */
export function isAuthorizationId(value: unknown): value is string {
  return typeof value === 'string' && /^[A-Za-z0-9._~-]{1,256}$/.test(value) && /[A-Za-z0-9]/.test(value)
}
