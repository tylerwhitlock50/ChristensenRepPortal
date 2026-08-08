import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/fetchAll'
import { qk } from '@/lib/queryClient'
import { isViewMissing } from '@/composables/useOverview'
import type { Tables } from '@/types/database.types'

export type RepSummary = Tables<'rep_execution_summary'>
export type Coverage = Tables<'account_coverage'>

/**
 * Per-rep execution metrics (PRD §7). Both of these views are
 * security_invoker, so an admin sees every row and a rep would see only their
 * own — the same policy that protects the rest of the app protects these.
 */
export function useRepExecution() {
  return useQuery({
    queryKey: qk.admin.execution(),
    queryFn: async (): Promise<RepSummary[]> => {
      const { data, error } = await supabase
        .from('rep_execution_summary')
        .select('*')
        .order('full_name')
      if (error) throw error
      return data ?? []
    },
  })
}

/** 20260808 lands after database.types.ts was last generated — same
 *  untyped-handle convention as useOverview.ts; delete after regenerating. */
const db = supabase as unknown as SupabaseClient

/** PostgREST can hand numerics back as strings depending on the column type. */
function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

function numOrNull(value: unknown): number | null {
  if (value == null) return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

export interface RepGoalRow {
  user_id: string
  full_name: string | null
  active: boolean
  period_year: number
  assigned_accounts: number
  accounts_with_goal: number
  /** Per-account coalesce(CRM goal for this year, ERP yearly goal), summed. */
  goal_total: number
  crm_goal_total: number
  erp_goal_total: number
  /** Invoiced revenue YTD over the rep's active external accounts. */
  shipped_ytd: number
  /** Booked order value YTD (orders written, canceled excluded). */
  booked_ytd: number
  /** 0–100, one decimal, null when the rep has no goal data. */
  shipped_pct: number | null
  booked_pct: number | null
}

/** Every rep vs their aggregate current-year goal (public.v_rep_goal_dashboard). */
export function useRepGoals() {
  return useQuery({
    queryKey: qk.admin.goals(),
    retry: (failureCount, error) => !isViewMissing(error) && failureCount < 1,
    queryFn: async (): Promise<RepGoalRow[]> => {
      const { data, error } = await db
        .from('v_rep_goal_dashboard')
        .select('*')
        .order('full_name')
      if (error) {
        if (isViewMissing(error)) {
          throw Object.assign(
            new Error(
              'The rep goal view is not in the database yet. Apply ' +
                'supabase/migrations/20260808090000_rep_goal_dashboard.sql, then reload.',
            ),
            { code: 'PGRST205' },
          )
        }
        throw error
      }
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        user_id: String(r.user_id),
        full_name: (r.full_name as string | null) ?? null,
        active: r.active === true,
        period_year: num(r.period_year),
        assigned_accounts: num(r.assigned_accounts),
        accounts_with_goal: num(r.accounts_with_goal),
        goal_total: num(r.goal_total),
        crm_goal_total: num(r.crm_goal_total),
        erp_goal_total: num(r.erp_goal_total),
        shipped_ytd: num(r.shipped_ytd),
        booked_ytd: num(r.booked_ytd),
        shipped_pct: numOrNull(r.shipped_pct),
        booked_pct: numOrNull(r.booked_pct),
      }))
    },
  })
}

export function useCoverage() {
  return useQuery({
    queryKey: qk.admin.coverage({ from: 'rolling', to: '30d' }),
    queryFn: async (): Promise<Coverage[]> => {
      // .limit(5000) never delivered more than PostgREST's max-rows (1,000),
      // so an admin's coverage table silently dropped accounts. Page it;
      // (customer_key, user_id) is the view's grain, so the tiebreakers
      // make the date sort total.
      return fetchAllRows((from, to) =>
        supabase
          .from('account_coverage')
          .select('*', { count: 'exact' })
          .order('last_contact_date', { ascending: true, nullsFirst: true })
          .order('customer_key')
          .order('user_id')
          .range(from, to),
      )
    },
  })
}
