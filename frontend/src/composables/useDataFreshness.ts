import { computed } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'

/**
 * The "As of … · Data through …" stamp (public.v_data_freshness, 024).
 *
 * Design principle #4 of the restructure: freshness is visible. A rep
 * looking at a number should never have to wonder whether it includes
 * yesterday — every intel page and every AI brief renders this stamp.
 */

/** 019 lands after database.types.ts was last generated — same untyped-handle
 *  convention as useAccountMetrics.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

export interface DataFreshnessRow {
  /** When the nightly ETL last finished successfully. */
  data_loaded_at: string | null
  /** Newest non-memo invoice date in the warehouse — the revenue horizon. */
  data_through: string | null
  /** Newest order entry date. Runs ahead of data_through when ERP billing lags shipping. */
  orders_through: string | null
}

export function useDataFreshness() {
  const query = useQuery({
    queryKey: qk.freshness(),
    // The ETL runs nightly; holding this for 10 minutes costs nothing.
    staleTime: 10 * 60_000,
    queryFn: async (): Promise<DataFreshnessRow> => {
      const { data, error } = await db
        .from('v_data_freshness')
        .select('data_loaded_at, data_through, orders_through')
        .maybeSingle()
      if (error) throw error
      return {
        data_loaded_at: (data?.data_loaded_at as string | null) ?? null,
        data_through: (data?.data_through as string | null) ?? null,
        orders_through: (data?.orders_through as string | null) ?? null,
      }
    },
  })

  return {
    ...query,
    loadedAt: computed(() => query.data.value?.data_loaded_at ?? null),
    dataThrough: computed(() => query.data.value?.data_through ?? null),
    ordersThrough: computed(() => query.data.value?.orders_through ?? null),
  }
}
