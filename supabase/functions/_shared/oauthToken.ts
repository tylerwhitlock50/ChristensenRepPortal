/*============================================================================
  _shared/oauthToken.ts

  The OAuth half of the MCP door, as pure functions: no Deno APIs, no
  imports, nothing but Web Crypto. mcpAuth.ts supplies the environment
  (issuer, signing keys) and the database call; this file only answers two
  questions.

    1. Is this bearer token an access token Supabase Auth issued to an OAuth
       client, and for whom? (verifyOAuthAccessToken)
    2. What do we tell a client that has no token yet, so it can find the
       authorization server by itself? (the RFC 9728 helpers at the bottom)

  What the token is
  -----------------
  With the OAuth 2.1 server enabled, Supabase Auth issues an ordinary user
  JWT (role authenticated, sub = the user) with two claims that matter here:

    client_id   the OAuth client it was issued to. A portal session has none.
                Requiring it is what stops a JWT lifted from a browser tab
                from being used as an MCP credential.
    session_id  the auth.sessions row of the grant. Revoking the grant
                deletes that row; mcp_oauth_resolve() looks for it on every
                request, so a signature that is still good is not enough.

  Supabase Auth cannot bind a token to one resource yet (its aud is always
  "authenticated"), so the audience check the MCP spec asks for is done the
  other way round: the database refuses this token everywhere except through
  the mcp function (migration 20261116120000 section 5).

  Signature
  ---------
  ES256 or RS256 against the project's published keys (JWKS), or HS256
  against the legacy JWT secret for a project that still signs with it. The
  algorithm comes from the token header but each one is checked against its
  own kind of key: a public key is never used as an HMAC secret.
============================================================================*/

export type OAuthTokenErrorCode =
  | 'malformed'
  | 'unsupported_alg'
  | 'no_key'
  | 'bad_signature'
  | 'expired'
  | 'wrong_issuer'
  | 'not_a_user_token'
  | 'not_oauth'

export class OAuthTokenError extends Error {
  readonly code: OAuthTokenErrorCode

  constructor(code: OAuthTokenErrorCode, message: string) {
    super(message)
    this.name = 'OAuthTokenError'
    this.code = code
  }
}

/** A public key as the JWKS endpoint publishes it. */
export interface Jwk {
  kty: string
  kid?: string
  alg?: string
  crv?: string
  x?: string
  y?: string
  n?: string
  e?: string
  [key: string]: unknown
}

/** Who a verified OAuth access token speaks for. */
export interface OAuthIdentity {
  userId: string
  /** auth.oauth_clients.id of the app the user connected. */
  clientId: string
  /** auth.sessions.id of the grant; gone the moment it is revoked. */
  sessionId: string
  /** Seconds since the epoch. */
  expiresAt: number
}

export interface JwtParts {
  header: Record<string, unknown>
  payload: Record<string, unknown>
  /** The exact bytes that were signed: `<header>.<payload>` as sent. */
  signingInput: Uint8Array
  signature: Uint8Array
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const B64URL = /^[A-Za-z0-9_-]+$/

function b64urlBytes(value: string): Uint8Array | null {
  if (!B64URL.test(value)) return null
  try {
    const padded = value.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((value.length + 3) % 4)
    const binary = atob(padded)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    return bytes
  } catch {
    return null
  }
}

function b64urlJson(value: string): Record<string, unknown> | null {
  const bytes = b64urlBytes(value)
  if (!bytes) return null
  try {
    const parsed = JSON.parse(new TextDecoder().decode(bytes))
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)
      : null
  } catch {
    return null
  }
}

/** Splits a compact JWT. Null for anything that is not one. Verifies nothing. */
export function decodeJwt(token: string): JwtParts | null {
  const segments = token.split('.')
  if (segments.length !== 3) return null
  const [head, body, sig] = segments
  const header = b64urlJson(head)
  const payload = b64urlJson(body)
  const signature = b64urlBytes(sig)
  if (!header || !payload || !signature) return null
  return {
    header,
    payload,
    signingInput: new TextEncoder().encode(`${head}.${body}`),
    signature,
  }
}

