import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { isViewMissing } from '@/composables/useAccountMetrics'

/**
 * Rep-entered account goals — supabase/migrations/023_account_goals.sql.
 *
 * One goal per (account, year), owned by the ACCOUNT rather than by whoever
 * typed it, so a principal and their rep report against the same number.
 * Everything except the writes reads public.v_account_goal_progress, which
 * pairs the target with the revenue earned against it and with a seasonal
 * pace — all computed in Postgres. Nothing here sums a fact table, and no
 * caller filters by owner: RLS is the boundary (TECH_STACK §1).
 *
 * 023 lands after database.types.ts was last generated, so `account_goals`
 * and the v_* views are not in the typed `Database` yet. This is the SAME
 * client — same JWT, same session, same RLS — read through an untyped handle,
 * with the row shapes asserted below. Delete the cast once the types are
 * regenerated (023 post-migration checklist item 2).
 */
const db = supabase as unknown as SupabaseClient

/**
 * Resolved per call, never at module load: a truck iPad left open through
 * midnight on December 31 would otherwise keep reporting against last year's
 * goal until someone reloaded the tab.
 */
export function currentGoalYear(): number {
  return new Date().getFullYear()
}

/* ----------------------------------------------------------------- rows */

/** Which basis v_account_goal_progress used for "should be here by now". */
export type PaceBasis = 'seasonal' | 'straight_line' | 'not_started'

/**
 * Where the target came from: 'crm' = entered in the portal (account_goals,
 * editable, wins on conflict); 'erp' = dim_customer.yearly_sales_goal — the
 * customer master's USER_3 field, surfaced as the current-year default when
 * no portal goal exists (migration 20260817140000). ERP rows have no
 * account_goals row behind them, so there is nothing to remove.
 */
export type GoalSource = 'crm' | 'erp'

export interface AccountGoalProgress {
  goal_id: number
  customer_key: string
  customer_name: string | null
  sold_to_city: string | null
  sold_to_state: string | null
  active_flag: string | null
  period_year: number
  target_amount: number
  note: string | null
  updated_at: string | null
  /** erp.dim_customer.yearly_sales_goal — shown beside the rep goal, never replaced by it. */
  erp_yearly_sales_goal: number | null
  revenue_to_date: number
  attainment_pct: number
  /** Share of the goal that should be in by today, on this account's own seasonal shape. */
  expected_pct: number
  expected_amount: number
  /** Dollars ahead (+) or behind (−) pace. */
  gap_to_pace: number
  gap_to_goal: number
  projected_amount: number | null
  /** Null until the goal's year has started — no basis to judge, not "behind". */
  on_track: boolean | null
  pace_basis: PaceBasis
  days_remaining: number
  goal_source: GoalSource
}

export interface GoalRollup {
  period_year: number
  accounts_with_goal: number
  accounts_behind: number
  target_total: number
  revenue_total: number
  expected_total: number
  attainment_pct: number | null
  expected_pct: number | null
}

export interface RepGoalAttainment {
  user_id: string | null
  full_name: string | null
  active: boolean | null
  period_year: number
  assigned_accounts: number
  accounts_with_goal: number
  accounts_behind: number
  target_total: number
  revenue_total: number
  attainment_pct: number | null
  expected_pct: number | null
}

/** What the goal form collects. */
export interface GoalInput {
  targetAmount: number
  periodYear: number
  note?: string | null
}

/* -------------------------------------------------------------- plumbing */

/** PostgREST hands numerics back as strings depending on the column type. */
function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

function numOrNull(value: unknown): number | null {
  if (value == null) return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function toProgress(row: Record<string, unknown>): AccountGoalProgress {
  return {
    goal_id: num(row.goal_id),
    customer_key: String(row.customer_key),
    customer_name: (row.customer_name as string | null) ?? null,
    sold_to_city: (row.sold_to_city as string | null) ?? null,
    sold_to_state: (row.sold_to_state as string | null) ?? null,
    active_flag: (row.active_flag as string | null) ?? null,
    period_year: num(row.period_year),
    target_amount: num(row.target_amount),
    note: (row.note as string | null) ?? null,
    updated_at: (row.updated_at as string | null) ?? null,
    erp_yearly_sales_goal: numOrNull(row.erp_yearly_sales_goal),
    revenue_to_date: num(row.revenue_to_date),
    attainment_pct: num(row.attainment_pct),
    expected_pct: num(row.expected_pct),
    expected_amount: num(row.expected_amount),
    gap_to_pace: num(row.gap_to_pace),
    gap_to_goal: num(row.gap_to_goal),
    projected_amount: numOrNull(row.projected_amount),
    on_track: (row.on_track as boolean | null) ?? null,
    pace_basis: (row.pace_basis as PaceBasis) ?? 'straight_line',
    days_remaining: num(row.days_remaining),
    // Absent only if the view predates 20260817140000 — then every row is CRM.
    goal_source: (row.goal_source as GoalSource) ?? 'crm',
  }
}

const MISSING_RELATION_MESSAGE =
  'Account goals are not in the database yet. Apply ' +
  'supabase/migrations/023_account_goals.sql, then reload.'

/**
 * A goal table that does not exist yet is a deployment state, not a crash.
 * Every read below degrades to "no goal" so an unapplied migration costs the
 * account page a card, not the page.
 */
function asDisplayError(error: unknown): unknown {
  if (isViewMissing(error)) {
    return Object.assign(new Error(MISSING_RELATION_MESSAGE), { code: 'PGRST205' })
  }
  return error
}

function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isViewMissing(error) && failureCount < 1
}

