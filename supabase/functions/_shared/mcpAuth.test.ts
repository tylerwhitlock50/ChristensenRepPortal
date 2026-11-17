/*============================================================================
  mcpAuth.test.ts: which credential a request carries, and what the JWT this
  function mints says about it. The token checks themselves are in
  oauthToken.test.ts; the crp_ extraction rules are in mcp/orderTools.test.ts.

      deno test --allow-env supabase/functions/_shared/mcpAuth.test.ts
============================================================================*/

import { extractCredential, jwtClaims, type McpCaller } from './mcpAuth.ts'

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}

function eq(got: unknown, want: unknown, what: string): void {
  assert(
    JSON.stringify(got) === JSON.stringify(want),
    `${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
  )
}

function b64url(value: unknown): string {
  return btoa(JSON.stringify(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/** Shaped like a JWT; nothing here verifies a signature. */
function jwt(claims: Record<string, unknown>): string {
  return `${b64url({ alg: 'ES256', typ: 'JWT' })}.${b64url(claims)}.c2lnbmF0dXJl`
}

const USER = '11111111-1111-4111-8111-111111111111'
const URL_ = 'https://x/functions/v1/mcp'

function request(headers: Record<string, string> = {}, url = URL_): Request {
  return new Request(url, { method: 'POST', headers })
}

function caller(over: Partial<McpCaller> = {}): McpCaller {
  return {
    tokenId: 'aaaaaaaa-0000-0000-0000-000000000001',
    userId: USER,
    fullName: 'A Rep',
    role: 'rep',
    realRole: 'rep',
    salesRepKey: 'A REP',
    repGroupVendorId: null,
    tokenExpiresAt: '2027-01-01T00:00:00Z',
    tokenVia: 'header',
    tokenScopes: [],
    ...over,
  }
}

Deno.test('extractCredential: nothing, a crp_ token, or an OAuth access token', () => {
  eq(extractCredential(request()), null, 'no credential: the request that starts OAuth')

  eq(
    extractCredential(request({ Authorization: 'Bearer crp_abc' })),
    { kind: 'token', token: 'crp_abc', via: 'header' },
    'a crp_ token in the header',
  )
  eq(
    extractCredential(request({}, `${URL_}?token=crp_abc`)),
    { kind: 'token', token: 'crp_abc', via: 'url' },
    'a crp_ token in the URL',
  )

  const access = jwt({ sub: USER, role: 'authenticated', client_id: '22222222-2222-4222-8222-222222222222' })
  eq(extractCredential(request({ Authorization: `Bearer ${access}` })), { kind: 'oauth', token: access }, 'an OAuth token')

  // A JWT that names a user is always treated as the credential, so a portal
  // session token is refused out loud by the verifier rather than skipped in
  // favour of whatever else is on the request.
  const portal = jwt({ sub: USER, role: 'authenticated' })
  eq(
    extractCredential(request({ Authorization: `Bearer ${portal}` }, `${URL_}?token=crp_abc`)),
    { kind: 'oauth', token: portal },
    'a user JWT wins over a URL token',
  )

  // The project's anon key is a JWT with no user: not a credential of ours.
  const anon = jwt({ role: 'anon', iss: 'supabase' })
  eq(extractCredential(request({ Authorization: `Bearer ${anon}` })), null, 'the anon key alone is no credential')
  eq(
    extractCredential(request({ Authorization: `Bearer ${anon}` }, `${URL_}?token=crp_abc`)),
    { kind: 'token', token: 'crp_abc', via: 'url' },
    'the anon key riding along does not hide a URL token',
  )
})

Deno.test('jwtClaims: an OAuth caller is an MCP session, named by its connection', () => {
  const oauth = jwtClaims(
    caller({
      tokenId: null,
      oauth: {
        connectionId: 'cccccccc-0000-4000-8000-000000000001',
        clientId: '22222222-2222-4222-8222-222222222222',
        sessionId: '33333333-3333-4333-8333-333333333333',
      },
    }),
    1000,
  )
  eq(
    oauth.app_metadata,
    {
      provider: 'mcp',
      mcp_oauth_connection_id: 'cccccccc-0000-4000-8000-000000000001',
      mcp_oauth_session_id: '33333333-3333-4333-8333-333333333333',
      mcp_oauth_client_id: '22222222-2222-4222-8222-222222222222',
      mcp_scopes: [],
    },
    'OAuth caller claims',
  )
  eq([oauth.sub, oauth.role, oauth.aud, oauth.exp - oauth.iat], [USER, 'authenticated', 'authenticated', 300], 'same envelope')
  assert(!('mcp_token_id' in oauth.app_metadata), 'no token id on an OAuth session')
  // client_id at the top level is the mark of the raw OAuth token, which the
  // database refuses (postgrest_pre_request). The minted JWT must never carry it.
  assert(!('client_id' in oauth), 'no top-level client_id')
  assert(!('session_id' in oauth), 'no top-level session_id')

  const token = jwtClaims(caller(), 1000)
  eq(
    token.app_metadata,
    { provider: 'mcp', mcp_token_id: 'aaaaaaaa-0000-0000-0000-000000000001', mcp_scopes: [] },
    'a crp_ token caller is unchanged',
  )
  assert(!('client_id' in token), 'no top-level client_id there either')
})