/**
 * What kind of thing is sitting in `Authorization: Bearer`?
 *
 *   opaque    not a JWT: one of our crp_ tokens (or a typo of one).
 *   api_key   a JWT with no user in it. The project's anon or service key
 *             riding along from a gateway or an SDK. Not a credential of
 *             ours; the caller keeps looking for a crp_ token elsewhere.
 *   user_jwt  a JWT that names a user. The only candidate for an OAuth
 *             access token; verifyOAuthAccessToken decides.
 */
export function classifyBearer(bearer: string): 'opaque' | 'api_key' | 'user_jwt' {
  if (bearer.split('.').length !== 3) return 'opaque'
  const parts = decodeJwt(bearer)
  if (!parts) return 'api_key'
  const sub = parts.payload.sub
  return typeof sub === 'string' && sub.length > 0 ? 'user_jwt' : 'api_key'
}

/**
 * True when a bearer token is a JWT carrying a client_id claim: an access
 * token issued to an OAuth client. Decodes only. For the functions that are
 * NOT the MCP endpoint and must turn such a token away (see _shared/supabase.ts);
 * a forged claim can only get its bearer refused.
 */
export function isOAuthClientToken(bearer: string): boolean {
  const clientId = decodeJwt(bearer)?.payload.client_id
  return typeof clientId === 'string' && clientId.length > 0
}

/*----------------------------------------------------------------------------
  Signature
----------------------------------------------------------------------------*/
type Asymmetric = 'ES256' | 'RS256'

const IMPORT_PARAMS: Record<Asymmetric, EcKeyImportParams | RsaHashedImportParams> = {
  ES256: { name: 'ECDSA', namedCurve: 'P-256' },
  RS256: { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
}

const VERIFY_PARAMS: Record<Asymmetric, EcdsaParams | AlgorithmIdentifier> = {
  ES256: { name: 'ECDSA', hash: 'SHA-256' },
  RS256: { name: 'RSASSA-PKCS1-v1_5' },
}

const KEY_TYPE: Record<Asymmetric, string> = { ES256: 'EC', RS256: 'RSA' }

/** Web Crypto's BufferSource, spelled so that it type-checks both before and
 *  after TypeScript made typed arrays generic over their buffer. */
function bytes(value: Uint8Array): BufferSource {
  return value as BufferSource
}

/** Only the public-key fields: a JWKS entry's `alg`/`use`/`key_ops` can make
 *  importKey refuse a key that is perfectly good for verifying. */
function publicJwk(key: Jwk): JsonWebKey {
  return key.kty === 'EC'
    ? { kty: 'EC', crv: String(key.crv ?? ''), x: String(key.x ?? ''), y: String(key.y ?? '') }
    : { kty: 'RSA', n: String(key.n ?? ''), e: String(key.e ?? '') }
}

async function verifyWithKey(alg: Asymmetric, key: Jwk, parts: JwtParts): Promise<boolean> {
  try {
    const cryptoKey = await crypto.subtle.importKey('jwk', publicJwk(key), IMPORT_PARAMS[alg], false, ['verify'])
    return await crypto.subtle.verify(VERIFY_PARAMS[alg], cryptoKey, bytes(parts.signature), bytes(parts.signingInput))
  } catch {
    // A key we cannot import is a key that did not sign this.
    return false
  }
}

function candidates(alg: Asymmetric, kid: string | undefined, keys: Jwk[]): Jwk[] {
  const ofType = keys.filter((k) => k.kty === KEY_TYPE[alg] && (!k.alg || k.alg === alg))
  return kid ? ofType.filter((k) => k.kid === kid) : ofType
}

async function verifyHmac(secret: string, parts: JwtParts): Promise<boolean> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  )
  return crypto.subtle.verify('HMAC', key, bytes(parts.signature), bytes(parts.signingInput))
}

export interface VerifyOptions {
  /** The project's Auth issuer, `https://<ref>.supabase.co/auth/v1`. */
  issuer: string
  /** The project's public signing keys. Called with `true` to bypass any
   *  cache when a token names a key id we have not seen (a rotation). */
  getKeys: (forceRefresh: boolean) => Promise<Jwk[]>
  /** The legacy HS256 JWT secret, for a project that still signs with it. */
  hmacSecret?: string
  /** Seconds since the epoch. Injected by tests. */
  now?: number
  /** Tolerated clock difference between Auth and this function. */
  clockSkewSeconds?: number
}

