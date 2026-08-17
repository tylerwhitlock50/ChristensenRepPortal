import { createClient } from '@supabase/supabase-js'
import type { Database } from '@/types/database.types'

const url = import.meta.env.VITE_SUPABASE_URL
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY

if (!url || !key) {
  throw new Error(
    'Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY. ' +
      'Copy .env.example to .env.local and fill both in.',
  )
}

/**
 * The only Supabase client in the app. Every read and write goes through this
 * with the signed-in user's JWT — there is no service_role anywhere in the
 * frontend, and no application server in front of it (TECH_STACK §3.1).
 */
export const supabase = createClient<Database>(url, key, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false,
  },
})

/**
 * Reads against the ETL-landed read models. Separate handle because `erp` is a
 * non-default schema and must be listed under Settings → API → Exposed schemas.
 */
export const erp = supabase.schema('erp' as never)

/** True when PostgREST rejected the request because `erp` isn't exposed. */
export function isSchemaNotExposed(error: unknown): boolean {
  const e = error as { code?: string; message?: string } | null
  if (!e) return false
  return (
    e.code === 'PGRST106' ||
    /schema must be one of|does not exist in the schema cache/i.test(
      e.message ?? '',
    )
  )
}

/**
 * The `authenticated` role carries an 8s statement_timeout, so a heavy read
 * over a cold rollup comes back as 57014 rather than slowly.
 */
function isStatementTimeout(error: unknown): boolean {
  const e = error as { code?: string; message?: string } | null
  if (!e) return false
  return (
    e.code === '57014' ||
    /canceling statement due to statement timeout/i.test(e.message ?? '')
  )
}

/** PostgREST rejected the JWT — expired, or refreshed out from under us. */
function isAuthExpired(error: unknown): boolean {
  const e = error as { code?: string; message?: string; status?: number } | null
  if (!e) return false
  return (
    e.code === 'PGRST301' ||
    e.status === 401 ||
    /jwt expired|invalid claim|token is expired/i.test(e.message ?? '')
  )
}

/** fetch() never reached Supabase. Safari and Chrome word this differently. */
function isNetworkFailure(error: unknown): boolean {
  const e = error as { message?: string } | null
  if (!e) return false
  return /failed to fetch|network ?request ?failed|networkerror|load failed/i.test(
    e.message ?? '',
  )
}

/**
 * What a rep reads when a query fails.
 *
 * Every read in the app lands in AsyncState, which used to print the raw
 * `error.message`. That is fine for `PGRST205` during a deploy and useless in
 * a parking lot: a statement timeout rendered as "canceling statement due to
 * statement timeout", and an expired session as a PostgREST code. Each branch
 * below says what happened and what to do about it; anything unrecognised
 * still falls through to the original message rather than being swallowed,
 * because a wrong-but-specific error beats a friendly dead end.
 */
export function describeError(error: unknown): string {
  const e = error as { message?: string } | null
  if (!e) return ''

  if (isSchemaNotExposed(e)) {
    return 'The ERP read models are not published to the API yet. An admin needs to add the `erp` schema under Settings → API → Exposed schemas in Supabase.'
  }
  if (isNetworkFailure(e)) {
    return "This phone couldn't reach the network. Anything you've saved is still here — try again when you have signal."
  }
  if (isStatementTimeout(e)) {
    return 'This took too long to come back. Try again — if it keeps timing out, tell your admin which screen it was.'
  }
  if (isAuthExpired(e)) {
    return 'Your sign-in expired. Sign out and back in from the menu up top to keep going.'
  }
  return e.message || 'Something went wrong.'
}