/** Progress is recomputed off invoice lines the ETL lands once a night. */
const GOAL_STALE_TIME = 5 * 60_000

/* -------------------------------------------------------------- queries */

/** The goal for one account and year — the account page. Null when unset. */
export function useAccountGoal(
  customerKey: MaybeRef<string>,
  year: MaybeRef<number> = currentGoalYear(),
) {
  const key = computed(() => unref(customerKey))
  const period = computed(() => unref(year))
  return useQuery({
    queryKey: computed(() => [...qk.account.goal(key.value), period.value] as const),
    enabled: computed(() => !!key.value),
    staleTime: GOAL_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AccountGoalProgress | null> => {
      const { data, error } = await db
        .from('v_account_goal_progress')
        .select('*')
        .eq('customer_key', key.value)
        .eq('period_year', period.value)
        .maybeSingle()
      if (error) throw asDisplayError(error)
      return data ? toProgress(data) : null
    },
  })
}

/**
 * Every customer_key travels in the query string, so an unbounded `.in()`
 * eventually produces a URL PostgREST rejects. The accounts list pages 50 at
 * a time and "Load more" keeps appending, so this is reachable by scrolling.
 * Chunked rather than capped: a truncated map would decorate the top of the
 * list and silently stop, which reads like "those accounts have no goal".
 */
const GOAL_KEY_CHUNK = 150

function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size))
  return out
}

/**
 * Goals for the accounts currently ON SCREEN, as a customer_key → progress
 * map. One `.in()` over the visible keys rather than a query per row — the
 * same shape as useAccountNames()/useAiHeadlines().
 *
 * Degrades to an empty map on purpose: a missing goal decoration must never
 * take down the accounts list, and 023 may not be applied yet.
 */
export function useAccountGoalsFor(
  customerKeys: MaybeRef<string[]>,
  year: MaybeRef<number> = currentGoalYear(),
) {
  const list = computed(() => [...new Set(unref(customerKeys))].sort())
  const period = computed(() => unref(year))
  return useQuery({
    queryKey: computed(() => qk.goals.forAccounts(period.value, list.value)),
    enabled: computed(() => list.value.length > 0),
    staleTime: GOAL_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<Record<string, AccountGoalProgress>> => {
      const batches = await Promise.all(
        chunk(list.value, GOAL_KEY_CHUNK).map(async (keys) => {
          const { data, error } = await db
            .from('v_account_goal_progress')
            .select('*')
            .eq('period_year', period.value)
            .in('customer_key', keys)
          if (error) {
            if (isViewMissing(error)) return []
            throw error
          }
          return (data ?? []) as Record<string, unknown>[]
        }),
      )
      const map: Record<string, AccountGoalProgress> = {}
      for (const row of batches.flat()) {
        const progress = toProgress(row)
        map[progress.customer_key] = progress
      }
      return map
    },
  })
}

/**
 * The whole book ranked by attainment, worst first — "who am I behind on".
 *
 * Ordered in Postgres, not the browser: the point of the list is the accounts
 * at the BOTTOM, and a client-side sort behind a row limit would silently
 * drop exactly those. Bounded because only accounts with a goal have a row.
 */
export function useAccountsBehindGoal(
  year: MaybeRef<number> = currentGoalYear(),
  limit = 200,
) {
  const period = computed(() => unref(year))
  return useQuery({
    queryKey: computed(() => qk.goals.behind(period.value)),
    staleTime: GOAL_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AccountGoalProgress[]> => {
      const { data, error } = await db
        .from('v_account_goal_progress')
        .select('*')
        .eq('period_year', period.value)
        .order('attainment_pct', { ascending: true })
        .limit(limit)
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map(toProgress)
    },
  })
}

/** Book-level totals for the Today page. Aggregated in Postgres (023). */
export function useGoalRollup(year: MaybeRef<number> = currentGoalYear()) {
  const period = computed(() => unref(year))
  return useQuery({
    queryKey: computed(() => qk.goals.rollup(period.value)),
    staleTime: GOAL_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<GoalRollup | null> => {
      const { data, error } = await db
        .from('v_my_goal_rollup')
        .select('*')
        .eq('period_year', period.value)
        .maybeSingle()
      if (error) {
        // The Today page must render without this. An unapplied migration or
        // a rep with no goals both mean "nothing to show", not an error card.
        if (isViewMissing(error)) return null
        throw error
      }
      if (!data) return null
      return {
        period_year: num(data.period_year),
        accounts_with_goal: num(data.accounts_with_goal),
        accounts_behind: num(data.accounts_behind),
        target_total: num(data.target_total),
        revenue_total: num(data.revenue_total),
        expected_total: num(data.expected_total),
        attainment_pct: numOrNull(data.attainment_pct),
        expected_pct: numOrNull(data.expected_pct),
      }
    },
  })
}

