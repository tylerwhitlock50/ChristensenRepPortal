import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import type { Tables } from '@/types/database.types'
import type { ActionType, RecOutcome, RecPriority } from '@/types/domain'

export type Recommendation = Tables<'recommendations'>

/**
 * A "mission" is an admin-created recommendation — directed work from sales
 * ops, as opposed to the nightly rule engine's suggestions. The UI names and
 * badges them differently; the lifecycle is identical.
 */
export function isMission(rec: Pick<Recommendation, 'source'>): boolean {
  return rec.source === 'admin'
}

/**
 * Postgres raises bare error codes (016_missions_admin.sql); reps get a
 * sentence. Anything unrecognized passes through untouched.
 */
export function friendlyRecError(e: unknown): string {
  const message = (e as Error)?.message ?? ''
  if (message.includes('mission_requires_visit')) {
    return 'This mission needs a completed visit survey before it can be closed. Log a visit first.'
  }
  return message || 'Could not save that.'
}

/** Where an unscored row sits: the midpoint of its priority band. */
const PRIORITY_SCORE: Record<RecPriority, number> = { high: 75, normal: 50, low: 25 }

/**
 * Admin missions carry no rule_key and so are never scored, and rows created
 * before migration 020 have no score either. Mapping those onto their
 * priority band keeps them interleaved sensibly instead of sinking to the
 * bottom of every list the moment scoring ships.
 */
function effectiveScore(r: Recommendation): number {
  return r.score ?? PRIORITY_SCORE[(r.priority as RecPriority) ?? 'normal']
}

function isOverdue(dueDate: string | null): boolean {
  return !!dueDate && dueDate < new Date().toISOString().slice(0, 10)
}

/**
 * The rep's queue order.
 *
 *   1. overdue first        — ember means late, and lateness outranks a score
 *   2. missions ahead of system recs at equal lateness — a human is waiting
 *   3. score, descending    — the balanced ranking from 019
 *   4. soonest due, then oldest — unchanged tiebreakers
 *
 * Rule 2 is load-bearing rather than a preference. Missions are unscored, so
 * a naive score-descending sort would sink every piece of directed sales-ops
 * work below the algorithm's suggestions — and TodayView then shows only the
 * first few, which would hide them outright. The PRD calls order-season
 * missions "directive, not optional".
 */
export function sortForRep(rows: Recommendation[]): Recommendation[] {
  return [...rows].sort((a, b) => {
    const late = Number(isOverdue(b.due_date)) - Number(isOverdue(a.due_date))
    if (late !== 0) return late

    const mission = Number(isMission(b)) - Number(isMission(a))
    if (mission !== 0) return mission

    const score = effectiveScore(b) - effectiveScore(a)
    if (score !== 0) return score

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
 *
 * `enabled` exists for AppShell's mission badge: an admin's unscoped select
 * is the whole company's list and must not be fired from the shell.
 */
export function useNeedsAttention(options?: { enabled?: MaybeRef<boolean> }) {
  return useQuery({
    enabled: computed(() => unref(options?.enabled) ?? true),
    queryKey: qk.me.needsAttention(),
    queryFn: async (): Promise<Recommendation[]> => {
      const { data, error } = await supabase
        .from('recommendations')
        .select('*')
        .in('status', ['open', 'acted'])
        // Ordered server-side so the cap below takes the TOP rows rather than
        // an arbitrary 200. The client re-sorts (missions and overdue work
        // outrank a score), but it can only re-sort what it was sent.
        .order('score', { ascending: false, nullsFirst: false })
        .limit(200)
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
