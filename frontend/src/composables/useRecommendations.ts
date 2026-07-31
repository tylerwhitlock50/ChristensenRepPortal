import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import type { Tables } from '@/types/database.types'
import type { ActionType, RecOutcome, RecPriority } from '@/types/domain'

export type Recommendation = Tables<'recommendations'>

const PRIORITY_RANK: Record<RecPriority, number> = { high: 0, normal: 1, low: 2 }

/** Highest priority first, then soonest due, then oldest. */
export function sortForRep(rows: Recommendation[]): Recommendation[] {
  return [...rows].sort((a, b) => {
    const p =
      PRIORITY_RANK[(a.priority as RecPriority) ?? 'normal'] -
      PRIORITY_RANK[(b.priority as RecPriority) ?? 'normal']
    if (p !== 0) return p
    if (a.due_date && b.due_date && a.due_date !== b.due_date)
      return a.due_date < b.due_date ? -1 : 1
    if (a.due_date && !b.due_date) return -1
    if (!a.due_date && b.due_date) return 1
    return a.created_at < b.created_at ? -1 : 1
  })
}

/**
 * The home screen list: everything still owed an outcome. RLS scopes this to
 * the rep's book, so no user filter is needed.
 */
export function useNeedsAttention() {
  return useQuery({
    queryKey: qk.me.needsAttention(),
    queryFn: async (): Promise<Recommendation[]> => {
      const { data, error } = await supabase
        .from('recommendations')
        .select('*')
        .in('status', ['open', 'acted'])
        .limit(500)
      if (error) throw error
      return sortForRep(data ?? [])
    },
    staleTime: 30_000,
  })
}

export function useAccountRecommendations(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.recommendations(key.value)),
    enabled: computed(() => !!key.value),
    queryFn: async (): Promise<Recommendation[]> => {
      const { data, error } = await supabase
        .from('recommendations')
        .select('*')
        .eq('customer_key', key.value)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data ?? []
    },
  })
}

function useInvalidateAfterWrite() {
  const qc = useQueryClient()
  return (customerKey: string) => {
    void qc.invalidateQueries({ queryKey: qk.me.needsAttention() })
    void qc.invalidateQueries({ queryKey: qk.account.root(customerKey) })
  }
}

/**
 * Log what the rep did. A trigger on `actions` advances any referenced
 * recommendation from `open` to `acted`, so the client never writes that
 * transition itself (005_app_execution.sql).
 */
export function useLogAction() {
  const invalidate = useInvalidateAfterWrite()
  return useMutation({
    mutationFn: async (input: {
      customerKey: string
      actionType: ActionType
      note?: string
      recommendationId?: number | null
      actionDate?: string
    }) => {
      const { data, error } = await supabase
        .from('actions')
        .insert({
          customer_key: input.customerKey,
          action_type: input.actionType,
          note: input.note?.trim() || null,
          recommendation_id: input.recommendationId ?? null,
          ...(input.actionDate ? { action_date: input.actionDate } : {}),
        })
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}

/**
 * Close or dismiss. The outcome is not optional — the DB CHECK constraint
 * rejects a terminal status without one (PRD acceptance criterion #3), so the
 * UI requires it too rather than letting the write fail.
 */
export function useResolveRecommendation() {
  const invalidate = useInvalidateAfterWrite()
  return useMutation({
    mutationFn: async (input: {
      id: number
      customerKey: string
      status: 'closed' | 'dismissed'
      outcome: RecOutcome
      outcomeNote?: string
    }) => {
      const { data, error } = await supabase
        .from('recommendations')
        .update({
          status: input.status,
          outcome: input.outcome,
          outcome_note: input.outcomeNote?.trim() || null,
        })
        .eq('id', input.id)
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}
