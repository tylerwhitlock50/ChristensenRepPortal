import { computed, unref, type MaybeRef } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/fetchAll'
import { qk } from '@/lib/queryClient'
/**
 * The base relation-missing test, NOT useOverview's — useOverview imports the
 * derivations at the bottom of this file, and taking its copy would close an
 * import cycle. useAccountMetrics imports neither, and its version is the
 * right one anyway: this file reads a table, never an RPC, so the PGRST202
 * ("function not found") arm useOverview adds has nothing to match here.
 */
import { isViewMissing } from '@/composables/useAccountMetrics'

/**
 * public.account_signals — the behavioural read on each account, recomputed
 * every night by refresh_account_signals() after the ETL lands
 * (migration 019_account_scoring.sql).
 *
 * This table has existed and been refreshed nightly since 019 and, until now,
 * no screen in the app read a single row of it. The whole point of the
 * scoring work was the `cadence` factor — "overdue against THIS account's own
 * rhythm" — and that is exactly the fact a rep needs and never got.
 *
 * No migration was needed to read it: 019 already ships an RLS select policy
 * (`read account signals`) with the same predicate shape as
 * 010_access_performance.sql, and grants select to `authenticated`. So an
 * unscoped select returns exactly the caller's book, the same way
 * useOverview.ts's territory query does. Do NOT add an owner filter here.
 *
 * Rows exist only for "scorable" accounts — active, not internal, with some
 * invoice or order activity in the last 24 months (019's header). A missing
 * row is normal and means "unranked", never "zero"; every consumer below
 * treats absent as absent.
 */

/** 019 postdates the generated database.types.ts — same untyped-handle
 *  convention as useAccountMetrics.ts / useOverview.ts. */
const db = supabase as unknown as SupabaseClient

/* ----------------------------------------------------------------- rows */

export interface AccountSignalRow {
  customer_key: string
  /** Median gap in days between consecutive order DAYS. Null when unknown. */
  cadence_days: number | null
  /** False when there were too few gaps to call it a rhythm (019: >= 2). */
  cadence_confident: boolean
  days_since_order: number | null
  last_order_date: string | null
  /** Distinct order days in 24 months — how much evidence cadence rests on. */
  order_days_24m: number | null
  /** Product families bought in the last 12m vs the 12m before. */
  families_12m: number | null
  families_prior_12m: number | null
  families_dropped: number | null
  /** Ratio, e.g. -0.31. Null when there is no prior year to compare to. */
  yoy_change: number | null
  revenue_12m: number | null
  /** 0..1 percent_rank across the whole scored book. */
  revenue_percentile: number | null
  score: number | null
  priority: 'high' | 'normal' | 'low' | null
}

/* -------------------------------------------------------------- plumbing */

function num(value: unknown): number | null {
  if (value == null) return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function mapRow(r: Record<string, unknown>): AccountSignalRow {
  return {
    customer_key: String(r.customer_key),
    cadence_days: num(r.cadence_days),
    cadence_confident: r.cadence_confident === true,
    days_since_order: num(r.days_since_order),
    last_order_date: (r.last_order_date as string | null) ?? null,
    order_days_24m: num(r.order_days_24m),
    families_12m: num(r.families_12m),
    families_prior_12m: num(r.families_prior_12m),
    families_dropped: num(r.families_dropped),
    yoy_change: num(r.yoy_change),
    revenue_12m: num(r.revenue_12m),
    revenue_percentile: num(r.revenue_percentile),
    score: num(r.score),
    priority: (r.priority as AccountSignalRow['priority']) ?? null,
  }
}

/**
 * An explicit column list rather than '*': account_signals carries a
 * `factors` jsonb blob (per-factor value/weight/contribution/why) plus five
 * sub-scores that nothing here reads, and an admin's book is every scorable
 * account in the ERP. Naming columns keeps a whole-book page small.
 *
 * The cost is that `db` is the untyped SupabaseClient handle, so a column-list
 * .select() resolves its row type to GenericStringError[] instead of a row —
 * hence the cast at each call site below, in the same spirit as the `db` cast
 * itself. The shape is asserted by mapRow() either way.
 */
const SELECT_COLUMNS =
  'customer_key, cadence_days, cadence_confident, days_since_order, ' +
  'last_order_date, order_days_24m, families_12m, families_prior_12m, ' +
  'families_dropped, yoy_change, revenue_12m, revenue_percentile, score, priority'

/** PostgREST rows through the untyped handle, before mapRow() asserts them. */
type RawRow = Record<string, unknown>

/**
 * A missing table is a deployment state (019 not applied), not a crash — and
 * unlike the account rollups, nothing on the page *depends* on signals. Every
 * consumer degrades to the pre-existing behaviour, so this returns an empty
 * list rather than surfacing an error the rep can do nothing about.
 */
function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isViewMissing(error) && failureCount < 1
}

