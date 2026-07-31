/*============================================================================
  _shared/supabase.ts

  Two client factories, deliberately named so the difference is impossible to
  miss at a call site.

    userClient(req)  — the caller's own JWT, forwarded. RLS applies. This is
                       the default and the one you almost always want.
    serviceClient()  — service_role. Bypasses RLS entirely. Only
                       admin-create-user uses it, and only AFTER it has
                       verified the caller is an admin with their own JWT.

  TECH_STACK §3.2 / constraint #2 is the whole reason this split exists: a
  server component that uses service_role to fetch data "on behalf of" a rep
  moves the security boundary out of Postgres and into TypeScript, where it
  will eventually leak. `ai-account-summary` therefore never imports
  serviceClient() — it reads exactly what the rep could have read themselves.
============================================================================*/

import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''

// Supabase injects SUPABASE_ANON_KEY into every function. Newer projects may
// only carry the renamed publishable key, so accept either.
const PUBLIC_KEY =
  Deno.env.get('SUPABASE_ANON_KEY') ??
  Deno.env.get('SUPABASE_PUBLISHABLE_KEY') ??
  ''

const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''

export class HttpError extends Error {
  readonly status: number
  readonly code: string

  constructor(status: number, code: string, message: string) {
    super(message)
    this.name = 'HttpError'
    this.status = status
    this.code = code
  }
}

/** Throws 500 at boot rather than failing halfway through a request. */
function requireEnv(value: string, name: string): string {
  if (!value) {
    throw new HttpError(
      500,
      'missing_env',
      `${name} is not set on this function. See supabase/functions/README.md.`,
    )
  }
  return value
}

export function bearerToken(req: Request): string {
  const header = req.headers.get('Authorization') ?? ''
  const token = header.replace(/^Bearer\s+/i, '').trim()
  if (!token) {
    throw new HttpError(401, 'no_auth', 'Missing Authorization header.')
  }
  return token
}

/**
 * A client that acts AS THE CALLER. Every read and write goes through the
 * same RLS policies the SPA hits, so this function can never see more than
 * the signed-in rep can.
 */
export function userClient(req: Request): SupabaseClient {
  const token = bearerToken(req)
  return createClient(
    requireEnv(SUPABASE_URL, 'SUPABASE_URL'),
    requireEnv(PUBLIC_KEY, 'SUPABASE_ANON_KEY'),
    {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    },
  )
}

/**
 * service_role. Bypasses RLS. Never call this before you have independently
 * established who the caller is and that they are allowed to be here.
 */
export function serviceClient(): SupabaseClient {
  return createClient(
    requireEnv(SUPABASE_URL, 'SUPABASE_URL'),
    requireEnv(SERVICE_ROLE_KEY, 'SUPABASE_SERVICE_ROLE_KEY'),
    { auth: { persistSession: false, autoRefreshToken: false } },
  )
}

export type CallerUser = { id: string; email: string | null }

/** Resolves the caller from their own JWT. 401 if the token is bad. */
export async function requireCaller(client: SupabaseClient): Promise<CallerUser> {
  const { data, error } = await client.auth.getUser()
  if (error || !data?.user) {
    throw new HttpError(401, 'invalid_token', 'Not signed in.')
  }
  return { id: data.user.id, email: data.user.email ?? null }
}

/** Parses a JSON body, with a clear 400 instead of a stack trace. */
export async function readJson<T>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T
  } catch {
    throw new HttpError(400, 'bad_json', 'Request body must be valid JSON.')
  }
}

export function requirePost(req: Request): void {
  if (req.method !== 'POST') {
    throw new HttpError(405, 'method_not_allowed', 'Use POST.')
  }
}
