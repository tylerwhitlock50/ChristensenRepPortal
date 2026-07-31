/*============================================================================
  _shared/cors.ts

  The browser calls both functions from a Vercel-hosted SPA on a different
  origin, so every response — including errors and the preflight — needs CORS
  headers. Keeping them in one place means a new function can't ship with a
  half-configured header set.

  Origin is `*` on purpose: these functions carry no cookies and no ambient
  authority. Authorization is a bearer JWT the caller sends explicitly, so a
  hostile origin cannot make an authenticated request on a rep's behalf just
  by being allowed to talk to us. If that ever changes (cookie auth), pin
  ALLOWED_ORIGIN instead.
============================================================================*/

const ALLOWED_ORIGIN = Deno.env.get('CORS_ALLOWED_ORIGIN') ?? '*'

export const corsHeaders: Record<string, string> = {
  'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Max-Age': '86400',
  Vary: 'Origin',
}

/** Returns a preflight response for OPTIONS, or null for anything else. */
export function preflight(req: Request): Response | null {
  if (req.method !== 'OPTIONS') return null
  return new Response(null, { status: 204, headers: corsHeaders })
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

/**
 * Error shape every function returns, so the client can branch on `code`
 * rather than string-matching a message.
 */
export function fail(status: number, code: string, message: string): Response {
  return json({ error: { code, message } }, status)
}
