import { computed, unref, type MaybeRef } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { isViewMissing } from '@/composables/useAccountMetrics'

/**
 * "What should I be selling this dealer?" — public.report_account_sku_gaps,
 * migration 036.
 *
 * The three inputs already existed on three different screens (ATS, the
 * account's SKU history, global best-sellers) and the rep was doing the
 * cross-reference in their head, on a phone, standing in a shop. This is
 * that join, done in Postgres, returning only the answer.
 *
 * The RPC is SECURITY DEFINER — dealer breadth is a company-wide count no
 * rep's RLS would return — and is gated on has_account_access(customer_key)
 * as the first thing it evaluates. supabase/tests/036_sku_gaps.sql asserts
 * that a rep passing another rep's account gets nothing.
 */

/** The RPC postdates the generated database.types.ts. */
const db = supabase as unknown as SupabaseClient

export interface SkuGapRow {
  part_key: string
  part_id: string | null
  part_description: string | null
  product_code: string | null
  product_family: string | null
  chambering: string | null
  barrel_length: string | null
  upc: string | null
  /** Units we could ship today. */
  ats_qty: number
  /** Distinct dealers company-wide who bought it in the window. */
  dealer_count: number
  units_sold: number
  /** False = never bought. True = they used to; a different conversation. */
  bought_before: boolean
  last_bought_date: string | null
}

function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

const ERP_STALE_TIME = 10 * 60_000

export function useAccountSkuGaps(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.skuGaps(key.value)),
    enabled: computed(() => !!key.value),
    staleTime: ERP_STALE_TIME,
    retry: (failureCount, error) => !isViewMissing(error) && failureCount < 1,
    queryFn: async (): Promise<SkuGapRow[]> => {
      const { data, error } = await db.rpc('report_account_sku_gaps', {
        p_customer_key: key.value,
        p_months: 12,
        p_min_dealers: 4,
        p_limit: 25,
      })
      if (error) {
        // 036 not applied yet. Nothing else on the account page depends on
        // this card, so it stays quiet rather than showing the rep an error
        // about a migration they cannot run.
        if (isViewMissing(error)) return []
        throw error
      }
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        part_key: String(r.part_key),
        part_id: (r.part_id as string | null) ?? null,
        part_description: (r.part_description as string | null) ?? null,
        product_code: (r.product_code as string | null) ?? null,
        product_family: (r.product_family as string | null) ?? null,
        chambering: (r.chambering as string | null) ?? null,
        barrel_length: (r.barrel_length as string | null) ?? null,
        upc: (r.upc as string | null) ?? null,
        ats_qty: num(r.ats_qty),
        dealer_count: num(r.dealer_count),
        units_sold: num(r.units_sold),
        bought_before: r.bought_before === true,
        last_bought_date: (r.last_bought_date as string | null) ?? null,
      }))
    },
  })
}

/**
 * The sentence a rep can say out loud, which is the whole point of the card.
 * Two shapes, because "never carried it" and "used to carry it" are different
 * conversations and blurring them would make both weaker.
 *
 * Pure and exported so the wording can be reasoned about without a DB.
 */
export function gapPitch(row: SkuGapRow): string {
  const dealers = `${row.dealer_count} dealer${row.dealer_count === 1 ? '' : 's'}`
  return row.bought_before
    ? `Stocked by ${dealers} · they used to carry it`
    : `Stocked by ${dealers} · never carried here`
}
