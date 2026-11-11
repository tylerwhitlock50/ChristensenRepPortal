/*============================================================================
  _shared/mcpAuth.ts

  Turning an MCP bearer token into "the rep, with their own RLS".

  Three steps, in this order, and the order is the whole point:

    1. Pull the token off the request (header, query string, or path — see
       extractToken for why three), noting which (informational only: since
       2026-11-11 the transport no longer changes what a token can do).
    2. Resolve it to a user with service_role, calling ONE function that
       returns no account data (mcp_token_resolve, migration 20260816120000).
    3. Mint a five-minute `authenticated` JWT for that user and build a normal
       supabase-js client with it.

  From step 3 onward the MCP server is indistinguishable from the SPA: same
  anon key, same PostgREST, same policies, same my_customer_keys(). There is
  no code path in this server that reads sales data with service_role, and
  adding one would move the security boundary out of Postgres and into
  TypeScript — the thing _shared/supabase.ts exists to prevent.

  Why mint a JWT instead of storing one
  -------------------------------------
  A Supabase session token lives about an hour. An MCP client is configured
  once and then left alone for months, so "paste your portal JWT into Claude"
  breaks the same afternoon. Refresh tokens rotate on use, which a stateless
  function cannot do safely from several concurrent requests. Signing a fresh,
  short-lived token per request has neither problem and keeps zero live
  credentials at rest.

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
 * Scopes a token may carry. Anything else in the column is ignored. Since
 * 2026-11-11 no scope gates anything: order drafting is decided by
 * feature.mcp_orders + mcp_order_users alone (mcp_orders_gate(), migration
 * 20261111150000). The column stays for per-connection consent under OAuth.
 */
export const KNOWN_SCOPES = ['orders:draft'] as const
export type McpScope = (typeof KNOWN_SCOPES)[number]

/** How the token reached us. Informational: both transports are equivalent. */
export type TokenVia = 'header' | 'url'

export interface McpCaller {
  tokenId: string
  userId: string
  fullName: string
  /** Coarse role for wording ("admin sees every account"). */
  role: 'admin' | 'rep'
  /** profiles.role exactly as stored (admin, rep, order_entry, ...). */
  realRole: string
  salesRepKey: string | null
  repGroupVendorId: string | null
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
    ?token=crp_… / trailing path  claude.ai custom connectors, which accept a
                                  URL and nothing else.

  The URL forms are a deliberate trade: a secret in a URL can land in a
  server log or a referrer, which is why tokens expire, are per-user, and are
  revocable from /connect on their own. Since 2026-11-11 a URL token is
  treated exactly like a header token (claude.ai connectors can only send a
  URL): if its user is on mcp_order_users and feature.mcp_orders is on, the
  order-DRAFTING tools are listed for it too. So a leaked connector URL lets
  whoever holds it read that user's book and create drafts as them — never
  submit (only a person in the portal can). The remedy is revoking the token
  on the Connect page. Per-connection consent comes back with OAuth.
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

/** The JWT body for a caller. Exported for tests; carries no secret. */
export function jwtClaims(caller: McpCaller, now: number) {
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
    // provider marks the origin of the session: mcp_orders_gate() and
    // mcp_log_call() refuse a JWT without it, so a portal session cannot call
    // the drafting RPCs; the gate also checks the token row named by
    // mcp_token_id is live and the caller's. mcp_scopes is the token row's
    // stored scopes, informational since 20261111150000 (the gate no longer
    // reads it). Only this function can mint these claims, because only it
    // holds the signing secret.
    app_metadata: {
      provider: 'mcp',
      mcp_token_id: caller.tokenId,
      mcp_scopes: [...caller.tokenScopes],
    },
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
