/*============================================================================
  _shared/mcpAuth.ts

  Turning an MCP bearer token into "the rep, with their own RLS".

  Three steps, in this order, and the order is the whole point:

    1. Pull the token off the request (header, query string, or path — see
       extractToken for why three).
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

export interface McpCaller {
  tokenId: string
  userId: string
  fullName: string
  role: 'admin' | 'rep'
  salesRepKey: string | null
  repGroupVendorId: string | null
  tokenExpiresAt: string
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
  server log or a referrer, which is why tokens expire, are per-user, are
  revocable from /connect on their own, and grant read-only access to data the
  holder could already see. Reps who can send a header should send a header.
----------------------------------------------------------------------------*/
export function extractToken(req: Request): string | null {
  const auth = req.headers.get('Authorization') ?? ''
  const bearer = auth.replace(/^Bearer\s+/i, '').trim()
  // A Supabase JWT (three dot-separated segments) is the gateway's anon key
  // riding along, not an MCP credential. Ignore it and keep looking.
  if (bearer && bearer.split('.').length !== 3) return bearer

  const header = req.headers.get('x-mcp-token')?.trim()
  if (header) return header

  const url = new URL(req.url)
  const query = url.searchParams.get('token') ?? url.searchParams.get('key')
  if (query?.trim()) return query.trim()

  // …/functions/v1/mcp/crp_abc123 — only a segment that looks like one of
  // ours, so a stray path never gets treated as a credential.
  const segments = url.pathname.split('/').filter(Boolean)
  const last = segments[segments.length - 1] ?? ''
  if (last.startsWith('crp_')) return last

  return null
}

/*----------------------------------------------------------------------------
  Resolution. The single service_role call in this server.
----------------------------------------------------------------------------*/
export async function resolveCaller(token: string): Promise<McpCaller> {
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

  return {
    tokenId: String(row.token_id),
    userId: String(row.user_id),
    fullName: String(row.full_name ?? ''),
    role: row.user_role === 'admin' ? 'admin' : 'rep',
    salesRepKey: row.sales_rep_key ?? null,
    repGroupVendorId: row.rep_group_vendor_id ?? null,
    tokenExpiresAt: String(row.expires_at),
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

async function mintUserJwt(userId: string): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const head = b64urlJson({ alg: 'HS256', typ: 'JWT' })
  const body = b64urlJson({
    // `sub` is what auth.uid() reads and therefore what every policy in 010
    // resolves the book from. `role` is what PostgREST sets the database role
    // to — `authenticated`, never `service_role`.
    sub: userId,
    role: 'authenticated',
    aud: 'authenticated',
    iss: `${SUPABASE_URL}/auth/v1`,
    iat: now,
    exp: now + JWT_TTL_SECONDS,
    // Marks the origin of the session in Postgres logs. Carries no authority.
    app_metadata: { provider: 'mcp' },
  })
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
  const jwt = await mintUserJwt(caller.userId)
  return createClient(SUPABASE_URL, PUBLIC_KEY, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
}
