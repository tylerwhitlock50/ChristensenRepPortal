import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { isMissingDbObject, supabase } from '@/lib/supabase'
import { ERP_STALE_TIME } from '@/lib/queryClient' // the nightly-load policy

/**
 * "Bought before and in stock now" — public.report_reorder_candidates,
 * migration 20261013100000.
 *
 * The account's own repeat buys (erp.agg_sku_month, 36 months) that we can
 * ship today, each with its buying rhythm: last buy month and quantity, how
 * many months it was bought in, the median gap between buys, and the month
 * the next buy is expected. `is_due` once that month has arrived. Due rows
 * come first. Finished guns only, same screens as the SKU-gaps card.
 *
 * SECURITY INVOKER: RLS on agg_sku_month (view-as aware) is the scope, so
 * an account outside the caller's book simply returns no rows.
 *
 * `unavailable` is true when the RPC does not exist yet (a preview pointed at
 * a database without the migration). Callers hide the feature then — never
 * an error card for it. Any other error is a real error.
 */

/** The RPC postdates the generated database.types.ts. */
const db = supabase as unknown as SupabaseClient

/**
 * Under ['account', key] so the account-root invalidation sweeps it. `limit`
 * is in the key so two callers asking for different lengths don't share an
 * entry (same reasoning as useAccountSkuGaps).
 */
export const reorderCandidatesKey = (customerKey: string, limit: number) =>
  ['account', customerKey, 'reorders', limit] as const

export interface ReorderCandidate {
  part_key: string
  part_id: string | null
  part_description: string | null
  product_code: string | null
  product_family: string | null
  chambering: string | null
  barrel_length: string | null
  upc: string | null
  /** Units available to sell today, summed over sites. Always >= 1. */
  ats_qty: number
  /** First day of the last month they bought it, 'YYYY-MM-DD'. */
  last_bought_month: string
  /** Units bought in that month. */
  last_qty: number
  /** Units bought over the whole window (buy months only). */
  total_qty: number
  /** Distinct months with a purchase. */
  months_with_buys: number
  /** Median months between buy months, 1 decimal. Null with one buy month. */
  median_months_between_buys: number | null
  /** last_bought_month + the median gap (rounded), 'YYYY-MM-DD'. Null with no gap. */
  expected_next_month: string | null
  /** expected_next_month is this month or earlier. */
  is_due: boolean
}

function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

function numOrNull(value: unknown): number | null {
  if (value == null) return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function str(value: unknown): string | null {
  return value == null ? null : String(value)
}

function toCandidate(r: Record<string, unknown>): ReorderCandidate {
  return {
    part_key: String(r.part_key),
    part_id: str(r.part_id),
    part_description: str(r.part_description),
    product_code: str(r.product_code),
    product_family: str(r.product_family),
    chambering: str(r.chambering),
    barrel_length: str(r.barrel_length),
    upc: str(r.upc),
    ats_qty: num(r.ats_qty),
    last_bought_month: String(r.last_bought_month),
    last_qty: num(r.last_qty),
    total_qty: num(r.total_qty),
    months_with_buys: num(r.months_with_buys),
    median_months_between_buys: numOrNull(r.median_months_between_buys),
    expected_next_month: str(r.expected_next_month),
    is_due: r.is_due === true,
  }
}

export function useReorderCandidates(customerKey: MaybeRefOrGetter<string>, limit = 10) {
  const key = computed(() => toValue(customerKey))
  const query = useQuery({
    queryKey: computed(() => reorderCandidatesKey(key.value, limit)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    // A missing function will still be missing in a second.
    retry: (failureCount, error) => !isMissingDbObject(error) && failureCount < 1,
    queryFn: async (): Promise<ReorderCandidate[]> => {
      const { data, error } = await db.rpc('report_reorder_candidates', {
        p_customer_key: key.value,
        p_limit: limit,
      })
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map(toCandidate)
    },
  })

  const rows = computed(() => query.data.value ?? [])
  const unavailable = computed(() => isMissingDbObject(query.error.value))

  return { ...query, rows, unavailable }
}
