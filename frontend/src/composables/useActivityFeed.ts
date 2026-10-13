import { computed, ref, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { format } from 'date-fns'
import { isMissingDbObject, supabase } from '@/lib/supabase'
import { trackingList } from '@/lib/orderStatusMessage'

/**
 * The Overview's "Recent activity": what happened on the book in the last
 * 14 days — what shipped (with tracking, backorders called out), what was
 * ordered, and the heads-up a rep wants before the dealer rings: a promise
 * date that moved.
 *
 * Reads public.v_territory_recent_events (20261013150004), unfiltered:
 * security_invoker, so RLS is the territory filter exactly as for the
 * Overview's other reads. On a database without that migration it falls
 * back to the old orders-only read of v_territory_recent_orders (029), so
 * the card looks like it did before rather than broken.
 *
 * Grouping and the "new since you last looked" rule are pure functions
 * below, exported for tests/unit/activityFeed.test.ts.
 */

/** The view postdates the generated types. */
const db = supabase as unknown as SupabaseClient

/** Territory-scoped, like qk.intel.*: no account key, the caller's book. */
export const activityKeys = {
  feed: () => ['intel', 'territory-recent-events'] as const,
  fallback: () => ['intel', 'territory-recent-events', 'orders-only'] as const,
}

/** Rows read; the card shows what fits in its groups. */
export const ACTIVITY_LIMIT = 50

// Nightly ERP data; same holding period as the rest of the Overview.
const STALE_TIME = 10 * 60_000

export type ActivityKind = 'order_new' | 'shipped' | 'backorder_shipped' | 'promise_slipped'

export interface ActivityEvent {
  customer_key: string
  customer_name: string | null
  kind: ActivityKind
  /** yyyy-mm-dd: order date, ship date, or the night the change was seen. */
  occurred_on: string | null
  order_id: string | null
  customer_po_number: string | null
  packlist_id: string | null
  line_no: number | null
  part_id: string | null
  part_description: string | null
  amount: number | null
  qty: number | null
  line_count: number | null
  tracking_numbers: string | null
  ship_via: string | null
  promise_before: string | null
  promise_after: string | null
  has_backlog: boolean | null
  event_id: number | null
}

function numOrNull(value: unknown): number | null {
  if (value == null) return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function str(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

const KINDS: readonly ActivityKind[] = ['order_new', 'shipped', 'backorder_shipped', 'promise_slipped']

export function mapActivityRow(r: Record<string, unknown>): ActivityEvent | null {
  const kind = r.kind as ActivityKind
  if (!KINDS.includes(kind)) return null
  return {
    customer_key: String(r.customer_key),
    customer_name: str(r.customer_name),
    kind,
    occurred_on: str(r.occurred_on),
    order_id: str(r.order_id),
    customer_po_number: str(r.customer_po_number),
    packlist_id: str(r.packlist_id),
    line_no: numOrNull(r.line_no),
    part_id: str(r.part_id),
    part_description: str(r.part_description),
    amount: numOrNull(r.amount),
    qty: numOrNull(r.qty),
    line_count: numOrNull(r.line_count),
    tracking_numbers: str(r.tracking_numbers),
    ship_via: str(r.ship_via),
    promise_before: str(r.promise_before),
    promise_after: str(r.promise_after),
    has_backlog: typeof r.has_backlog === 'boolean' ? r.has_backlog : null,
    event_id: numOrNull(r.event_id),
  }
}

/** A v_territory_recent_orders row (029) in the feed's shape. */
export function mapFallbackOrder(r: Record<string, unknown>): ActivityEvent {
  return {
    customer_key: String(r.customer_key),
    customer_name: str(r.customer_name),
    kind: 'order_new',
    occurred_on: str(r.order_date),
    order_id: str(r.order_id),
    customer_po_number: null,
    packlist_id: null,
    line_no: null,
    part_id: null,
    part_description: null,
    amount: numOrNull(r.order_amount),
    qty: null,
    line_count: numOrNull(r.line_count),
    tracking_numbers: null,
    ship_via: null,
    promise_before: null,
    promise_after: null,
    has_backlog: r.has_backlog === true,
    event_id: null,
  }
}

/* ---------------------------------------------------------------- grouping */

export interface ShippedItem {
  key: string
  customer_key: string
  customer_name: string | null
  order_id: string | null
  customer_po_number: string | null
  occurred_on: string | null
  tracking: string[]
  ship_via: string | null
  amount: number | null
  /** The nightly capture saw a line that had been waiting go out. */
  backorder: boolean
  /** Which parts, when the capture named them. */
  backorderParts: string[]
}

export interface SlipItem {
  key: string
  customer_key: string
  customer_name: string | null
  order_id: string | null
  occurred_on: string | null
  lines: { part: string; before: string | null; after: string | null }[]
}

export interface ActivityGroups {
  shipped: ShippedItem[]
  newOrders: ActivityEvent[]
  headsUp: SlipItem[]
}

function byDateDesc<T extends { occurred_on: string | null }>(a: T, b: T): number {
  return (b.occurred_on ?? '').localeCompare(a.occurred_on ?? '')
}

function partName(e: ActivityEvent): string {
  return e.part_description || e.part_id || (e.line_no != null ? `Line ${e.line_no}` : 'A line')
}

/**
 * Shipments and backorder events describe the same parcels from two
 * sides: the shipment fact has the tracking, the nightly capture knows the
 * line had been waiting. One item per shipment, flagged as a backorder when
 * the capture saw one on that order; a backorder event with no shipment row
 * in the window (no packlist landed yet, or it fell outside 14 days) is an
 * item of its own. Slips are grouped per order.
 */
export function groupActivity(events: readonly ActivityEvent[]): ActivityGroups {
  const backorders = new Map<string, ActivityEvent[]>()
  for (const e of events) {
    if (e.kind !== 'backorder_shipped') continue
    const k = `${e.customer_key}|${e.order_id ?? ''}`
    backorders.set(k, [...(backorders.get(k) ?? []), e])
  }

  const shipped: ShippedItem[] = []
  const claimed = new Set<string>()
  for (const e of events) {
    if (e.kind !== 'shipped') continue
    const k = `${e.customer_key}|${e.order_id ?? ''}`
    const bo = backorders.get(k) ?? []
    if (bo.length) claimed.add(k)
    shipped.push({
      key: `s|${e.customer_key}|${e.packlist_id ?? ''}|${e.order_id ?? ''}`,
      customer_key: e.customer_key,
      customer_name: e.customer_name,
      order_id: e.order_id,
      customer_po_number: e.customer_po_number,
      occurred_on: e.occurred_on,
      tracking: trackingList(e.tracking_numbers),
      ship_via: e.ship_via,
      amount: e.amount,
      backorder: bo.length > 0,
      backorderParts: [...new Set(bo.map(partName))],
    })
  }
  for (const [k, bo] of backorders) {
    if (claimed.has(k)) continue
    const first = bo[0]!
    shipped.push({
      key: `b|${k}`,
      customer_key: first.customer_key,
      customer_name: first.customer_name,
      order_id: first.order_id,
      customer_po_number: null,
      occurred_on: bo.reduce<string | null>(
        (max, e) => ((e.occurred_on ?? '') > (max ?? '') ? e.occurred_on : max),
        null,
      ),
      tracking: trackingList(bo.map((e) => e.tracking_numbers ?? '').join(',')),
      ship_via: null,
      amount: null,
      backorder: true,
      backorderParts: [...new Set(bo.map(partName))],
    })
  }

  const slips = new Map<string, SlipItem>()
  for (const e of events) {
    if (e.kind !== 'promise_slipped') continue
    const k = `${e.customer_key}|${e.order_id ?? ''}`
    const item = slips.get(k) ?? {
      key: `p|${k}`,
      customer_key: e.customer_key,
      customer_name: e.customer_name,
      order_id: e.order_id,
      occurred_on: e.occurred_on,
      lines: [],
    }
    if ((e.occurred_on ?? '') > (item.occurred_on ?? '')) item.occurred_on = e.occurred_on
    item.lines.push({ part: partName(e), before: e.promise_before, after: e.promise_after })
    slips.set(k, item)
  }

  return {
    shipped: shipped.sort(byDateDesc),
    newOrders: events.filter((e) => e.kind === 'order_new').sort(byDateDesc),
    headsUp: [...slips.values()].sort(byDateDesc),
  }
}

/* ------------------------------------------------- new since last looked */

/**
 * The feed is dated by day (an order date, a ship date, the night a change
 * was seen), so "new" is by day too: anything dated on or after the day of
 * the rep's previous look. A second look the same evening re-marks that
 * day's items; that over-marks once rather than ever hiding something the
 * nightly load brought in after the morning look.
 */
export function isNewSince(occurredOn: string | null, lastSeenIso: string | null): boolean {
  if (!occurredOn || !lastSeenIso) return false
  const seen = new Date(lastSeenIso)
  if (Number.isNaN(seen.getTime())) return false
  // The rep's own calendar day, not UTC's.
  return occurredOn.slice(0, 10) >= format(seen, 'yyyy-MM-dd')
}

const SEEN_PREFIX = 'rp:activity-seen:'

function readSeen(userId: string): string | null {
  try {
    return localStorage.getItem(SEEN_PREFIX + userId)
  } catch {
    return null
  }
}

function writeSeen(userId: string, iso: string): void {
  try {
    localStorage.setItem(SEEN_PREFIX + userId, iso)
  } catch {
    // Private mode or blocked storage: the marker just never shows.
  }
}

/**
 * The previous look, read once per mount (so the markers stay put while
 * the rep reads), and `markSeen()` to record this one. Per user id: a
 * shared truck iPad must not inherit the last rep's "new".
 */
export function useActivityLastSeen(userId: MaybeRefOrGetter<string | null | undefined>) {
  const uid = toValue(userId) ?? ''
  const previous = ref<string | null>(uid ? readSeen(uid) : null)
  let marked = false
  function markSeen() {
    if (marked || !uid) return
    marked = true
    writeSeen(uid, new Date().toISOString())
  }
  return { previous, markSeen }
}

/* ------------------------------------------------------------------ query */

export function useActivityFeed() {
  const events = useQuery({
    queryKey: activityKeys.feed(),
    staleTime: STALE_TIME,
    retry: (n, e) => !isMissingDbObject(e) && n < 1,
    queryFn: async (): Promise<ActivityEvent[]> => {
      const { data, error } = await db
        .from('v_territory_recent_events')
        .select('*') // unfiltered on purpose — RLS is the territory filter
        .order('occurred_on', { ascending: false, nullsFirst: false })
        .order('kind', { ascending: true })
        .order('order_id', { ascending: true })
        .limit(ACTIVITY_LIMIT)
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[])
        .map(mapActivityRow)
        .filter((e): e is ActivityEvent => e !== null)
    },
  })

  /** The migration isn't applied: show the orders-only card it replaced. */
  const usingFallback = computed(() => isMissingDbObject(events.error.value))

  const fallback = useQuery({
    queryKey: activityKeys.fallback(),
    enabled: usingFallback,
    staleTime: STALE_TIME,
    retry: (n, e) => !isMissingDbObject(e) && n < 1,
    queryFn: async (): Promise<ActivityEvent[]> => {
      const { data, error } = await db
        .from('v_territory_recent_orders')
        .select('*')
        .order('order_date', { ascending: false, nullsFirst: false })
        .limit(25)
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map(mapFallbackOrder)
    },
  })

  const active = computed(() => (usingFallback.value ? fallback : events))

  return {
    usingFallback,
    items: computed(() => active.value.data.value ?? []),
    // While the first read is still deciding whether to fall back, the
    // fallback is disabled and reads as pending — the skeleton stays up.
    isPending: computed(() => active.value.isPending.value),
    error: computed(() => active.value.error.value),
    hasData: computed(() => active.value.data.value !== undefined),
    updatedAt: computed(() => active.value.dataUpdatedAt.value),
    refetch: () => active.value.refetch(),
  }
}
