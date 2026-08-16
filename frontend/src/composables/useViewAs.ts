import { computed, type Ref } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'

/**
 * Admin "view as rep" — the client half of
 * supabase/migrations/20260816140000_admin_view_as_rep.sql.
 *
 * There is deliberately almost nothing here. Scope lives in Postgres
 * (`is_admin()` / `my_customer_keys()` resolve through `effective_user_id()`),
 * so switching reps does not filter anything client-side: it writes one row
 * via an RPC and throws the query cache away. Every page then re-fetches and
 * comes back with the rep's answers, because RLS gave the rep's answers.
 *
 * The live state itself lives in the session store next to the profile — it
 * is identity, not page data, and the router guard and the shell both read it
 * before any query runs.
 */

/** 20260816140000 lands after database.types.ts was last generated — same
 *  untyped-handle convention as useOverview.ts; delete after regenerating. */
const db = supabase as unknown as SupabaseClient

/** One row from public.acting_context(). */
export interface ActingContext {
  impersonating: boolean
  real_user_id: string
  real_full_name: string | null
  real_is_admin: boolean
  target_user_id: string | null
  target_full_name: string | null
  target_role: string | null
  target_sales_rep_key: string | null
  target_rep_group_vendor_id: string | null
  expires_at: string | null
}

/** One option in the picker, from public.impersonatable_profiles(). */
export interface ImpersonatableProfile {
  user_id: string
  full_name: string | null
  role: string
  sales_rep_key: string | null
  rep_group_vendor_id: string | null
}

export async function fetchActingContext(): Promise<ActingContext | null> {
  const { data, error } = await db.rpc('acting_context')
  if (error) {
    // The migration is not applied yet: the portal must still work, it just
    // has no view-as. Anything else is a real failure and should surface.
    if (isRpcMissing(error)) return null
    throw error
  }
  const row = (Array.isArray(data) ? data[0] : data) as ActingContext | undefined
  return row ?? null
}

export function isRpcMissing(error: unknown): boolean {
  const e = error as { code?: string; message?: string } | null
  if (!e) return false
  return (
    e.code === 'PGRST202' ||
    e.code === '42883' ||
    /could not find the function|function .* does not exist/i.test(e.message ?? '')
  )
}

/**
 * The picker's options. A definer RPC rather than a select on `profiles`
 * because the admin must be able to switch targets while ALREADY viewing as
 * someone — by then `is_admin()` is false and the profiles policy hides
 * everybody else.
 */
export function useImpersonatableProfiles(when?: Ref<boolean>) {
  const session = useSessionStore()
  return useQuery({
    queryKey: ['view-as', 'profiles'],
    // Long, because the answer is "the active users", which changes about as
    // often as somebody is hired. setViewAs() clears the whole cache
    // including this, so it re-fetches once on a switch and then sits.
    staleTime: 5 * 60_000,
    // `when` lets the always-mounted shell banner stay quiet until it is
    // actually showing something — without it, every admin page view would
    // fire this for a picker nobody has opened.
    enabled: computed(() => session.isRealAdmin && (when?.value ?? true)),
    queryFn: async (): Promise<ImpersonatableProfile[]> => {
      const { data, error } = await db.rpc('impersonatable_profiles')
      if (error) {
        if (isRpcMissing(error)) return []
        throw error
      }
      return (data ?? []) as ImpersonatableProfile[]
    },
  })
}

/** "Jane Doe · TANY MCDO" — how a target reads in the banner and the picker. */
export function repLabel(p: {
  full_name: string | null
  sales_rep_key: string | null
  rep_group_vendor_id?: string | null
  role?: string
}): string {
  const name = p.full_name?.trim() || 'Unnamed user'
  const code = p.sales_rep_key || p.rep_group_vendor_id
  return code ? `${name} · ${code}` : name
}
