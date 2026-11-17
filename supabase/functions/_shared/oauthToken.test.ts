/*============================================================================
  oauthToken.test.ts: the OAuth door of the MCP endpoint, with real keys.

  Every token here is signed in the test with a freshly generated key, so the
  signature paths are the real ones (Web Crypto), not a stub. No network, no
  database: what mcp_oauth_resolve() decides is covered by
  supabase/tests/20261116_mcp_oauth.sql.

      deno test --allow-env supabase/functions/_shared/oauthToken.test.ts
============================================================================*/

import {
  bearerChallenge,
  classifyBearer,
  createJwksCache,
  decodeJwt,
  isOAuthClientToken,
  isResourceMetadataPath,
  type Jwk,
  mcpResourceUrl,
  OAuthTokenError,
  publicOrigin,
  resourceMetadata,
  resourceMetadataUrl,
  verifyOAuthAccessToken,
} from './oauthToken.ts'

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}

function eq(got: unknown, want: unknown, what: string): void {
  assert(
    JSON.stringify(got) === JSON.stringify(want),
    `${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
  )
}

const ISSUER = 'https://project.supabase.co/auth/v1'
const USER = '11111111-1111-4111-8111-111111111111'
const CLIENT = '22222222-2222-4222-8222-222222222222'
const SESSION = '33333333-3333-4333-8333-333333333333'
const NOW = 1_800_000_000
const SECRET = 'legacy-jwt-secret-at-least-32-characters-long'

function b64url(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function b64urlJson(value: unknown): string {
  return b64url(new TextEncoder().encode(JSON.stringify(value)))
}

/** The claims Supabase Auth puts in an access token issued to an OAuth client. */
function oauthClaims(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iss: ISSUER,
    sub: USER,
    aud: 'authenticated',
    role: 'authenticated',
    exp: NOW + 3600,
    iat: NOW,
    email: 'rep@example.test',
    app_metadata: { provider: 'email', providers: ['email'] },
    user_metadata: {},
    aal: 'aal1',
    session_id: SESSION,
    client_id: CLIENT,
    is_anonymous: false,
    ...over,
  }
}

interface Signer {
  jwk: Jwk
  sign: (claims: Record<string, unknown>, header?: Record<string, unknown>) => Promise<string>
}

async function asymmetricSigner(alg: 'ES256' | 'RS256', kid: string): Promise<Signer> {
  const generate = alg === 'ES256'
    ? { name: 'ECDSA', namedCurve: 'P-256' }
    : { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' }
  const signWith = alg === 'ES256' ? { name: 'ECDSA', hash: 'SHA-256' } : { name: 'RSASSA-PKCS1-v1_5' }
  const pair = (await crypto.subtle.generateKey(generate, true, ['sign', 'verify'])) as CryptoKeyPair
  const exported = await crypto.subtle.exportKey('jwk', pair.publicKey)
  // As the JWKS endpoint publishes it: with alg, use, key_ops and kid.
  const jwk = { ...exported, kid, alg, use: 'sig', key_ops: ['verify'], ext: true } as Jwk
  return {
    jwk,
    sign: async (claims, header = {}) => {
      const signingInput = `${b64urlJson({ alg, typ: 'JWT', kid, ...header })}.${b64urlJson(claims)}`
      const signature = await crypto.subtle.sign(signWith, pair.privateKey, new TextEncoder().encode(signingInput))
      return `${signingInput}.${b64url(new Uint8Array(signature))}`
    },
  }
}

async function hmacSign(secret: string, claims: Record<string, unknown>, header: Record<string, unknown> = {}) {
  const signingInput = `${b64urlJson({ alg: 'HS256', typ: 'JWT', ...header })}.${b64urlJson(claims)}`
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(signingInput))
  return `${signingInput}.${b64url(new Uint8Array(mac))}`
}

/** A key source that records how it was asked. */
function keySource(...sets: Jwk[][]) {
  const calls: boolean[] = []
  let index = 0
  return {
    calls,
    getKeys: (forceRefresh: boolean) => {
      calls.push(forceRefresh)
      if (forceRefresh && index < sets.length - 1) index++
      return Promise.resolve(sets[index])
    },
  }
}

async function rejects(run: () => Promise<unknown>, code: string, what: string): Promise<void> {
  try {
    await run()
  } catch (error) {
    assert(error instanceof OAuthTokenError, `${what}: threw ${String(error)}, not an OAuthTokenError`)
    eq((error as OAuthTokenError).code, code, what)
    return
  }
  throw new Error(`FAILED: ${what}: accepted, should have been refused as ${code}`)
}

Deno.test('ES256: a token Supabase Auth issued to an OAuth client verifies', async () => {
  const signer = await asymmetricSigner('ES256', 'key-1')
  const keys = keySource([signer.jwk])
  const identity = await verifyOAuthAccessToken(await signer.sign(oauthClaims()), {
    issuer: ISSUER,
    getKeys: keys.getKeys,
    now: NOW,
  })
  eq(identity, { userId: USER, clientId: CLIENT, sessionId: SESSION, expiresAt: NOW + 3600 }, 'identity')
  eq(keys.calls, [false], 'one cached key lookup, no refresh')
})

Deno.test('RS256 verifies too, and aud may be an array', async () => {
  const signer = await asymmetricSigner('RS256', 'rsa-1')
  const identity = await verifyOAuthAccessToken(
    await signer.sign(oauthClaims({ aud: ['authenticated'] })),
    { issuer: ISSUER, getKeys: keySource([signer.jwk]).getKeys, now: NOW },
  )
  eq(identity.userId, USER, 'user')
})

Deno.test('a portal session token is not an MCP credential', async () => {
  const signer = await asymmetricSigner('ES256', 'key-1')
  const options = { issuer: ISSUER, getKeys: keySource([signer.jwk]).getKeys, now: NOW }
  const portal = oauthClaims()
  delete portal.client_id
  // Genuine signature, genuine user: still refused, because nobody approved
  // an app to use it. This is the check that stands in for the audience.
  await rejects(async () => verifyOAuthAccessToken(await signer.sign(portal), options), 'not_oauth', 'no client_id')
  await rejects(
    async () => verifyOAuthAccessToken(await signer.sign(oauthClaims({ client_id: 'claude' })), options),
    'not_oauth',
    'client_id that is not a client id',
  )
  await rejects(
    async () => verifyOAuthAccessToken(await signer.sign(oauthClaims({ session_id: undefined })), options),
    'not_oauth',
    'no session_id',
  )
})

Deno.test('tokens that are signed correctly but are the wrong kind', async () => {
  const signer = await asymmetricSigner('ES256', 'key-1')
  const options = { issuer: ISSUER, getKeys: keySource([signer.jwk]).getKeys, now: NOW }
  const refused = async (over: Record<string, unknown>, code: string, what: string) =>
    rejects(async () => verifyOAuthAccessToken(await signer.sign(oauthClaims(over)), options), code, what)

  await refused({ exp: NOW - 31 }, 'expired', 'expired beyond the clock allowance')
  await refused({ exp: undefined }, 'expired', 'no expiry at all')
  await refused({ nbf: NOW + 600 }, 'expired', 'not valid yet')
  await refused({ iss: 'https://other.supabase.co/auth/v1' }, 'wrong_issuer', 'another project')
  await refused({ role: 'service_role' }, 'not_a_user_token', 'service role')
  await refused({ role: 'anon', sub: undefined }, 'not_a_user_token', 'the anon key')
  await refused({ aud: 'https://somewhere.else' }, 'not_a_user_token', 'another audience')
  await refused({ sub: 'not-a-uuid' }, 'not_a_user_token', 'sub is not a user id')
  await refused({ is_anonymous: true }, 'not_a_user_token', 'anonymous sign-in')

  // Inside the allowance: a clock a few seconds apart is not an outage.
  const justExpired = await signer.sign(oauthClaims({ exp: NOW - 10 }))
  eq((await verifyOAuthAccessToken(justExpired, options)).userId, USER, 'ten seconds past expiry is tolerated')
})

Deno.test('forgeries', async () => {
  const signer = await asymmetricSigner('ES256', 'key-1')
  const attacker = await asymmetricSigner('ES256', 'key-1') // same kid, different key
  const options = { issuer: ISSUER, getKeys: keySource([signer.jwk]).getKeys, now: NOW }

  await rejects(
    async () => verifyOAuthAccessToken(await attacker.sign(oauthClaims()), options),
    'bad_signature',
    'signed by another key with the same key id',
  )

  // The claims swapped under a genuine signature.
  const [head, , sig] = (await signer.sign(oauthClaims())).split('.')
  const swapped = `${head}.${b64urlJson(oauthClaims({ sub: '99999999-9999-4999-8999-999999999999' }))}.${sig}`
  await rejects(() => verifyOAuthAccessToken(swapped, options), 'bad_signature', 'payload changed after signing')

  // "alg: none" and friends.
  const unsigned = `${b64urlJson({ alg: 'none', typ: 'JWT' })}.${b64urlJson(oauthClaims())}.AA`
  await rejects(() => verifyOAuthAccessToken(unsigned, options), 'unsupported_alg', 'alg none')

  // The classic confusion: an HS256 token whose "secret" is the public key.
  // There is no HMAC secret configured here, and with one configured the
  // public key still would not be it.
  const confused = await hmacSign(JSON.stringify(signer.jwk), oauthClaims())
  await rejects(() => verifyOAuthAccessToken(confused, options), 'unsupported_alg', 'HS256 with no secret configured')
  await rejects(
    () => verifyOAuthAccessToken(confused, { ...options, hmacSecret: SECRET }),
    'bad_signature',
    'HS256 keyed with the public key',
  )

  await rejects(() => verifyOAuthAccessToken('crp_notajwt', options), 'malformed', 'not a JWT')
  await rejects(() => verifyOAuthAccessToken('a.b.c', options), 'malformed', 'three segments of nothing')
})

Deno.test('HS256: accepted only with the legacy secret', async () => {
  const getKeys = keySource([]).getKeys
  const good = await hmacSign(SECRET, oauthClaims())
  eq(
    (await verifyOAuthAccessToken(good, { issuer: ISSUER, getKeys, hmacSecret: SECRET, now: NOW })).clientId,
    CLIENT,
    'signed with the project secret',
  )
  await rejects(
    async () =>
      verifyOAuthAccessToken(await hmacSign('some-other-secret-of-the-same-length-ok', oauthClaims()), {
        issuer: ISSUER,
        getKeys,
        hmacSecret: SECRET,
        now: NOW,
      }),
    'bad_signature',
    'signed with a different secret',
  )
  // The JWT this function mints itself (provider mcp) is HS256 with the same
  // secret. It must not come back in as an OAuth token.
  const minted = await hmacSign(SECRET, {
    sub: USER,
    role: 'authenticated',
    aud: 'authenticated',
    iss: ISSUER,
    iat: NOW,
    exp: NOW + 300,
    app_metadata: { provider: 'mcp', mcp_oauth_connection_id: CLIENT, mcp_oauth_session_id: SESSION },
  })
  await rejects(
    () => verifyOAuthAccessToken(minted, { issuer: ISSUER, getKeys, hmacSecret: SECRET, now: NOW }),
    'not_oauth',
    'our own minted JWT is not an OAuth access token',
  )
})

Deno.test('key rotation: an unknown key id refreshes the key set once', async () => {
  const oldKey = await asymmetricSigner('ES256', 'old')
  const newKey = await asymmetricSigner('ES256', 'new')
  const rotated = keySource([oldKey.jwk], [oldKey.jwk, newKey.jwk])
  const identity = await verifyOAuthAccessToken(await newKey.sign(oauthClaims()), {
    issuer: ISSUER,
    getKeys: rotated.getKeys,
    now: NOW,
  })
  eq(identity.userId, USER, 'verified against the refreshed set')
  eq(rotated.calls, [false, true], 'cached lookup, then one forced refresh')

  const stranger = await asymmetricSigner('ES256', 'never-published')
  const source = keySource([oldKey.jwk])
  await rejects(
    async () =>
      verifyOAuthAccessToken(await stranger.sign(oauthClaims()), { issuer: ISSUER, getKeys: source.getKeys, now: NOW }),
    'no_key',
    'a key id the project does not publish',
  )
  eq(source.calls, [false, true], 'and it asked only twice')

  // A key of the other type is never tried, whatever its key id says.
  const rsa = await asymmetricSigner('RS256', 'old')
  await rejects(
    async () =>
      verifyOAuthAccessToken(await oldKey.sign(oauthClaims()), {
        issuer: ISSUER,
        getKeys: keySource([rsa.jwk]).getKeys,
        now: NOW,
      }),
    'no_key',
    'an EC token against an RSA key set',
  )
})

Deno.test('the key cache: ten minutes, and refreshes are rate limited', async () => {
  let fetches = 0
  let clock = 0
  const cached = createJwksCache(
    () => {
      fetches++
      return Promise.resolve([{ kty: 'EC', kid: `fetch-${fetches}` }])
    },
    { ttlMs: 600_000, minRefreshMs: 30_000, now: () => clock },
  )
  eq((await cached(false))[0].kid, 'fetch-1', 'first use fetches')
  await cached(false)
  eq(fetches, 1, 'second use is served from memory')
  await cached(true)
  eq(fetches, 1, 'a forced refresh inside 30 s is not honoured')
  clock = 31_000
  eq((await cached(true))[0].kid, 'fetch-2', 'after 30 s it is')
  clock = 31_000 + 599_000
  await cached(false)
  eq(fetches, 2, 'still fresh just under ten minutes')
  clock = 31_000 + 600_000
  await cached(false)
  eq(fetches, 3, 'refetched at ten minutes')
})

Deno.test('what is in Authorization: Bearer', async () => {
  const signer = await asymmetricSigner('ES256', 'key-1')
  eq(classifyBearer('crp_0123456789abcdef'), 'opaque', 'a crp_ token')
  eq(classifyBearer('a.b.c'), 'api_key', 'three segments that decode to nothing')
  eq(
    classifyBearer(await hmacSign(SECRET, { role: 'anon', iss: 'supabase', ref: 'project' })),
    'api_key',
    'the anon key: a JWT with no user',
  )
  eq(classifyBearer(await signer.sign(oauthClaims())), 'user_jwt', 'an OAuth access token')

  const portal = oauthClaims()
  delete portal.client_id
  const portalToken = await signer.sign(portal)
  // A portal token is still a candidate (so it is refused loudly, not ignored),
  // but it is not an OAuth client token.
  eq(classifyBearer(portalToken), 'user_jwt', 'a portal session token')
  eq(isOAuthClientToken(portalToken), false, 'portal token: no client_id')
  eq(isOAuthClientToken(await signer.sign(oauthClaims())), true, 'OAuth token: client_id')
  eq(isOAuthClientToken('crp_0123456789abcdef'), false, 'a crp_ token')
  eq(isOAuthClientToken(await signer.sign(oauthClaims({ client_id: '' }))), false, 'empty client_id')
  eq(decodeJwt('only.two'), null, 'two segments')
  eq(decodeJwt(`${b64urlJson([1, 2])}.${b64urlJson({})}.AA`), null, 'a header that is not an object')
})

Deno.test('discovery: where the client is told to sign in', () => {
  // Hosted: the gateway forwards the public host; req.url is internal.
  const hosted = new Request('http://edge-runtime.internal/mcp', {
    headers: { 'x-forwarded-host': 'project.supabase.co', 'x-forwarded-proto': 'https', 'x-forwarded-port': '443' },
  })
  eq(publicOrigin(hosted), 'https://project.supabase.co', 'forwarded origin, standard port dropped')
  eq(mcpResourceUrl(hosted), 'https://project.supabase.co/functions/v1/mcp', 'the URL a person types into Claude')

  // The resource does not follow the sub-path a request arrived on: a token
  // in the path, or the metadata route itself.
  const subPath = new Request('http://edge-runtime.internal/mcp/oauth-protected-resource', {
    headers: { 'x-forwarded-host': 'project.supabase.co', 'x-forwarded-proto': 'https' },
  })
  eq(mcpResourceUrl(subPath), 'https://project.supabase.co/functions/v1/mcp', 'canonical whatever the sub-path')

  // Local stack: a non-standard port is kept.
  const local = new Request('http://kong:8000/mcp', {
    headers: { 'x-forwarded-host': '127.0.0.1', 'x-forwarded-proto': 'http', 'x-forwarded-port': '54321' },
  })
  eq(mcpResourceUrl(local), 'http://127.0.0.1:54321/functions/v1/mcp', 'local stack')
  eq(
    mcpResourceUrl(hosted, { override: 'https://api.example.com/functions/v1/mcp/' }),
    'https://api.example.com/functions/v1/mcp',
    'MCP_PUBLIC_URL wins, trailing slash dropped',
  )

  const resource = mcpResourceUrl(hosted)
  eq(resourceMetadataUrl(resource), 'https://project.supabase.co/functions/v1/mcp/oauth-protected-resource', 'metadata URL')
  eq(
    resourceMetadata(resource, `${ISSUER}/`),
    {
      resource: 'https://project.supabase.co/functions/v1/mcp',
      authorization_servers: [ISSUER],
      bearer_methods_supported: ['header'],
      resource_name: 'Christensen Rep Portal',
    },
    'metadata document',
  )
  assert(!('scopes_supported' in resourceMetadata(resource, ISSUER)), 'no scopes advertised')

  eq(isResourceMetadataPath('/mcp/oauth-protected-resource'), true, 'the reference path')
  eq(isResourceMetadataPath('/mcp/.well-known/oauth-protected-resource'), true, 'under .well-known')
  eq(isResourceMetadataPath('/mcp/oauth-protected-resource/'), true, 'trailing slash')
  eq(isResourceMetadataPath('/mcp'), false, 'the endpoint itself')
  eq(isResourceMetadataPath('/mcp/crp_abc'), false, 'a token in the path')
})

Deno.test('the WWW-Authenticate challenge', () => {
  const url = 'https://project.supabase.co/functions/v1/mcp/oauth-protected-resource'
  eq(bearerChallenge(url), `Bearer resource_metadata="${url}"`, 'no token: just the pointer')
  eq(
    bearerChallenge(url, { code: 'invalid_token', description: 'The access token has expired.' }),
    `Bearer error="invalid_token", error_description="The access token has expired.", resource_metadata="${url}"`,
    'bad token: says so, so the client refreshes',
  )
  // Nothing a message or a URL contains can end the quoted string early.
  const hostile = bearerChallenge('https://x/"y\\z', { code: 'invalid_token', description: 'a "quoted"\r\nline' })
  eq(
    hostile,
    'Bearer error="invalid_token", error_description="a  quoted   line", resource_metadata="https://x/%22y%5Cz"',
    'quotes, backslashes and line breaks are neutralised',
  )
})
