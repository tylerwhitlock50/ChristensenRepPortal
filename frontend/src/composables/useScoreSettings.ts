import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'

/**
 * The recommendation tuning surface (019 + 020).
 *
 * Two tables, on purpose:
 *   score_settings  how accounts are RANKED — the five factor weights, the
 *                   per-factor thresholds, and the priority bands.
 *   rule_settings   which rules FIRE and at what thresholds.
 *
 * They are separate because public.recommendations.rule_key is a foreign key
 * to rule_settings.rule_key: every row in that table is a legal rule stamp on
 * a recommendation, and a weight vector must not be stampable.
 *
 * Reads go straight through PostgREST (both tables are readable by any
 * signed-in user — the reason strings and bands are shown in the rep UI too).
 * Writes are gated by the admin-only RLS policies, so nothing here needs a
 * client-side role check; a rep's UPDATE simply affects zero rows.
 */

/** score_settings and the two preview RPCs postdate the generated types. */
const db = supabase as unknown as SupabaseClient

export const SCORE_FACTORS = ['cadence', 'recency', 'trend', 'value', 'mix'] as const
export type ScoreFactor = (typeof SCORE_FACTORS)[number]

export const FACTOR_LABELS: Record<ScoreFactor, string> = {
  cadence: 'Overdue vs their own rhythm',
  recency: 'Time since last contact',
  trend: 'Revenue vs last year',
  value: 'Size of the account',
  mix: 'Product mix narrowing',
}

/** What each factor actually measures, in the rep's language, for the UI. */
export const FACTOR_HELP: Record<ScoreFactor, string> = {
  cadence:
    'Compares days since the last order against the median gap between this ' +
    "account's own orders. An annual buyer at 200 days is early; a weekly " +
    'buyer at 30 days is late.',
  recency:
    'Days since anyone logged a call, visit or email. Accounts with no ' +
    'logged contact at all are left out of the average rather than treated ' +
    'as urgent.',
  trend: 'Trailing twelve months against the twelve before. Growth scores zero.',
  value: 'Where the account sits by revenue against the whole book.',
  mix: 'Product families bought last year that they have not bought this year.',
}

export type ScoreWeights = Record<ScoreFactor, number>

export interface ScoreSettings {
  weights: ScoreWeights
  params: Record<string, Record<string, unknown>>
  priority_high: number
  priority_low: number
  updated_at: string
}

export interface RuleSetting {
  rule_key: string
  description: string
  enabled: boolean
  params: Record<string, unknown>
}

export interface PreviewRow {
  customer_key: string
  customer_name: string | null
  score: number
  priority: string
  score_cadence: number | null
  score_recency: number | null
  score_trend: number | null
  score_value: number | null
  score_mix: number | null
  factors: Record<string, { why?: string; contribution?: number }> | null
}

export interface RuleCount {
  rule_key: string
  would_create: number
}

/** Only the three rules the settings screen owns; missions are not rules. */
export const TUNABLE_RULES = ['no_order_days', 'yoy_decline', 'cadence_overdue'] as const

export function useScoreSettings() {
  return useQuery({
    queryKey: qk.admin.scoreSettings(),
    queryFn: async (): Promise<ScoreSettings> => {
      const { data, error } = await db
        .from('score_settings')
        .select('weights, params, priority_high, priority_low, updated_at')
        .eq('id', true)
        .single()
      if (error) throw error
      return data as ScoreSettings
    },
  })
}

export function useRuleSettings() {
  return useQuery({
    queryKey: qk.admin.rules(),
    queryFn: async (): Promise<RuleSetting[]> => {
      const { data, error } = await db
        .from('rule_settings')
        .select('rule_key, description, enabled, params')
        .in('rule_key', TUNABLE_RULES as unknown as string[])
        .order('rule_key')
      if (error) throw error
      return (data ?? []) as RuleSetting[]
    },
  })
}

/**
 * Bare Postgres error codes become sentences, the way friendlyMissionError
 * does for the mission composer.
 */
export function friendlyScoreError(e: unknown): string {
  const message = (e as Error)?.message ?? ''
  if (message.includes('not_admin')) {
    return 'Only an admin can change the recommendation settings.'
  }
  if (message.includes('bands_out_of_order') || message.includes('score_bands_ordered')) {
    return 'The "high" band has to be above the "low" band.'
  }
  if (message.includes('score_settings_missing')) {
    return 'The scoring settings row is missing — reapply migration 019.'
  }
  return message || 'Could not save that.'
}

export interface PreviewInput {
  weights: ScoreWeights
  params: ScoreSettings['params']
  priorityHigh: number
  priorityLow: number
  /** Rule overrides, keyed by rule_key: {enabled, params}. */
  rules: Record<string, { enabled: boolean; params: Record<string, unknown> }>
}

/**
 * Both previews run against the CANDIDATE settings in the form and write
 * nothing — the same contract create_mission(p_dry_run) has, and for the same
 * reason: an admin should see the size of a change before committing to it.
 *
 * Cheap because it re-scores stored signals; it never touches a fact table.
 */
export function usePreviewScores() {
  return useMutation({
    mutationFn: async (
      input: PreviewInput,
    ): Promise<{ rows: PreviewRow[]; counts: RuleCount[] }> => {
      const [scores, counts] = await Promise.all([
        db.rpc('preview_account_scores', {
          p_weights: input.weights,
          p_params: input.params,
          p_high: input.priorityHigh,
          p_low: input.priorityLow,
          p_limit: 25,
        }),
        db.rpc('preview_recommendation_counts', {
          p_weights: input.weights,
          p_params: input.params,
          p_high: input.priorityHigh,
          p_low: input.priorityLow,
          p_rules: input.rules,
        }),
      ])
      if (scores.error) throw scores.error
      if (counts.error) throw counts.error
      return {
        rows: (scores.data ?? []) as PreviewRow[],
        counts: (counts.data ?? []) as RuleCount[],
      }
    },
  })
}

/**
 * Save, then re-score immediately so the reps' ranking reflects the change
 * now rather than tomorrow morning.
 *
 * apply_account_scores() updates every scored account synchronously under the
 * `authenticated` role, which carries a statement timeout. Ten numeric columns
 * over ~41k rows should land well inside it, but if it ever does time out the
 * settings are already saved and tonight's job applies them anyway — hence
 * the soft failure rather than a rollback.
 */
export function useSaveScoreSettings() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: PreviewInput): Promise<{ rescored: boolean }> => {
      const { error: settingsError } = await db
        .from('score_settings')
        .update({
          weights: input.weights,
          params: input.params,
          priority_high: input.priorityHigh,
          priority_low: input.priorityLow,
          updated_at: new Date().toISOString(),
        })
        .eq('id', true)
      if (settingsError) throw settingsError

      for (const [ruleKey, rule] of Object.entries(input.rules)) {
        const { error } = await db
          .from('rule_settings')
          .update({ enabled: rule.enabled, params: rule.params })
          .eq('rule_key', ruleKey)
        if (error) throw error
      }

      // admin_rescore_accounts(), not apply_account_scores(): the latter takes
      // a whole settings row and is job-only, because a client-callable
      // version would let any rep re-score the book under weights of their
      // choosing. This one takes nothing and gates on is_admin().
      const { error: applyError } = await db.rpc('admin_rescore_accounts')
      return { rescored: !applyError }
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.admin.scoreSettings() })
      void qc.invalidateQueries({ queryKey: qk.admin.rules() })
      void qc.invalidateQueries({ queryKey: qk.me.needsAttention() })
    },
  })
}
