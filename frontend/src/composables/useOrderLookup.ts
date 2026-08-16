import { computed, unref, type MaybeRef } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { isViewMissing } from '@/composables/useAccountMetrics'

/**
 * Cross-account order lookup — public.lookup_orders(text, int), migration 035.
 *
 * The one question a rep gets asked more than any other is "did my PO land,
 * and when does it ship?", and until 035 the portal could not answer it: the
 * dealer's PO number was landed on every order line and shown nowhere, and
 * every other read in the app is anchored to a customer_key the rep had
 * already navigated to. This is the only rep-facing query that starts from a
 * number instead of an account.
 *
 * RLS does the scoping. The function is SECURITY INVOKER precisely so a rep
 * pasting a competitor dealer's PO number gets nothing back — see the
 * migration header, and supabase/tests/035_order_lookup.sql, which asserts
 * exactly that from both reps' seats.
 */

/** The RPC postdates the generated database.types.ts. */
const db = supabase as unknown as SupabaseClient

export interface OrderLookupRow {
  customer_key: string
  customer_id: string | null
  customer_name: string | null
  order_id: string
  order_date: string | null
  order_state: string | null
  order_status_desc: string | null
  customer_po_number: string | null
  line_count: number
  bookings: number
  open_line_count: number
  backlog_amount: number
  next_promise_date: string | null
  next_desired_ship_date: string | null
  tracking_numbers: string | null
  last_ship_date: string | null
  /** Which field the search term hit: 'order' | 'po' | 'tracking'. */
  matched_on: string | null
}

function num(value: unknown): number {
  const n = Number(value ?? 0)
  return Number.isFinite(n) ? n : 0
}

/** The shortest term worth a round trip. One or two characters would match
 *  most of the book and tell the rep nothing. */
export const MIN_LOOKUP_LENGTH = 3

export function useOrderLookup(term: MaybeRef<string>) {
  const t = computed(() => unref(term).trim())
  const longEnough = computed(() => t.value.length >= MIN_LOOKUP_LENGTH)

  const query = useQuery({
    queryKey: computed(() => ['order-lookup', t.value] as const),
    enabled: longEnough,
    // A lookup is a deliberate act with a fresh answer expected; but the same
    // term re-typed within a minute is the rep double-checking, not new data.
    staleTime: 60_000,
    retry: (failureCount, error) => !isViewMissing(error) && failureCount < 1,
    queryFn: async (): Promise<OrderLookupRow[]> => {
      const { data, error } = await db.rpc('lookup_orders', {
        p_term: t.value,
        p_limit: 25,
      })
      if (error) {
        if (isViewMissing(error)) {
          throw Object.assign(
            new Error(
              'Order lookup is not in the database yet. Apply ' +
                'supabase/migrations/035_order_lookup.sql, then reload.',
            ),
            { code: 'PGRST202' },
          )
        }
        throw error
      }
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        customer_key: String(r.customer_key),
        customer_id: (r.customer_id as string | null) ?? null,
        customer_name: (r.customer_name as string | null) ?? null,
        order_id: String(r.order_id),
        order_date: (r.order_date as string | null) ?? null,
        order_state: (r.order_state as string | null) ?? null,
        order_status_desc: (r.order_status_desc as string | null) ?? null,
        customer_po_number: (r.customer_po_number as string | null) ?? null,
        line_count: num(r.line_count),
        bookings: num(r.bookings),
        open_line_count: num(r.open_line_count),
        backlog_amount: num(r.backlog_amount),
        next_promise_date: (r.next_promise_date as string | null) ?? null,
        next_desired_ship_date:
          (r.next_desired_ship_date as string | null) ?? null,
        tracking_numbers: (r.tracking_numbers as string | null) ?? null,
        last_ship_date: (r.last_ship_date as string | null) ?? null,
        matched_on: (r.matched_on as string | null) ?? null,
      }))
    },
  })

  return { ...query, longEnough }
}

/** Why this row came back, in words a rep would use. */
export function matchLabel(matchedOn: string | null): string {
  switch (matchedOn) {
    case 'po':
      return 'Matched their PO number'
    case 'tracking':
      return 'Matched a tracking number'
    case 'order':
      return 'Matched our order number'
    default:
      return ''
  }
}

/**
 * Where the order stands, as one sentence. Ordered by what the dealer
 * actually asked: still owed → when → already gone.
 */
export function statusSentence(row: OrderLookupRow): string {
  if (row.open_line_count > 0) {
    const when =
      row.next_promise_date ?? row.next_desired_ship_date ?? null
    return when
      ? `${row.open_line_count} line${row.open_line_count === 1 ? '' : 's'} still open`
      : `${row.open_line_count} line${row.open_line_count === 1 ? '' : 's'} still open, no date yet`
  }
  if (row.last_ship_date) return 'Shipped complete'
  return 'Nothing open'
}
