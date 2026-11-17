/*============================================================================
  _shared/mcpAuth.ts

  Turning an MCP credential into "the rep, with their own RLS".

  Two credentials are accepted, and they meet at step 3:

    OAuth (20261116120000)   an access token Supabase Auth issued to Claude
                             after the user signed in and approved it on the
                             portal's consent screen. One connector URL for
                             everyone, nothing secret in it. The way in from
                             now on.
    crp_ token               minted on /connect and pasted into a header or
                             the connector URL. Kept so existing connections
                             go on working.

  Three steps, in this order, and the order is the whole point:

    1. Pull the credential off the request (extractCredential).
    2. Resolve it to a user with service_role, calling ONE function that
       returns no account data: mcp_oauth_resolve for a verified OAuth token
       (_shared/oauthToken.ts checks signature, issuer and expiry first),
       mcp_token_resolve for a crp_ token.
    3. Mint a five-minute `authenticated` JWT for that user and build a normal
       supabase-js client with it.

  From step 3 onward the MCP server is indistinguishable from the SPA: same
  anon key, same PostgREST, same policies, same my_customer_keys(). There is
  no code path in this server that reads sales data with service_role, and
  adding one would move the security boundary out of Postgres and into
  TypeScript — the thing _shared/supabase.ts exists to prevent.

  Why the OAuth token is not simply forwarded to PostgREST
  --------------------------------------------------------
  It could be: it is a valid user JWT. But then two kinds of JWT would mean
  "an MCP session" to the database, and every guard that keeps Claude from
  submitting an order (they all read app_metadata.provider = 'mcp') would need
  a second spelling. Minting our own keeps one shape, and lets the database
  refuse the raw OAuth token everywhere else (20261116120000 section 5),
  which is the audience binding Supabase Auth cannot do itself yet.

  Why mint a JWT instead of storing one
  -------------------------------------
  A Supabase session token lives about an hour. An MCP client is configured
  once and then left alone for months, so "paste your portal JWT into Claude"
  breaks the same afternoon. Refresh tokens rotate on use, which a stateless
  function cannot do safely from several concurrent requests. Signing a fresh,
  short-lived token per request has neither problem and keeps zero live
  credentials at rest. (Under OAuth the client does the refreshing, against
  Supabase Auth, and this function still never holds a refresh token.)

  MCP_JWT_SECRET
  --------------
  The project's JWT secret (Dashboard → Settings → API → JWT Secret), the same
  HS256 key PostgREST already validates every browser token against. It is NOT
  auto-injected like SUPABASE_SERVICE_ROLE_KEY — set it explicitly, and see
  functions/mcp/README.md if this project has retired its legacy HS256 secret
  in favour of asymmetric signing keys.
============================================================================*/

import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { HttpError, serviceClient } from './supabase.ts'
import {
  classifyBearer,
  createJwksCache,
  type Jwk,
  type OAuthIdentity,
  OAuthTokenError,
  verifyOAuthAccessToken,
} from './oauthToken.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''

const PUBLIC_KEY =
  Deno.env.get('SUPABASE_ANON_KEY') ??
  Deno.env.get('SUPABASE_PUBLISHABLE_KEY') ??
  ''

const JWT_SECRET =
  Deno.env.get('MCP_JWT_SECRET') ?? Deno.env.get('SUPABASE_JWT_SECRET') ?? ''

/** Long enough for the slowest tool's fan-out, short enough to be worthless
 *  if it ever escapes into a log. */
const JWT_TTL_SECONDS = 300

/**
 * The project's Auth issuer: the `iss` of every token it signs, and the
 * authorization server the MCP endpoint advertises. On a hosted project
 * SUPABASE_URL is the public project URL, so the default is right. Set
 * MCP_AUTH_ISSUER where it is not: `supabase functions serve` (SUPABASE_URL is
 * a Docker-internal address there) or a custom domain (Auth keeps issuing as
 * the project domain).
 */
export const AUTH_ISSUER = (
  Deno.env.get('MCP_AUTH_ISSUER') ?? (SUPABASE_URL ? `${SUPABASE_URL.replace(/\/+$/, '')}/auth/v1` : '')
).replace(/\/+$/, '')

/** Public signing keys, straight from the project. No key needed to read them. */
const signingKeys = createJwksCache(async () => {
  const response = await fetch(`${SUPABASE_URL.replace(/\/+$/, '')}/auth/v1/.well-known/jwks.json`, {
    headers: PUBLIC_KEY ? { apikey: PUBLIC_KEY } : {},
  })
  if (!response.ok) throw new Error(`JWKS fetch failed with ${response.status}`)
  const body = (await response.json()) as { keys?: Jwk[] }
  return Array.isArray(body.keys) ? body.keys : []
})

