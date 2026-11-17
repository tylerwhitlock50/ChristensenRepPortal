/**
 * Unit tests for lib/oauthConsent.ts: what the OAuth consent screen
 * (/oauth/consent) is willing to approve, and what it tells the person.
 *
 * Run with:  npm run test:unit -- oauthConsent
 *
 * What matters: an app's name proves nothing, so the screen goes by where
 * the approval would be sent. Claude's callback and an app on the same
 * computer are offered; anything else is not, however it is dressed up, and
 * the page never navigates to an address other than the one it showed.
 */
import {
  classifyRedirect,
  describeScopes,
  isAuthorizationId,
  parseAllowedRedirects,
  sameRedirectTarget,
} from '../../src/lib/oauthConsent'
import { isOAuthServerDisabled, claudeCodeOAuthCommand } from '../../src/composables/useMcpOAuth'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(`FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`)
  }
}

const trust = (uri: string, allowed: string[] = []) => classifyRedirect(uri, allowed).trust

/* ---- Claude ------------------------------------------------------------- */
t('Claude’s callback', classifyRedirect('https://claude.ai/api/mcp/auth_callback'), {
  trust: 'claude',
  host: 'claude.ai',
})
t('…and its announced second home', trust('https://claude.com/api/mcp/auth_callback'), 'claude')
t('…with the code and state Auth appends', trust('https://claude.ai/api/mcp/auth_callback?code=abc&state=xyz'), 'claude')
t('…a trailing slash is the same address', trust('https://claude.ai/api/mcp/auth_callback/'), 'claude')

/* ---- Look-alikes: every one of these must be refused --------------------- */
t('another path on claude.ai is not the callback', trust('https://claude.ai/redirect?to=evil'), 'unknown')
t('http is not https', trust('http://claude.ai/api/mcp/auth_callback'), 'unknown')
t('a host that only starts with claude.ai', trust('https://claude.ai.evil.example/api/mcp/auth_callback'), 'unknown')
t('a host that only ends with it', trust('https://notclaude.ai/api/mcp/auth_callback'), 'unknown')
t('claude.ai as the user name of another host', trust('https://claude.ai@evil.example/api/mcp/auth_callback'), 'unknown')
t('a different port', trust('https://claude.ai:8443/api/mcp/auth_callback'), 'unknown')
t('an unrelated site', classifyRedirect('https://evil.example/callback'), { trust: 'unknown', host: 'evil.example' })
t('not a URL at all', classifyRedirect('claude'), { trust: 'unknown', host: '' })
t('a custom scheme', trust('myapp://callback'), 'unknown')
t('javascript:', trust('javascript:alert(1)'), 'unknown')
t('empty', trust(''), 'unknown')

/* ---- An app on this computer -------------------------------------------- */
t('Claude Code: localhost on its own port', classifyRedirect('http://localhost:3118/callback'), {
  trust: 'this_device',
  host: 'localhost:3118',
})
t('127.0.0.1', trust('http://127.0.0.1:6274/oauth/callback'), 'this_device')
t('IPv6 loopback', trust('http://[::1]:9000/cb'), 'this_device')
t('localhost as a subdomain of somewhere else is not loopback', trust('http://localhost.evil.example/callback'), 'unknown')
t('a LAN address is not this computer', trust('http://192.168.1.20:3000/callback'), 'unknown')

/* ---- The deploy-time list ------------------------------------------------ */
const listed = parseAllowedRedirects(
  'https://tools.example.com/oauth/callback, https://inspector.example.org\n http://plain.example.com/cb not-a-url',
)
t('list: https URLs kept, the rest dropped', listed, [
  'https://tools.example.com/oauth/callback',
  'https://inspector.example.org',
])
t('list: unset is empty', parseAllowedRedirects(undefined), [])
t('listed callback', trust('https://tools.example.com/oauth/callback', listed), 'listed')
t('…exactly that callback, not its neighbours', trust('https://tools.example.com/other', listed), 'unknown')
t('a listed origin allows any path on it', trust('https://inspector.example.org/a/b', listed), 'listed')
t('…but not over http', trust('http://inspector.example.org/a/b', listed), 'unknown')
t('the list never outranks Claude', trust('https://claude.ai/api/mcp/auth_callback', listed), 'claude')
t('nothing is listed by default', trust('https://tools.example.com/oauth/callback'), 'unknown')

/* ---- Only go where the person was shown ---------------------------------- */
t(
  'the reply URL is the shown address plus a code',
  sameRedirectTarget('https://claude.ai/api/mcp/auth_callback?code=1&state=2', 'https://claude.ai/api/mcp/auth_callback'),
  true,
)
t(
  'a denial goes to the same place',
  sameRedirectTarget('http://localhost:3118/callback?error=access_denied', 'http://localhost:3118/callback'),
  true,
)
t(
  'a different host is not the shown address',
  sameRedirectTarget('https://evil.example/api/mcp/auth_callback?code=1', 'https://claude.ai/api/mcp/auth_callback'),
  false,
)
t(
  'nor a different path',
  sameRedirectTarget('https://claude.ai/elsewhere?code=1', 'https://claude.ai/api/mcp/auth_callback'),
  false,
)
t(
  'nor a different port',
  sameRedirectTarget('http://localhost:9999/callback?code=1', 'http://localhost:3118/callback'),
  false,
)
t('nor something unreadable', sameRedirectTarget('', 'https://claude.ai/api/mcp/auth_callback'), false)

/* ---- Scopes, in words ----------------------------------------------------- */
t('the default scope', describeScopes('email'), ['Your email address, so it knows who connected.'])
t('what Claude asks for', describeScopes('email offline_access'), [
  'Your email address, so it knows who connected.',
  'It stays connected until you disconnect it; you are not asked to sign in again each hour.',
])
t('all the identity scopes read as one line', describeScopes('openid email profile phone'), [
  'Your email address, name and phone number, so it knows who connected.',
])
t('a scope we do not know is shown, not hidden', describeScopes('email orders:write'), [
  'Your email address, so it knows who connected.',
  '"orders:write"',
])
t('none requested', describeScopes(''), [])
t('null', describeScopes(null), [])

/* ---- The id on the consent URL -------------------------------------------- */
t('a uuid', isAuthorizationId('2f1c6c1e-7b0a-4a39-9d0e-0a5b6c7d8e9f'), true)
t('an opaque token', isAuthorizationId('aB3_x-9.Z~q'), true)
t('missing', isAuthorizationId(undefined), false)
t('repeated in the query (an array)', isAuthorizationId(['a', 'b']), false)
t('a path', isAuthorizationId('../admin/users'), false)
t('dots only', isAuthorizationId('..'), false)
t('empty', isAuthorizationId(''), false)

/* ---- The Connect page ------------------------------------------------------ */
t('OAuth server off: the code Auth sends', isOAuthServerDisabled({ code: 'feature_disabled', status: 404 }), true)
t('…or only its message', isOAuthServerDisabled({ message: 'OAuth server is disabled' }), true)
t('a network error is not "off"', isOAuthServerDisabled(new Error('Failed to fetch')), false)
t('nor a 404 about something else', isOAuthServerDisabled({ status: 404, message: 'Not found' }), false)
t('null', isOAuthServerDisabled(null), false)
t(
  'Claude Code: the address and nothing else, no token',
  claudeCodeOAuthCommand('https://x.supabase.co/functions/v1/mcp'),
  'claude mcp add --transport http rep-portal https://x.supabase.co/functions/v1/mcp',
)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
