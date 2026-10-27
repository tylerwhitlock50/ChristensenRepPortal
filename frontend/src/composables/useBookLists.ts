import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { isMissingDbObject, supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/fetchAll'
import { qk } from '@/lib/queryClient'
import {
  mapBookShipmentLine,
  mapOpenOrderLine,
  type BookShipmentLine,
  type OpenOrderLine,
} from '@/lib/bookLists'

/**
 * The two book lists that replace the outside reps' Tableau pulls
 * (20261027090600): every open order line, and every packlist line in a
 * date window. Both are read UNFILTERED — security_invoker view and a
 * SECURITY INVOKER function, so RLS is the territory filter, exactly as for
 * the other intel reads — and filtered on the phone (lib/bookLists.ts).
 *
 * Both keys are ERP keys (queryClient.ts): the data moves with the hourly
 * and full loads, and the heartbeat refreshes it when one lands.
 *
 * `unavailable` is true on a database without the migration (a preview
 * pointed at an older database): the page says the list is on its way
 * instead of showing an error card. Any other error is a real error.
 */

/** The view and function postdate the generated types' last regeneration. */
const db = supabase as unknown as SupabaseClient

/** A missing object will still be missing in a second. */
const retryUnlessMissing = (failureCount: number, error: unknown) =>
  !isMissingDbObject(error) && failureCount < 1

export function useOpenOrderLines() {
  const query = useQuery({
    queryKey: qk.intel.openOrders(),
    retry: retryUnlessMissing,
    queryFn: async (): Promise<OpenOrderLine[]> => {
      // A principal's book runs to thousands of open lines — page it.
      // (order_id, line_num) is fact_order_line's key, so this order is total.
      const data = await fetchAllRows<Record<string, unknown>>((from, to) =>
        db
          .from('v_open_order_lines')
          .select('*', { count: 'exact' }) // unfiltered on purpose — RLS is the territory filter
          .order('customer_key')
          .order('order_id')
          .order('line_num')
          .range(from, to),
      )
      return data.map(mapOpenOrderLine)
    },
  })
  return { ...query, unavailable: computed(() => isMissingDbObject(query.error.value)) }
}

/**
 * Packlist lines shipped between `from` and `to` (inclusive, yyyy-MM-dd).
 * `enabled` is the page's say-so: a custom window the function would refuse
 * (rangeProblem) is never sent.
 */
export function useBookShipments(
  range: MaybeRefOrGetter<{ from: string; to: string }>,
  enabled: MaybeRefOrGetter<boolean> = true,
) {
  const span = computed(() => toValue(range))
  const query = useQuery({
    queryKey: computed(() => qk.intel.bookShipments(span.value.from, span.value.to)),
    enabled: computed(() => toValue(enabled) && !!span.value.from && !!span.value.to),
    retry: retryUnlessMissing,
    queryFn: async (): Promise<BookShipmentLine[]> => {
      const { from: pFrom, to: pTo } = span.value
      // Each window re-runs the function, which is built to answer a year
      // of a principal's book in well under the 8 s timeout (filter by
      // ship date first, then key lookups). (packlist_id, line_num) is the
      // shipment line's key, so the order is total and pages never overlap.
      const data = await fetchAllRows<Record<string, unknown>>((from, to) =>
        db
          .rpc('report_book_shipments', { p_from: pFrom, p_to: pTo }, { count: 'exact' })
          .order('ship_date', { ascending: false, nullsFirst: false })
          .order('packlist_id', { ascending: false })
          .order('line_num')
          .range(from, to),
      )
      return data.map(mapBookShipmentLine)
    },
  })
  return { ...query, unavailable: computed(() => isMissingDbObject(query.error.value)) }
}