/**
 * Scopes a token may carry. Anything else in the column is ignored. Since
 * 2026-11-11 no scope gates anything: order drafting is decided by
 * feature.mcp_orders + mcp_order_users alone (mcp_orders_gate(), migration
 * 20261111150000). Supabase Auth's OAuth server has no custom scopes yet, so
 * an OAuth connection carries none either; the column stays for the day it
 * does.
 */
export const KNOWN_SCOPES = ['orders:draft'] as const
export type McpScope = (typeof KNOWN_SCOPES)[number]

/** How the token reached us. Informational: both transports are equivalent. */
export type TokenVia = 'header' | 'url'

/** Present on a caller who signed in with OAuth instead of a crp_ token. */
export interface McpOAuthConnection {
  /** public.mcp_oauth_connections.id */
  connectionId: string
  /** auth.oauth_clients.id: which app. */
  clientId: string
  /** auth.sessions.id: the grant. The gate re-checks it is still there. */
  sessionId: string
}

export interface McpCaller {
  /** public.mcp_tokens.id, or null for a caller who signed in with OAuth. */
  tokenId: string | null
  /** Set instead of tokenId when the caller signed in with OAuth. */
  oauth?: McpOAuthConnection
  userId: string
  fullName: string
  /** Coarse role for wording ("admin sees every account"). */
  role: 'admin' | 'rep'
  /** profiles.role exactly as stored (admin, rep, order_entry, ...). */
  realRole: string
  salesRepKey: string | null
  repGroupVendorId: string | null
  /** When the credential stops working: the token row's expiry, or the
   *  OAuth access token's (the client refreshes that one by itself). */
  tokenExpiresAt: string
  /** Where the token arrived: Authorization / x-mcp-token, or the URL. */
  tokenVia: TokenVia
  /** Scopes stored on the token row. Informational; nothing gates on them. */
  tokenScopes: McpScope[]
}

export interface ExtractedToken {
  token: string
  via: TokenVia
}

/*----------------------------------------------------------------------------
  Token extraction

  Three accepted places, because MCP clients disagree about what they can
  send:

    Authorization: Bearer crp_…   Claude Code, Claude Desktop, anything with a
                                  headers block in its config. Preferred.
    x-mcp-token: crp_…            Proxies that reserve Authorization.
    ?token=crp_… / trailing path  claude.ai custom connectors set up before
                                  OAuth (20261116120000), when a connector
                                  could carry a credential only in its URL.
                                  New connectors use the bare URL and sign in.

  The URL forms are a deliberate trade: a secret in a URL can land in a
  server log or a referrer, which is why tokens expire, are per-user, and are
  revocable from /connect on their own. Since 2026-11-11 a URL token is
  treated exactly like a header token (claude.ai connectors can only send a
  URL): if its user is on mcp_order_users and feature.mcp_orders is on, the
  order-DRAFTING tools are listed for it too. So a leaked connector URL lets
  whoever holds it read that user's book and create drafts as them — never
  submit (only a person in the portal can). For an admin or inside sales
  (20261113090000) "that user's book" is every account, and the drafts may be
  hand-priced, with upload URLs and document links for any order: they
  should use the header transport wherever their client allows (mcp/README
  "On putting a secret in a URL"), or better, sign in with OAuth, which puts
  no credential in the connector at all. The remedy for a leaked URL is
  revoking the token on the Connect page.
----------------------------------------------------------------------------*/
export function extractToken(req: Request): ExtractedToken | null {
  const auth = req.headers.get('Authorization') ?? ''
  const bearer = auth.replace(/^Bearer\s+/i, '').trim()
  // A Supabase JWT (three dot-separated segments) is the gateway's anon key
  // riding along, not an MCP credential. Ignore it and keep looking.
  if (bearer && bearer.split('.').length !== 3) return { token: bearer, via: 'header' }

  const header = req.headers.get('x-mcp-token')?.trim()
  if (header) return { token: header, via: 'header' }

  const url = new URL(req.url)
  const query = url.searchParams.get('token') ?? url.searchParams.get('key')
  if (query?.trim()) return { token: query.trim(), via: 'url' }

  // …/functions/v1/mcp/crp_abc123 — only a segment that looks like one of
  // ours, so a stray path never gets treated as a credential.
  const segments = url.pathname.split('/').filter(Boolean)
  const last = segments[segments.length - 1] ?? ''
  if (last.startsWith('crp_')) return { token: last, via: 'url' }

  return null
}

