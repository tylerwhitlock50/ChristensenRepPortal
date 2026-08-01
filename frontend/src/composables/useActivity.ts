import { computed, unref, type MaybeRef } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import type { Tables } from '@/types/database.types'

export type RepActivity = Tables<'v_rep_activity'>

/**
 * The Activity tab (admin). v_rep_activity is security_invoker, so a rep
 * hitting it directly would only ever see their own row — the page gate is
 * cosmetic, the view is the boundary.
 */
export function useRepActivity() {
  return useQuery({
    queryKey: qk.admin.activity(),
    queryFn: async (): Promise<RepActivity[]> => {
      const { data, error } = await supabase
        .from('v_rep_activity')
        .select('*')
        .order('full_name')
      if (error) throw error
      return data ?? []
    },
  })
}

export interface VendorRollup {
  vendorId: string
  reps: RepActivity[]
  actions30d: number
  openMissions: number
  overdueMissions: number
  lastLoginAt: string | null
}

const NO_VENDOR = '(no rep group)'

/**
 * Rep-group rollup, grouped client-side — the field org is tens of rows, not
 * thousands, and the per-rep list is already on the page.
 */
export function rollupByVendor(rows: RepActivity[]): VendorRollup[] {
  const groups = new Map<string, RepActivity[]>()
  for (const row of rows) {
    const key = row.vendor_id ?? NO_VENDOR
    const list = groups.get(key)
    if (list) list.push(row)
    else groups.set(key, [row])
  }
  const rollups: VendorRollup[] = []
  for (const [vendorId, reps] of groups) {
    rollups.push({
      vendorId,
      reps,
      actions30d: reps.reduce((n, r) => n + (r.actions_30d ?? 0), 0),
      openMissions: reps.reduce((n, r) => n + (r.open_missions ?? 0), 0),
      overdueMissions: reps.reduce((n, r) => n + (r.overdue_missions ?? 0), 0),
      lastLoginAt: reps.reduce<string | null>(
        (latest, r) =>
          r.last_login_at && (!latest || r.last_login_at > latest)
            ? r.last_login_at
            : latest,
        null,
      ),
    })
  }
  // Most overdue first — that's who the admin is here to find.
  return rollups.sort(
    (a, b) =>
      b.overdueMissions - a.overdueMissions || b.actions30d - a.actions30d,
  )
}

export interface LoginEventRow {
  id: number
  user_id: string
  logged_at: string
}

/** Raw login stream for the recent-activity list. Admin RLS shows all rows. */
export function useRecentLogins(days: MaybeRef<number>) {
  const window = computed(() => unref(days))
  return useQuery({
    queryKey: computed(() => [...qk.admin.activity(), 'logins', window.value] as const),
    queryFn: async (): Promise<LoginEventRow[]> => {
      const since = new Date(Date.now() - window.value * 86_400_000).toISOString()
      const { data, error } = await supabase
        .from('login_events')
        .select('id, user_id, logged_at')
        .gte('logged_at', since)
        .order('logged_at', { ascending: false })
        .limit(500)
      if (error) throw error
      return data ?? []
    },
  })
}

export interface ActionRow {
  id: number
  user_id: string
  customer_key: string
  action_type: string
  action_date: string
  note: string | null
}

export function useRecentActions(days: MaybeRef<number>) {
  const window = computed(() => unref(days))
  return useQuery({
    queryKey: computed(() => [...qk.admin.activity(), 'actions', window.value] as const),
    queryFn: async (): Promise<ActionRow[]> => {
      const since = new Date(Date.now() - window.value * 86_400_000)
        .toISOString()
        .slice(0, 10)
      const { data, error } = await supabase
        .from('actions')
        .select('id, user_id, customer_key, action_type, action_date, note')
        .gte('action_date', since)
        .order('action_date', { ascending: false })
        .order('id', { ascending: false })
        .limit(500)
      if (error) throw error
      return data ?? []
    },
  })
}
