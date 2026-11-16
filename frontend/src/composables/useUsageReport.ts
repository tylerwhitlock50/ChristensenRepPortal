import { computed, unref, type MaybeRef } from 'vue'
import { keepPreviousData, useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'

/**
 * Admin › Usage: admin_usage_report() (20261116120000), one round trip for
 * the whole page. The function returns null to a non-admin and the table's
 * only read policy is the admin's, so the page gate is cosmetic.
 */
export interface UsageTotals {
  views: number
  users: number
  phone_views: number
  device_views: number
  actions: number
  accounts: number
}
export interface UsageDay {
  day: string
  views: number
  users: number
}
export interface UsagePageRow {
  page: string
  views: number
  users: number
  phone_views: number
  last_at: string | null
}
export interface UsageUserRow {
  user_id: string
  full_name: string | null
  email: string | null
  role: string | null
  active: boolean | null
  rep_group: string | null
  sales_rep_key: string | null
  views: number
  active_days: number
  last_at: string | null
  phone_views: number
  accounts: number
  exports: number
  top_page: string | null
}
export interface UsageAccountRow {
  customer_key: string
  customer_id: string | null
  customer_name: string | null
  views: number
  users: number
  last_at: string | null
}
export interface UsageActionRow {
  event: string
  what: string
  page: string
  count: number
  users: number
  last_at: string | null
}
export interface UsageRecentRow {
  id: number
  at: string
  user_id: string
  full_name: string | null
  event: string
  page: string | null
  customer_key: string | null
  customer_name: string | null
  device: string | null
  detail: Record<string, unknown> | null
}
export interface UsageReport {
  days: number
  from: string
  through: string
  /** The first event ever logged: before it there is nothing to count. */
  first_event_at: string | null
  totals: UsageTotals
  by_day: UsageDay[]
  by_page: UsagePageRow[]
  by_user: UsageUserRow[]
  by_account: UsageAccountRow[]
  by_action: UsageActionRow[]
  recent: UsageRecentRow[]
}

const db = supabase as unknown as SupabaseClient

/** PostgREST's "no such function": the migration has not been applied yet. */
export function isUsageReportMissing(error: unknown): boolean {
  const code = (error as { code?: string } | null)?.code
  return code === 'PGRST202' || code === '42883'
}

export function useUsageReport(
  days: MaybeRef<number>,
  userId: MaybeRef<string>,
  includeAdmins: MaybeRef<boolean>,
) {
  const args = computed(() => ({
    p_days: unref(days),
    p_user_id: unref(userId) || null,
    p_include_admins: unref(includeAdmins),
  }))
  return useQuery({
    queryKey: computed(() => [...qk.admin.activity(), 'usage', args.value] as const),
    placeholderData: keepPreviousData,
    retry: (count, error) => !isUsageReportMissing(error) && count < 1,
    queryFn: async (): Promise<UsageReport | null> => {
      const { data, error } = await db.rpc('admin_usage_report', args.value)
      if (error) throw error
      return (data as UsageReport | null) ?? null
    },
  })
}
