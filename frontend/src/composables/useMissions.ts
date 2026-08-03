import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { erp, supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import type { Tables } from '@/types/database.types'
import type { MissionScope } from '@/types/domain'
import type { DimSalesRepRow } from '@/types/erp'

export type MissionBatchProgress = Tables<'mission_batch_progress'>
export type MissionDetail = Tables<'v_mission_detail'>

/**
 * Everything here is admin-only by construction: mission_batches carries only
 * an admin RLS policy, create_mission() raises not_admin, and the pages that
 * call these sit behind meta.adminOnly. No client-side scoping needed.
 */

export function useMissionBatches() {
  return useQuery({
    queryKey: qk.admin.missions(),
    queryFn: async (): Promise<MissionBatchProgress[]> => {
      const { data, error } = await supabase
        .from('mission_batch_progress')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(200)
      if (error) throw error
      return data ?? []
    },
  })
}

export function useMissionDetail(batchId: MaybeRef<number | null>) {
  const id = computed(() => unref(batchId))
  return useQuery({
    queryKey: computed(() => qk.admin.missionDetail(id.value ?? 0)),
    enabled: computed(() => id.value != null),
    queryFn: async (): Promise<MissionDetail[]> => {
      const { data, error } = await supabase
        .from('v_mission_detail')
        .select('*')
        .eq('batch_id', id.value!)
        .order('status')
        .order('customer_name')
        .limit(5000)
      if (error) throw error
      return data ?? []
    },
  })
}

/**
 * The rep/vendor pickers for the composer. Placeholders are filtered out —
 * a mission scoped to WEB has no human to do it, and create_mission()
 * rejects it server-side anyway.
 */
export function useSalesReps() {
  return useQuery({
    queryKey: qk.admin.salesReps(),
    staleTime: 10 * 60_000,
    queryFn: async (): Promise<DimSalesRepRow[]> => {
      const { data, error } = await (erp as unknown as SupabaseClient)
        .from('dim_sales_rep')
        .select('sales_rep_key, sales_rep_name, vendor_id, is_placeholder_rep')
        .order('sales_rep_name')
      if (error) throw error
      return ((data ?? []) as DimSalesRepRow[]).filter(
        (r) => !r.is_placeholder_rep,
      )
    },
  })
}

export interface MissionInput {
  title: string
  reason?: string
  priority: string
  dueDate?: string | null
  requiresVisit: boolean
  scopeType: MissionScope
  scopeValue?: string | null
  customerKeys?: string[] | null
  activeOnly?: boolean
}

/**
 * Optional args are omitted (undefined), not nulled. The generated RPC types
 * type an optional argument as `T | undefined`, and supabase-js drops
 * undefined keys from the body so PostgREST falls back to the SQL default.
 * Every one of these defaults to NULL in create_mission (016), so this is the
 * same call it always was — it just type-checks now.
 */
function rpcArgs(input: MissionInput, dryRun: boolean) {
  return {
    p_title: input.title.trim(),
    p_reason: input.reason?.trim() || undefined,
    p_priority: input.priority,
    p_due_date: input.dueDate || undefined,
    p_requires_visit: input.requiresVisit,
    p_scope_type: input.scopeType,
    p_scope_value: input.scopeValue || undefined,
    p_customer_keys: input.customerKeys?.length ? input.customerKeys : undefined,
    p_active_only: input.activeOnly ?? true,
    p_dry_run: dryRun,
  }
}

/** Postgres raises bare codes; the composer shows sentences. */
export function friendlyMissionError(e: unknown): string {
  const message = (e as Error)?.message ?? ''
  if (message.includes('missing_title')) return 'Give the mission a title first.'
  if (message.includes('placeholder_rep_key')) {
    return 'That rep code is a placeholder (WEB/HOUSE) — no one would receive the mission.'
  }
  if (message.includes('scope_resolved_empty') || message.includes('empty_custom_scope')) {
    return 'That scope matches no accounts. Widen it or check the filter.'
  }
  if (message.includes('unknown_customer_keys')) {
    return 'One of the picked accounts no longer exists in the ERP load.'
  }
  if (message.includes('missing_scope_value')) {
    return 'Pick which rep or rep group this mission is for.'
  }
  return message || 'Could not create the mission.'
}

/**
 * Both calls run the SAME server-side scope resolution — the preview count is
 * the created count, by construction (016_missions_admin.sql).
 */
export function useMissionPreview() {
  return useMutation({
    mutationFn: async (input: MissionInput): Promise<number> => {
      const { data, error } = await supabase.rpc('create_mission', rpcArgs(input, true))
      if (error) throw error
      return data?.[0]?.created_count ?? 0
    },
  })
}

export function useCreateMission() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (
      input: MissionInput,
    ): Promise<{ batchId: number | null; created: number }> => {
      const { data, error } = await supabase.rpc('create_mission', rpcArgs(input, false))
      if (error) throw error
      const row = data?.[0]
      return { batchId: row?.batch_id ?? null, created: row?.created_count ?? 0 }
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.admin.missions() })
      void qc.invalidateQueries({ queryKey: qk.admin.activity() })
    },
  })
}
