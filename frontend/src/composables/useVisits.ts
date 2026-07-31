import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import type { Tables, TablesInsert } from '@/types/database.types'
import type { ActionType } from '@/types/domain'
import type { VisitFormValues } from '@/lib/visitSchema'

export type Visit = Tables<'visits'>

/**
 * `qk` (src/lib/queryClient.ts) is owned by the orchestrator, so the visits key
 * lives here instead. It is deliberately built under `qk.account.root(key)` —
 * `['account', key]` — so the existing root invalidation in
 * useRecommendations/useAccountData clears visits too.
 */
export const visitsQueryKey = (customerKey: string) =>
  [...qk.account.root(customerKey), 'visits'] as const

/** Past surveys for one account. RLS scopes this; no owner filter needed. */
export function useAccountVisits(
  customerKey: MaybeRef<string>,
  options?: { limit?: number },
) {
  const key = computed(() => unref(customerKey))
  const limit = options?.limit ?? 50
  return useQuery({
    queryKey: computed(() => visitsQueryKey(key.value)),
    enabled: computed(() => !!key.value),
    queryFn: async (): Promise<Visit[]> => {
      const { data, error } = await supabase
        .from('visits')
        .select('*')
        .eq('customer_key', key.value)
        .order('visit_date', { ascending: false })
        .order('created_at', { ascending: false })
        .limit(limit)
      if (error) throw error
      return data ?? []
    },
  })
}

export interface SubmitVisitInput {
  customerKey: string
  values: VisitFormValues
  /** Set when the survey was opened from a recommendation. */
  recommendationId?: number | null
  /**
   * Only for retries: the action row from a previous attempt whose visit
   * insert failed. Reps can't delete actions (admin-only policy), so a retry
   * reuses the orphan instead of logging the same contact twice.
   */
  actionId?: number | null
  /**
   * Defaults to 'visit' — the P0 coverage view counts `actions`, not `visits`.
   * Override to 'call'/'email' if you'd rather mirror a phone/email survey.
   */
  actionType?: ActionType
}

/** Carries the action id so a failed submit can be retried without duplicating it. */
export type VisitSubmitError = Error & {
  actionId: number | null
  code?: string
}

function submitError(
  message: string,
  actionId: number | null,
  code?: string,
): VisitSubmitError {
  const err = new Error(message) as VisitSubmitError
  err.actionId = actionId
  err.code = code
  return err
}

function toVisitInsert(
  input: SubmitVisitInput,
  actionId: number | null,
): TablesInsert<'visits'> {
  const v = input.values
  return {
    action_id: actionId,
    customer_key: input.customerKey,
    visit_type: v.visit_type,
    visit_date: v.visit_date,
    inventory_level: v.inventory_level,
    store_condition: v.store_condition,
    display_quality: v.display_quality,
    staff_knowledge: v.staff_knowledge,
    store_traffic: v.store_traffic,
    competitor_promos: v.competitor_promos,
    competition_seen: v.competition_seen,
    comments: v.comments?.trim() || null,
    // user_id defaults to auth.uid() in Postgres — never send it from here.
  }
}

/**
 * Save a survey.
 *
 * Writes TWO rows, action first:
 *   1. `public.actions` (action_type 'visit') — this is what
 *      `account_coverage` and `rep_execution_summary` count. A visit that
 *      doesn't write an action is invisible to the P0 coverage report, and
 *      inserting it first is also what fires `trg_action_marks_acted` to move
 *      a linked recommendation from 'open' to 'acted'.
 *   2. `public.visits` with `action_id` pointing at it.
 *
 * If step 2 fails the action still stands — the contact really did happen, so
 * coverage should keep it — and the thrown error carries `actionId` so the
 * retry reuses it.
 */
export function useSubmitVisit() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: SubmitVisitInput): Promise<Visit> => {
      let actionId = input.actionId ?? null

      if (actionId == null) {
        const { data: action, error: actionError } = await supabase
          .from('actions')
          .insert({
            customer_key: input.customerKey,
            action_type: input.actionType ?? 'visit',
            action_date: input.values.visit_date,
            note: input.values.comments?.trim() || null,
            recommendation_id: input.recommendationId ?? null,
          })
          .select('id')
          .single()
        if (actionError || !action)
          throw submitError(
            actionError?.message ?? 'Could not log the visit.',
            null,
            actionError?.code,
          )
        actionId = action.id
      }

      const { data: visit, error: visitError } = await supabase
        .from('visits')
        .insert(toVisitInsert(input, actionId))
        .select('*')
        .single()
      if (visitError || !visit)
        throw submitError(
          visitError?.message ?? 'Could not save the survey.',
          actionId,
          visitError?.code,
        )

      return visit
    },
    onSuccess: (_visit, vars) => {
      // Everything hanging off the account: visits, activity, recommendations.
      void qc.invalidateQueries({ queryKey: qk.account.root(vars.customerKey) })
      // The home list — a linked recommendation just moved to 'acted'.
      void qc.invalidateQueries({ queryKey: qk.me.needsAttention() })
    },
  })
}
