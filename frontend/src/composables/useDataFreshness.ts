import { computed, watch } from 'vue'
import { useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { freshnessStamp, isErpQueryKey, qk } from '@/lib/queryClient'

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
  /** When the nightly ETL last finished with every table and every required
   *  post-load step successful. */
  data_loaded_at: string | null
  /** Newest non-memo invoice date in the warehouse — the revenue horizon. */
  data_through: string | null
  /** Newest order entry date. Runs ahead of data_through when ERP billing lags shipping. */
  orders_through: string | null
}

/** How often an open app checks for a new nightly load. */
const HEARTBEAT_MS = 15 * 60_000

export function useDataFreshness() {
  const query = useQuery({
    queryKey: qk.freshness(),
    // This is the ERP cache's heartbeat (useErpHeartbeat below), so it is the
    // one ERP-adjacent read that IS checked whenever the rep comes back to
    // the app, at most once a minute, and every 15 minutes while it is open.
    // One row; cheap enough to ask often.
    staleTime: 60_000,
    refetchOnWindowFocus: true,
    refetchInterval: HEARTBEAT_MS,
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

/**
 * Keep the ERP cache keyed to the nightly load. Mounted once, in AppShell.
 *
 * ERP queries (isErpQueryKey) hold their data for hours and skip the
 * refetch-on-focus every other query does, because the rows only change when
 * the ETL runs. This is how a new run reaches them: when the freshness stamp
 * (freshnessStamp: data_loaded_at, data_through and orders_through) moves
 * from the value the cache was built under, every ERP query is invalidated —
 * the ones on screen refetch now, the rest on next use.
 *
 * Not data_loaded_at alone: that is the last FULLY successful run. The ETL
 * also lands the facts and rebuilds the rollups on a night when an
 * unrelated table failed. That night's run is logged as an error, so
 * data_loaded_at stays put while the invoice and order horizons move. A
 * heartbeat watching only data_loaded_at would leave phones on yesterday's
 * ERP data for hours after such a night.
 *
 * "The value the cache was built under" survives an app restart: the
 * freshness row is persisted with the ERP queries (queryPersist.ts), so a
 * morning open compares last night's stamp from disk against the server's
 * and refreshes whatever the phone kept from before the load. Until the row
 * is loaded (from disk or the server) the stamp is undefined and nothing is
 * compared.
 */
export function useErpHeartbeat() {
  const qc = useQueryClient()
  const { data } = useDataFreshness()
  let seen: string | undefined

  watch(
    () => freshnessStamp(data.value),
    (stamp) => {
      if (stamp === undefined) return
      if (seen !== undefined && stamp !== seen) {
        void qc.invalidateQueries({ predicate: (q) => isErpQueryKey(q.queryKey) })
      }
      seen = stamp
    },
    { immediate: true },
  )
}