/**
 * Verifies a Supabase Auth access token and requires it to be one issued to
 * an OAuth client. Throws OAuthTokenError; never returns a partial identity.
 *
 * It does NOT know whether the grant has been revoked since the token was
 * signed. mcp_oauth_resolve() answers that, with the session id from here.
 */
export async function verifyOAuthAccessToken(token: string, options: VerifyOptions): Promise<OAuthIdentity> {
  const parts = decodeJwt(token)
  if (!parts) throw new OAuthTokenError('malformed', 'The access token is not a JWT.')

  const alg = parts.header.alg
  const kid = typeof parts.header.kid === 'string' ? parts.header.kid : undefined

  if (alg === 'ES256' || alg === 'RS256') {
    let keys = candidates(alg, kid, await options.getKeys(false))
    // An unknown key id usually means the project rotated its signing key
    // after we cached the set. Look once more before saying no.
    if (keys.length === 0) keys = candidates(alg, kid, await options.getKeys(true))
    if (keys.length === 0) {
      throw new OAuthTokenError('no_key', 'The access token was signed with a key this project does not publish.')
    }
    let ok = false
    for (const key of keys) {
      if (await verifyWithKey(alg, key, parts)) {
        ok = true
        break
      }
    }
    if (!ok) throw new OAuthTokenError('bad_signature', 'The access token signature is not valid.')
  } else if (alg === 'HS256') {
    if (!options.hmacSecret) {
      throw new OAuthTokenError('unsupported_alg', 'This server does not accept HS256 access tokens.')
    }
    if (!(await verifyHmac(options.hmacSecret, parts))) {
      throw new OAuthTokenError('bad_signature', 'The access token signature is not valid.')
    }
  } else {
    throw new OAuthTokenError('unsupported_alg', `Unsupported access token algorithm "${String(alg)}".`)
  }

  // Signed by this project. Now: is it the right kind of token, and current?
  const claims = parts.payload
  const now = options.now ?? Math.floor(Date.now() / 1000)
  const skew = options.clockSkewSeconds ?? 30

  if (typeof claims.exp !== 'number' || claims.exp <= now - skew) {
    throw new OAuthTokenError('expired', 'The access token has expired.')
  }
  if (typeof claims.nbf === 'number' && claims.nbf > now + skew) {
    throw new OAuthTokenError('expired', 'The access token is not valid yet.')
  }
  if (claims.iss !== options.issuer) {
    throw new OAuthTokenError('wrong_issuer', 'The access token was not issued by this project.')
  }

  const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud]
  const userId = claims.sub
  if (
    claims.role !== 'authenticated' ||
    !audience.includes('authenticated') ||
    typeof userId !== 'string' ||
    !UUID.test(userId) ||
    claims.is_anonymous === true
  ) {
    throw new OAuthTokenError('not_a_user_token', 'The access token does not belong to a signed-in user.')
  }

  const clientId = claims.client_id
  const sessionId = claims.session_id
  if (typeof clientId !== 'string' || !UUID.test(clientId) || typeof sessionId !== 'string' || !UUID.test(sessionId)) {
    throw new OAuthTokenError(
      'not_oauth',
      'That is a portal sign-in, not a connection approved for an app. Connect through the MCP sign-in flow.',
    )
  }

  return { userId, clientId, sessionId, expiresAt: claims.exp }
}

/*----------------------------------------------------------------------------
  Signing keys, cached.

  The set changes only when the project rotates its key, so one fetch serves
  every request an instance handles for ten minutes. A forced refresh (an
  unknown key id) is honoured at most once every thirty seconds: a stream of
  tokens with made-up key ids must not become a stream of fetches.
----------------------------------------------------------------------------*/
export function createJwksCache(
  fetchKeys: () => Promise<Jwk[]>,
  options: { ttlMs?: number; minRefreshMs?: number; now?: () => number } = {},
): (forceRefresh: boolean) => Promise<Jwk[]> {
  const ttlMs = options.ttlMs ?? 10 * 60_000
  const minRefreshMs = options.minRefreshMs ?? 30_000
  const now = options.now ?? (() => Date.now())
  let keys: Jwk[] | null = null
  let fetchedAt = 0

  return async (forceRefresh: boolean) => {
    const age = now() - fetchedAt
    const stale = keys === null || age >= ttlMs
    if (stale || (forceRefresh && age >= minRefreshMs)) {
      keys = await fetchKeys()
      fetchedAt = now()
    }
    return keys ?? []
  }
}

