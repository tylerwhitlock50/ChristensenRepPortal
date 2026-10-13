import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { isMissingDbObject, supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { useAccountSearch, type AccountListRow } from '@/composables/useAccounts'
import { MIN_LOOKUP_LENGTH, useOrderLookup } from '@/composables/useOrderLookup'
import type { AtsRow } from '@/composables/useIntel'

/**
 * The header search: one box for the three things a rep is ever looking
 * for — a dealer, an order, a product — from any screen.
 *
 *   Dealers   the Accounts page's own server search (v_account_list:
 *             name, city or customer number), same query and cache
 *   Orders    lookup_orders() from 3 characters (PO, our order number,
 *             tracking), same query and cache as the Find page
 *   Products  in stock only, 5 at most: the ATS list when it is already
 *             cached (filtered here, no request), else a 5-row read
 *
 * Nothing runs until the sheet is open and something is typed; the caller
 * debounces the term. Ranking is pure and exported for unit tests.
 */

/** The ATS view postdates the generated types. */
const db = supabase as unknown as SupabaseClient

/** Dealers and products search from this many characters. */
export const MIN_SEARCH_LENGTH = 2
export const MAX_DEALERS = 6
export const MAX_ORDERS = 5
export const MAX_PRODUCTS = 5

/** Same guard as useAccountSearch: PostgREST's or=() is positional. */
export function sanitizeTerm(raw: string): string {
  return raw.trim().replace(/[,()"'\\*%]/g, '').slice(0, 80)
}

/**
 * The server returns matches A–Z; a rep typing "big" wants "Big Sky" before
 * "Abigail's". Exact customer number, then name prefix, then a word in the
 * name starting with it, then the rest (city or mid-word hits) — each band
 * keeps the server's order.
 */
export function rankDealers<T extends Pick<AccountListRow, 'customer_key' | 'customer_name'>>(
  rows: readonly T[],
  term: string,
): T[] {
  const q = term.trim().toLowerCase()
  if (!q) return [...rows]
  const band = (r: T): number => {
    const name = (r.customer_name ?? '').toLowerCase()
    if (r.customer_key.toLowerCase() === q) return 0
    if (name.startsWith(q)) return 1
    if (name.split(/[^a-z0-9]+/).some((w) => w.startsWith(q))) return 2
    return 3
  }
  return rows
    .map((r, i) => ({ r, i, b: band(r) }))
    .sort((a, b) => a.b - b.b || a.i - b.i)
    .map((x) => x.r)
}

export interface ProductHit {
  part_key: string
  part_id: string | null
  part_description: string | null
  product_family: string | null
  ats_qty: number
}

/** In-stock parts matching the term, most available first. Pure. */
export function filterProducts(rows: readonly AtsRow[], term: string, max = MAX_PRODUCTS): ProductHit[] {
  const q = term.trim().toLowerCase()
  if (!q) return []
  return rows
    .filter((r) => r.ats_qty > 0)
    .filter((r) =>
      [r.part_id, r.part_description, r.upc, r.product_family, r.chambering].some(
        (v) => (v ?? '').toLowerCase().includes(q),
      ),
    )
    .sort((a, b) => b.ats_qty - a.ats_qty || (a.part_id ?? '').localeCompare(b.part_id ?? ''))
    .slice(0, max)
    .map((r) => ({
      part_key: r.part_key,
      part_id: r.part_id,
      part_description: r.part_description,
      product_family: r.product_family,
      ats_qty: r.ats_qty,
    }))
}

export function useGlobalSearch(
  term: MaybeRefOrGetter<string>,
  open: MaybeRefOrGetter<boolean>,
) {
  const client = useQueryClient()
  const q = computed(() => (toValue(open) ? toValue(term).trim() : ''))
  const longEnough = computed(() => sanitizeTerm(q.value).length >= MIN_SEARCH_LENGTH)

  /* Dealers — every account, active or not: the rep searching a name wants
     to find it, and an inactive one says so on its row. */
  const dealersQuery = useAccountSearch(q, false, longEnough)
  const dealers = computed(() =>
    rankDealers(dealersQuery.data.value?.pages[0]?.rows ?? [], q.value).slice(0, MAX_DEALERS),
  )

  /* Orders — the Find page's lookup; it gates itself at 3 characters. */
  const ordersQuery = useOrderLookup(q)
  const orders = computed(() => (ordersQuery.data.value ?? []).slice(0, MAX_ORDERS))
  const ordersLongEnough = computed(() => q.value.length >= MIN_LOOKUP_LENGTH)

  /* Products — from the ATS list if Intel already loaded it this session,
     otherwise a 5-row read of in-stock parts. */
  const cachedAts = computed(() =>
    longEnough.value ? client.getQueryData<AtsRow[]>(qk.intel.ats()) : undefined,
  )
  const productsQuery = useQuery({
    queryKey: computed(() => ['global-search', 'products', sanitizeTerm(q.value)] as const),
    enabled: computed(() => longEnough.value && !cachedAts.value),
    // Nightly ERP data.
    staleTime: 10 * 60_000,
    retry: (n, e) => !isMissingDbObject(e) && n < 1,
    queryFn: async (): Promise<ProductHit[]> => {
      const t = sanitizeTerm(q.value)
      const { data, error } = await db
        .from('v_ats_list')
        .select('part_key, part_id, part_description, product_family, ats_qty')
        .gt('ats_qty', 0)
        .or(`part_id.ilike.*${t}*,part_description.ilike.*${t}*,upc.ilike.*${t}*`)
        .order('ats_qty', { ascending: false })
        .limit(MAX_PRODUCTS)
      if (error) throw error
      return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
        part_key: String(r.part_key),
        part_id: (r.part_id as string | null) ?? null,
        part_description: (r.part_description as string | null) ?? null,
        product_family: (r.product_family as string | null) ?? null,
        ats_qty: Number(r.ats_qty ?? 0) || 0,
      }))
    },
  })
  const products = computed(() =>
    cachedAts.value
      ? filterProducts(cachedAts.value, q.value)
      : (productsQuery.data.value ?? []),
  )

  /* With no signal (or in the offline open, where every request waits) a
     new search never starts: TanStack holds it 'paused' with isPending
     true, which read as "Searching…" for ever. Paused is not loading; the
     sheet says the search needs a signal instead. Products still filter
     the In stock list when this session (or the saved copy) has it. */
  const isPaused = (query: { fetchStatus: { value: string } }) =>
    query.fetchStatus.value === 'paused'
  const loading = (query: { isPending: { value: boolean }; fetchStatus: { value: string } }) =>
    query.isPending.value && !isPaused(query)

  return {
    q,
    longEnough,
    ordersLongEnough,
    /** A search was asked for and is waiting on a connection. */
    paused: computed(
      () =>
        (longEnough.value && isPaused(dealersQuery)) ||
        (ordersLongEnough.value && isPaused(ordersQuery)) ||
        (longEnough.value && !cachedAts.value && isPaused(productsQuery)),
    ),
    dealers,
    dealersLoading: computed(() => longEnough.value && loading(dealersQuery)),
    dealersError: computed(() => (longEnough.value ? dealersQuery.error.value : null)),
    orders,
    ordersLoading: computed(() => ordersLongEnough.value && loading(ordersQuery)),
    // A database without lookup_orders (035) just has no Orders group.
    ordersError: computed(() =>
      ordersLongEnough.value && !isMissingDbObject(ordersQuery.error.value)
        ? ordersQuery.error.value
        : null,
    ),
    products,
    productsLoading: computed(
      () => longEnough.value && !cachedAts.value && loading(productsQuery),
    ),
    productsError: computed(() =>
      longEnough.value && !cachedAts.value && !isMissingDbObject(productsQuery.error.value)
        ? productsQuery.error.value
        : null,
    ),
  }
}