/*----------------------------------------------------------------------------
  Which credential, if any

  A JWT in Authorization that names a user is an OAuth access token (or is
  refused as not being one); it wins over a crp_ token anywhere else on the
  same request. A JWT that names no user is the project's anon key riding
  along, as before: ignored, and extractToken keeps looking.

  A request with no credential at all is what starts OAuth: index.ts answers
  401 with a pointer to the metadata document, and the client takes it from
  there.
----------------------------------------------------------------------------*/
export type Credential =
  | { kind: 'oauth'; token: string }
  | ({ kind: 'token' } & ExtractedToken)

export function extractCredential(req: Request): Credential | null {
  const auth = req.headers.get('Authorization') ?? ''
  const bearer = auth.replace(/^Bearer\s+/i, '').trim()
  if (bearer && classifyBearer(bearer) === 'user_jwt') return { kind: 'oauth', token: bearer }

  const token = extractToken(req)
  return token ? { kind: 'token', ...token } : null
}

/** The token row's scopes, minus anything this server does not know. */
export function knownScopes(raw: unknown): McpScope[] {
  if (!Array.isArray(raw)) return []
  const known = new Set<string>(KNOWN_SCOPES)
  return [...new Set(raw.map(String).filter((s) => known.has(s)))] as McpScope[]
}

/*----------------------------------------------------------------------------
  Resolution. The single service_role call in this server.
----------------------------------------------------------------------------*/
export async function resolveCaller(token: string, via: TokenVia): Promise<McpCaller> {
  const { data, error } = await serviceClient().rpc('mcp_token_resolve', {
    p_token: token,
  })

  if (error) {
    throw new HttpError(
      500,
      'token_lookup_failed',
      `Could not verify the token: ${error.message}`,
    )
  }

  const row = Array.isArray(data) ? data[0] : data
  if (!row) {
    throw new HttpError(
      401,
      'invalid_token',
      'That token is unknown, revoked, or expired. Mint a new one from the ' +
        'portal under your account menu → Connect Claude.',
    )
  }

  // `scopes` arrived with the order-drafting migration; a database without
  // it resolves to no scopes. Informational only (see KNOWN_SCOPES).
  const tokenScopes = knownScopes(row.scopes)
  return {
    tokenId: String(row.token_id),
    userId: String(row.user_id),
    fullName: String(row.full_name ?? ''),
    role: row.user_role === 'admin' ? 'admin' : 'rep',
    realRole: String(row.user_role ?? ''),
    salesRepKey: row.sales_rep_key ?? null,
    repGroupVendorId: row.rep_group_vendor_id ?? null,
    tokenExpiresAt: String(row.expires_at),
    tokenVia: via,
    tokenScopes,
  }
}

/*----------------------------------------------------------------------------
  The OAuth path: verify, then resolve.

  Two different "no"s, kept apart because the client acts on them:

    the token is bad      signature, issuer, expiry, or not an OAuth token at
                          all. Decided here, from the token alone.
    the token was good    but the grant has been revoked since, or the
                          account deactivated. Decided by mcp_oauth_resolve,
                          the one service_role call on this path.

  Both are a 401 with error="invalid_token": the client tries a refresh, the
  refresh fails for a revoked grant, and the user is asked to sign in again.
----------------------------------------------------------------------------*/
export async function verifyOAuthToken(token: string): Promise<OAuthIdentity> {
  if (!AUTH_ISSUER) {
    throw new HttpError(500, 'missing_env', 'SUPABASE_URL is not set on this function.')
  }
  try {
    return await verifyOAuthAccessToken(token, {
      issuer: AUTH_ISSUER,
      getKeys: signingKeys,
      hmacSecret: JWT_SECRET || undefined,
    })
  } catch (error) {
    if (error instanceof OAuthTokenError) {
      throw new HttpError(401, 'invalid_token', error.message)
    }
    // The key set could not be fetched: our problem, not the caller's.
    throw new HttpError(
      503,
      'signing_keys_unavailable',
      `Could not load the project's signing keys: ${error instanceof Error ? error.message : String(error)}`,
    )
  }
}

export async function resolveOAuthCaller(identity: OAuthIdentity): Promise<McpCaller> {
  const { data, error } = await serviceClient().rpc('mcp_oauth_resolve', {
    p_user_id: identity.userId,
    p_client_id: identity.clientId,
    p_session_id: identity.sessionId,
  })

  if (error) {
    throw new HttpError(
      500,
      'token_lookup_failed',
      `Could not verify the connection: ${error.message}`,
    )
  }

  const row = Array.isArray(data) ? data[0] : data
  if (!row) {
    throw new HttpError(
      401,
      'invalid_token',
      'This connection is no longer authorized: it was disconnected in the ' +
        'portal, or the account was deactivated. Sign in again to reconnect.',
    )
  }

  return {
    tokenId: null,
    oauth: {
      connectionId: String(row.connection_id),
      clientId: identity.clientId,
      sessionId: identity.sessionId,
    },
    userId: String(row.user_id),
    fullName: String(row.full_name ?? ''),
    role: row.user_role === 'admin' ? 'admin' : 'rep',
    realRole: String(row.user_role ?? ''),
    salesRepKey: row.sales_rep_key ?? null,
    repGroupVendorId: row.rep_group_vendor_id ?? null,
    tokenExpiresAt: new Date(identity.expiresAt * 1000).toISOString(),
    tokenVia: 'header',
    tokenScopes: [],
  }
}