/*----------------------------------------------------------------------------
  RFC 9728: telling a client where to sign in.

  An MCP client that gets a 401 reads `resource_metadata` from the
  WWW-Authenticate header, fetches that document, and finds the authorization
  server in it. Everything after that happens between the client and Supabase
  Auth; this function never sees a password, a code or a refresh token.

  The document cannot live at /.well-known/… on the host root, where the RFC
  would put it: a Supabase project only routes /functions/v1/<name>/… to us.
  The header names its real address instead, which the MCP spec says a client
  must use when it is given.
----------------------------------------------------------------------------*/

/** Any GET ending in this is the metadata document. Matches the path the
 *  Supabase reference middleware serves, and the same under /.well-known/. */
export const RESOURCE_METADATA_SUFFIX = '/oauth-protected-resource'

export function isResourceMetadataPath(pathname: string): boolean {
  return pathname.replace(/\/+$/, '').endsWith(RESOURCE_METADATA_SUFFIX)
}

function trimTrailingSlash(value: string): string {
  return value.replace(/\/+$/, '')
}

/**
 * The origin the client actually used. Inside an Edge Function `req.url` is
 * an internal address; the gateway forwards the public one in X-Forwarded-*.
 */
export function publicOrigin(req: Request): string {
  const url = new URL(req.url)
  const host = req.headers.get('x-forwarded-host') ?? url.host
  const proto = (req.headers.get('x-forwarded-proto') ?? url.protocol.replace(':', '')).toLowerCase()
  const port = host.includes(':') ? '' : (req.headers.get('x-forwarded-port') ?? '')
  const standard = (proto === 'https' && port === '443') || (proto === 'http' && port === '80')
  return `${proto}://${host}${port && !standard ? `:${port}` : ''}`
}

/**
 * The MCP endpoint's public URL: what a person types into Claude, and what
 * the metadata document must repeat character for character. `override`
 * (MCP_PUBLIC_URL) wins; otherwise it is the public origin plus the function's
 * own path, whatever sub-path this particular request arrived on.
 */
export function mcpResourceUrl(req: Request, options: { override?: string; slug?: string } = {}): string {
  if (options.override) return trimTrailingSlash(options.override)
  return `${publicOrigin(req)}/functions/v1/${options.slug || 'mcp'}`
}

export function resourceMetadataUrl(resource: string): string {
  return `${trimTrailingSlash(resource)}${RESOURCE_METADATA_SUFFIX}`
}

/**
 * The metadata document. No `scopes_supported` on purpose: a client then
 * asks for no particular scope, which is right, because scopes do not decide
 * anything here. What a connection may do is decided by who signed in.
 */
export function resourceMetadata(resource: string, issuer: string) {
  return {
    resource: trimTrailingSlash(resource),
    authorization_servers: [trimTrailingSlash(issuer)],
    bearer_methods_supported: ['header'],
    resource_name: 'Christensen Rep Portal',
  }
}

/** `"` and `\` would end the quoted string early; nothing else needs care. */
function quoted(value: string): string {
  return `"${value.replace(/[\\"]/g, (c) => (c === '"' ? '%22' : '%5C'))}"`
}

function quotedText(value: string): string {
  return `"${value.replace(/[\\"\r\n]/g, ' ')}"`
}

/**
 * The WWW-Authenticate value for a 401. With no `error` it means "sign in
 * first"; with one it means "that token is no good, get another", which is
 * what makes a client refresh instead of giving up.
 */
export function bearerChallenge(
  metadataUrl: string,
  error?: { code: 'invalid_token'; description: string },
): string {
  const params: string[] = []
  if (error) {
    params.push(`error=${quotedText(error.code)}`)
    params.push(`error_description=${quotedText(error.description)}`)
  }
  params.push(`resource_metadata=${quoted(metadataUrl)}`)
  return `Bearer ${params.join(', ')}`
}