// Refreshed once a night by the ETL; same holding period as the other ERP reads.
const ERP_STALE_TIME = 10 * 60_000

/* -------------------------------------------------------------- queries */

/**
 * Signals for the caller's whole book, keyed by customer_key for a cheap
 * client-side join against the territory rows the Overview already holds.
 *
 * Unfiltered on purpose — RLS is the territory filter. Paged because an
 * admin's book is every scorable account in the ERP and would silently stop
 * at PostgREST's 1,000-row cap.
 */
export function useTerritorySignals() {
  return useQuery({
    queryKey: qk.intel.signals(),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<Record<string, AccountSignalRow>> => {
      let data: Record<string, unknown>[]
      try {
        data = await fetchAllRows<RawRow>(
          (from, to) =>
            db
              .from('account_signals')
              .select(SELECT_COLUMNS, { count: 'exact' }) // unfiltered — RLS scopes it
              .order('customer_key')
              .range(from, to) as unknown as PromiseLike<{
              data: RawRow[] | null
              error: unknown
              count?: number | null
            }>,
        )
      } catch (error) {
        // 019 not applied yet: the app worked without signals before and still
        // does. Absent is a valid answer here.
        if (isViewMissing(error)) return {}
        throw error
      }
      const byKey: Record<string, AccountSignalRow> = {}
      for (const r of data) {
        const row = mapRow(r)
        byKey[row.customer_key] = row
      }
      return byKey
    },
  })
}

/** One account's signals, for the account page. */
export function useAccountSignals(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.signals(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<AccountSignalRow | null> => {
      const { data, error } = await db
        .from('account_signals')
        .select(SELECT_COLUMNS)
        .eq('customer_key', key.value)
        .maybeSingle()
      if (error) {
        if (isViewMissing(error)) return null
        throw error
      }
      return data ? mapRow(data as unknown as RawRow) : null
    },
  })
}

/* ---------------------------------------------------- derivations (pure) */

/**
 * "Usually orders every 47 days — 82 since the last one."
 *
 * Deliberately the same sentence `score_account()` builds in SQL
 * (019_account_scoring.sql, `why_cadence`), including its guard: the number
 * quoted is the OBSERVED median, and it is only quoted at all when
 * `cadence_confident` is true. An unconfident cadence is one or two orders'
 * worth of evidence, and stating a rhythm off that is a false statement about
 * a dealer the rep is about to walk in on.
 *
 * Returns null when there is nothing true to say.
 */
export function cadenceSentence(s: AccountSignalRow | null): string | null {
  if (!s || s.days_since_order == null) return null
  if (s.cadence_confident && s.cadence_days != null) {
    return `Usually orders every ${Math.round(s.cadence_days)} days — ${s.days_since_order} since the last one`
  }
  return `No order in ${s.days_since_order} days`
}

/**
 * How far past their own rhythm this account is: 1.0 = due, 2.0 = twice the
 * usual gap. Null when there is no confident rhythm to be late against — an
 * annual buyer 200 days out is early, and that distinction is the entire
 * reason 019 replaced the flat "no order in N days" rule.
 */
export function overdueRatio(s: AccountSignalRow | null): number | null {
  if (!s || !s.cadence_confident) return null
  if (s.days_since_order == null || !s.cadence_days || s.cadence_days <= 0) return null
  return s.days_since_order / s.cadence_days
}

/** True when the account is meaningfully past its own ordering rhythm. */
export function isOverdueForCadence(
  s: AccountSignalRow | null,
  threshold = 1.5,
): boolean {
  const ratio = overdueRatio(s)
  return ratio != null && ratio >= threshold
}