/** Per-rep attainment for the admin execution page. */
export function useRepGoalAttainment() {
  return useQuery({
    queryKey: qk.admin.repGoals(),
    staleTime: GOAL_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<RepGoalAttainment[]> => {
      const { data, error } = await db
        .from('v_rep_goal_attainment')
        .select('*')
        .order('full_name')
      if (error) throw asDisplayError(error)
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        user_id: (r.user_id as string | null) ?? null,
        full_name: (r.full_name as string | null) ?? null,
        active: (r.active as boolean | null) ?? null,
        period_year: num(r.period_year),
        assigned_accounts: num(r.assigned_accounts),
        accounts_with_goal: num(r.accounts_with_goal),
        accounts_behind: num(r.accounts_behind),
        target_total: num(r.target_total),
        revenue_total: num(r.revenue_total),
        attainment_pct: numOrNull(r.attainment_pct),
        expected_pct: numOrNull(r.expected_pct),
      }))
    },
  })
}

/* --------------------------------------------------------------- writes */

function useInvalidateGoals() {
  const qc = useQueryClient()
  return (customerKey: string) => {
    // The account page reads it under qk.account.goal(key); the list, the
    // Today rollup and the admin grid are book-wide and no account key
    // covers them.
    void qc.invalidateQueries({ queryKey: qk.account.root(customerKey) })
    void qc.invalidateQueries({ queryKey: qk.goals.root() })
    void qc.invalidateQueries({ queryKey: qk.admin.repGoals() })
  }
}

/**
 * Set or change the goal for an account and year.
 *
 * An upsert on the (customer_key, period_year) unique constraint rather than
 * a read-then-insert-or-update: the goal is per account, so two people on the
 * same dealer would otherwise race and one would get a duplicate-key error
 * they cannot act on.
 *
 * created_by is deliberately not sent. The column defaults to auth.uid() and
 * the insert policy requires `created_by = auth.uid()`, so sending it adds
 * nothing but a way to get it wrong; on the conflict path it is left alone
 * and the trigger stamps updated_by instead.
 */
export function useSetAccountGoal() {
  const invalidate = useInvalidateGoals()
  return useMutation({
    mutationFn: async (input: { customerKey: string; values: GoalInput }) => {
      const note = input.values.note?.trim()
      const { data, error } = await db
        .from('account_goals')
        .upsert(
          {
            customer_key: input.customerKey,
            period_year: input.values.periodYear,
            target_amount: input.values.targetAmount,
            note: note ? note : null,
          },
          { onConflict: 'customer_key,period_year' },
        )
        .select()
      if (error) throw error
      // No `.single()`: when RLS filters the row out PostgREST reports "0
      // rows" as a coercion error, which reads like a bug rather than a
      // permission problem.
      if (!data?.length) {
        throw new Error(
          "That goal couldn't be saved. This account may be outside your book.",
        )
      }
      return data[0]
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}

/** Clear the goal. Reps may do this on their own accounts — see 023's RLS note. */
export function useRemoveAccountGoal() {
  const invalidate = useInvalidateGoals()
  return useMutation({
    mutationFn: async (input: { customerKey: string; periodYear: number }) => {
      const { data, error } = await db
        .from('account_goals')
        .delete()
        .eq('customer_key', input.customerKey)
        .eq('period_year', input.periodYear)
        .select()
      if (error) throw error
      if (!data?.length) {
        throw new Error('That goal is already gone.')
      }
      return data[0]
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}

/* ------------------------------------------------------------ formatting */

/**
 * "12% ahead of pace" / "8% behind pace" / "on pace" — the sentence under the
 * progress bar. Percentage points of the goal, not a percentage of a
 * percentage, because that is the unit the bar itself is drawn in.
 */
export function paceLabel(goal: AccountGoalProgress | null): string {
  if (!goal) return ''
  if (goal.on_track == null) return 'Not started yet'
  const points = Math.round(goal.attainment_pct - goal.expected_pct)
  if (points === 0) return 'On pace'
  return points > 0 ? `${points}% ahead of pace` : `${Math.abs(points)}% behind pace`
}

/** Where the pace bar's "should be here" marker comes from, in plain English. */
export function paceBasisLabel(goal: AccountGoalProgress | null): string {
  if (!goal) return ''
  if (goal.pace_basis === 'seasonal') {
    return "Pace follows this account's own buying season last year"
  }
  if (goal.pace_basis === 'not_started') return "This goal's year hasn't started"
  return 'Pace is a straight line — no prior year to compare against'
}
