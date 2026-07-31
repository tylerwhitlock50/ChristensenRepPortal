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
