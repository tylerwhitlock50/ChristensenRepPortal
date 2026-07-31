import { useQuery } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
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

export function useCoverage() {
  return useQuery({
    queryKey: qk.admin.coverage({ from: 'rolling', to: '30d' }),
    queryFn: async (): Promise<Coverage[]> => {
      const { data, error } = await supabase
        .from('account_coverage')
        .select('*')
        .order('last_contact_date', { ascending: true, nullsFirst: true })
        .limit(5000)
      if (error) throw error
      return data ?? []
    },
  })
}
