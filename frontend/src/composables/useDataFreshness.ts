import { computed, watch } from 'vue'
import { useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { isMissingDbObject, supabase } from '@/lib/supabase'
import { atsStamp, freshnessStamp, isAtsQueryKey, isErpQueryKey, qk } from '@/lib/queryClient'

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
  /** When the ETL last finished a full or hourly run with every table and
   *  every required post-load step successful (20261027090100). */
  data_loaded_at: string | null
  /** Newest non-memo invoice date in the warehouse — the revenue horizon. */
  data_through: string | null
  /** Newest order entry date. Runs ahead of data_through when ERP billing lags shipping. */
  orders_through: string | null
  /**
   * When erp.fact_available_to_sell was last confirmed against the ERP —
   * the stock tier, every 15 minutes on weekdays (20261027090100). Null on a
   * database without that migration.
   */
  ats_loaded_at: string | null
}

/**
 * How often an open, visible app checks for a new load. Five minutes, not
 * fifteen: stock now loads every 15 minutes and orders hourly, and a check
 * at the load's own cadence would leave a phone up to two loads behind.
 */
export const HEARTBEAT_MS = 5 * 60_000

const COLUMNS = 'data_loaded_at, data_through, orders_through'

/**
 * A database without 20261027090100 has no ats_loaded_at, and naming a
 * missing column fails the whole select (42703). Remembered for the session
 * so the 5-minute heartbeat does not pay for the failed ask every time.
 */
let atsColumnMissing = false

export function useDataFreshness() {
  const query = useQuery({
    queryKey: qk.freshness(),
    // This is the ERP cache's heartbeat (useErpHeartbeat below), so it is the
    // one ERP-adjacent read that IS checked whenever the rep comes back to
    // the app, at most once a minute, and every 5 minutes while it is open.
    // One row; cheap enough to ask often.
    staleTime: 60_000,
    refetchOnWindowFocus: true,
    refetchInterval: HEARTBEAT_MS,
    // The interval only ticks while the page is visible: TanStack's focus
    // manager reads document.visibilityState, and a hidden tab (the phone
    // locked in a pocket, a background browser tab) asks nothing. Coming
    // back is the focus refetch above. Pinned here because the default is
    // exactly what this needs and must not drift.
    refetchIntervalInBackground: false,
    queryFn: async (): Promise<DataFreshnessRow> => {
      const read = (columns: string) => db.from('v_data_freshness').select(columns).maybeSingle()
      let result = atsColumnMissing ? await read(COLUMNS) : await read(`${COLUMNS}, ats_loaded_at`)
      if (result.error && !atsColumnMissing && isMissingDbObject(result.error)) {
        atsColumnMissing = true
        result = await read(COLUMNS)
      }
      if (result.error) throw result.error
      const data = result.data as Record<string, unknown> | null
      return {
        data_loaded_at: (data?.data_loaded_at as string | null) ?? null,
        data_through: (data?.data_through as string | null) ?? null,
        orders_through: (data?.orders_through as string | null) ?? null,
        ats_loaded_at: (data?.ats_loaded_at as string | null) ?? null,
      }
    },
  })

  return {
    ...query,
    loadedAt: computed(() => query.data.value?.data_loaded_at ?? null),
    dataThrough: computed(() => query.data.value?.data_through ?? null),
    ordersThrough: computed(() => query.data.value?.orders_through ?? null),
    atsLoadedAt: computed(() => query.data.value?.ats_loaded_at ?? null),
  }
}

/**
 * Keep the ERP cache keyed to the loads. Mounted once, in AppShell.
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
 * The stock tier is the second stamp (atsStamp: ats_loaded_at). When only it
 * moves — the 15-minute stock load — only the in-stock reads
 * (isAtsQueryKey) are invalidated; the account pages and rollups keep their
 * cache. One watch over both stamps rather than two watches, so a full run
 * that moves both invalidates once: two back-to-back invalidations would
 * cancel and restart the In stock page's refetch.
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
  let seenErp: string | undefined
  let seenAts: string | undefined

  watch(
    () => [freshnessStamp(data.value), atsStamp(data.value)] as const,
    ([erp, ats]) => {
      if (erp === undefined || ats === undefined) return
      const erpMoved = seenErp !== undefined && erp !== seenErp
      const atsMoved = seenAts !== undefined && ats !== seenAts
      if (erpMoved) {
        // A full or hourly run: everything ERP, plus the stock reads that
        // are not ERP keys (the header search) when stock moved with it.
        void qc.invalidateQueries({
          predicate: (q) => isErpQueryKey(q.queryKey) || (atsMoved && isAtsQueryKey(q.queryKey)),
        })
      } else if (atsMoved) {
        void qc.invalidateQueries({ predicate: (q) => isAtsQueryKey(q.queryKey) })
      }
      seenErp = erp
      seenAts = ats
    },
    { immediate: true },
  )
}