/*----------------------------------------------------------------------------
  HS256 signing, on Web Crypto.

  Deliberately dependency-free: a JWT is two base64url JSON blobs and an
  HMAC, and an npm import for that is a supply-chain surface on the one file
  in this repo that mints credentials.
----------------------------------------------------------------------------*/
let signingKey: CryptoKey | null = null

async function hmacKey(): Promise<CryptoKey> {
  if (signingKey) return signingKey
  if (!JWT_SECRET) {
    throw new HttpError(
      500,
      'missing_env',
      'MCP_JWT_SECRET is not set on this function. ' +
        'See supabase/functions/mcp/README.md.',
    )
  }
  signingKey = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(JWT_SECRET),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  return signingKey
}

function b64url(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function b64urlJson(value: unknown): string {
  return b64url(new TextEncoder().encode(JSON.stringify(value)))
}

/** app_metadata of the JWT this function mints. One of the two id shapes. */
export interface McpAppMetadata {
  provider: 'mcp'
  /** A crp_ token caller: public.mcp_tokens.id. */
  mcp_token_id?: string | null
  /** An OAuth caller: public.mcp_oauth_connections.id … */
  mcp_oauth_connection_id?: string
  /** … the auth.sessions row of the grant … */
  mcp_oauth_session_id?: string
  /** … and which app (informational). */
  mcp_oauth_client_id?: string
  mcp_scopes: McpScope[]
}

/** The JWT body for a caller. Exported for tests; carries no secret. */
export function jwtClaims(caller: McpCaller, now: number) {
  // provider marks the origin of the session: mcp_orders_gate() and
  // mcp_log_call() refuse a JWT without it, so a portal session cannot call
  // the drafting RPCs; the gate also checks the row named by the id claim is
  // live and the caller's. mcp_scopes is the token row's stored scopes,
  // informational since 20261111150000 (the gate no longer reads it). Only
  // this function can mint these claims, because only it holds the signing
  // secret.
  //
  // A caller who signed in with OAuth carries the connection and the Auth
  // session in place of a token id: the gate checks the connection is the
  // caller's and the session still exists (20261116120000). Never both
  // shapes at once, and never a top-level client_id claim: that is the mark
  // of the raw OAuth token, which the database refuses.
  const appMetadata: McpAppMetadata = caller.oauth
    ? {
        provider: 'mcp',
        mcp_oauth_connection_id: caller.oauth.connectionId,
        mcp_oauth_session_id: caller.oauth.sessionId,
        mcp_oauth_client_id: caller.oauth.clientId,
        mcp_scopes: [...caller.tokenScopes],
      }
    : {
        provider: 'mcp',
        mcp_token_id: caller.tokenId,
        mcp_scopes: [...caller.tokenScopes],
      }

  return {
    // `sub` is what auth.uid() reads and therefore what every policy in 010
    // resolves the book from. `role` is what PostgREST sets the database role
    // to — `authenticated`, never `service_role`.
    sub: caller.userId,
    role: 'authenticated',
    aud: 'authenticated',
    iss: `${SUPABASE_URL}/auth/v1`,
    iat: now,
    exp: now + JWT_TTL_SECONDS,
    app_metadata: appMetadata,
  }
}

async function mintUserJwt(caller: McpCaller): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const head = b64urlJson({ alg: 'HS256', typ: 'JWT' })
  const body = b64urlJson(jwtClaims(caller, now))
  const signed = `${head}.${body}`
  const mac = await crypto.subtle.sign(
    'HMAC',
    await hmacKey(),
    new TextEncoder().encode(signed),
  )
  return `${signed}.${b64url(new Uint8Array(mac))}`
}

/**
 * A client that acts AS THE REP. Identical in every respect to the SPA's
 * client except for how the JWT was obtained, so RLS decides everything.
 */
export async function callerClient(caller: McpCaller): Promise<SupabaseClient> {
  if (!SUPABASE_URL || !PUBLIC_KEY) {
    throw new HttpError(
      500,
      'missing_env',
      'SUPABASE_URL / SUPABASE_ANON_KEY are not set on this function.',
    )
  }
  const jwt = await mintUserJwt(caller)
  return createClient(SUPABASE_URL, PUBLIC_KEY, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
}
