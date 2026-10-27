import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { erp, isMissingDbObject, supabase } from '@/lib/supabase'

/**
 * "Who should I call about this?" — the reverse of the account page's
 * Ready-to-ship card: given a SKU that is in stock, the dealers in the
 * caller's book who have bought it.
 *
 * Reads public.v_sku_sales_by_account by part_key: security_invoker over
 * erp.agg_sku_year (current + 3 prior years), whose RLS is
 * my_customer_keys() — view-as aware — so the answer is exactly the
 * caller's book with no filter here. 20261013140002 gives agg_sku_year a
 * part-first index for this read. The MCP tool find_dealers_for_sku takes
 * the same path.
 *
 * When nobody in the book bought that exact part, it falls back to dealers
 * who bought the same family and chambering (or whichever of the two the
 * part has), and says so — "nobody took the 24-inch, these four took other
 * Mesa 6.5 Creedmoors" is still the right call list.
 */

/** v_sku_sales_by_account predates the generated types. */
const db = supabase as unknown as SupabaseClient

/**
 * What the list is for. 'call' (the In stock list): dealers worth ringing, so
 * accounts the rep has stopped working are left off — and counted, so an
 * empty list can say why. 'buyers' (SKU Sales): everyone in the book who
 * bought it, the same population as the SKU row it opens from, with the
 * stopped ones marked rather than dropped.
 */
export type ProspectPurpose = 'call' | 'buyers'

/** Territory-scoped (no account key): every dealer in the caller's book. The
 *  purpose is in the key — the two lists differ for the same part. */
export const skuProspectsKey = (partKey: string, purpose: ProspectPurpose = 'call') =>
  ['intel', 'sku-prospects', partKey, purpose] as const

/** The listed dealers; `more` says how many were left off. */
const MAX_DEALERS = 25
/** Rows read for the family fallback — an admin's whole-company book is big. */
const FALLBACK_ROW_CAP = 5000

export interface ProspectPart {
  part_key: string
  part_id: string | null
  part_description: string | null
  product_family: string | null
  chambering: string | null
}

export interface SkuProspect {
  customer_key: string
  customer_name: string | null
  city: string | null
  state: string | null
  /** The account's assigned rep — a principal's book spans several. */
  repName: string | null
  /** The rep deactivated it (account_deactivations) — only ever listed for
   *  the 'buyers' purpose. */
  deactivated: boolean
  /** Most recent calendar year with a purchase, and the units that year. */
  lastYear: number
  unitsLastYear: number
  /** Units over the four-year window. */
  totalUnits: number
  lastInvoiceDate: string | null
}

export interface SkuProspects {
  /** 'exact' = bought this part; 'similar' = same family / chambering. */
  match: 'exact' | 'similar' | 'none'
  dealers: SkuProspect[]
  /** Dealers beyond MAX_DEALERS. */
  more: number
  /** Buyers of this exact part left off because the rep stopped working
   *  them ('call' only) — so "nobody bought this" is never said of them. */
  hidden: number
}

type SaleRow = {
  customer_key: string
  sales_year: number
  qty: number
  last_invoice_date: string | null
}

/** dim_part uses blank or 'N/A' where a spec does not apply. */
function realSpec(value: string | null | undefined): string | null {
  const v = (value ?? '').trim()
  return v && v.toUpperCase() !== 'N/A' ? v : null
}

/**
 * Sales rows → one entry per dealer, most recent buyer first. Returns
 * (qty <= 0) are not purchases. Pure and exported for unit tests.
 */
export type RankedProspect = Omit<SkuProspect, 'customer_name' | 'city' | 'state' | 'repName' | 'deactivated'>

export function rankProspects(rows: SaleRow[]): RankedProspect[] {
  const byDealer = new Map<string, RankedProspect>()
  for (const r of rows) {
    const qty = Number(r.qty ?? 0)
    if (!(qty > 0)) continue
    const year = Number(r.sales_year)
    const d = byDealer.get(r.customer_key) ?? {
      customer_key: r.customer_key,
      lastYear: year,
      unitsLastYear: 0,
      totalUnits: 0,
      lastInvoiceDate: null,
    }
    if (year > d.lastYear) {
      d.lastYear = year
      d.unitsLastYear = 0
    }
    if (year === d.lastYear) d.unitsLastYear += qty
    d.totalUnits += qty
    if (r.last_invoice_date && (!d.lastInvoiceDate || r.last_invoice_date > d.lastInvoiceDate)) {
      d.lastInvoiceDate = r.last_invoice_date
    }
    byDealer.set(r.customer_key, d)
  }
  return [...byDealer.values()].sort(
    (a, b) =>
      (b.lastInvoiceDate ?? '').localeCompare(a.lastInvoiceDate ?? '') ||
      b.totalUnits - a.totalUnits ||
      a.customer_key.localeCompare(b.customer_key),
  )
}

const SALE_COLUMNS = 'customer_key, part_key, sales_year, qty, last_invoice_date'

/** Pages an equality-filtered read of the view under a row cap. */
async function readSales(filters: Record<string, string>): Promise<SaleRow[]> {
  const out: SaleRow[] = []
  for (let from = 0; from < FALLBACK_ROW_CAP; from += 1000) {
    let q = db.from('v_sku_sales_by_account').select(SALE_COLUMNS)
    for (const [column, value] of Object.entries(filters)) q = q.eq(column, value)
    const { data, error } = await q
      // (customer_key, part_key, sales_year) is the view's grain: a total order.
      .order('customer_key')
      .order('part_key')
      .order('sales_year')
      .range(from, from + 999)
    if (error) throw error
    const batch = (data ?? []) as SaleRow[]
    out.push(...batch)
    if (batch.length < 1000) break
  }
  return out
}

/** One v_account_list row, as far as this file reads it. */
export type ProspectAccount = Record<string, unknown>

/**
 * Ranked buyers → the dealers to list, joined to their account rows. An
 * account missing from the list view (not readable as an account), no
 * longer active in the ERP, or internal (internal_customer_flag 'Y' — the
 * territory views leave those out, 029) is skipped for every purpose; one
 * the rep deactivated is skipped and counted for 'call', kept and marked
 * for 'buyers'. Stops at MAX_DEALERS. Pure and exported for unit tests.
 */
export function listProspects(
  candidates: RankedProspect[],
  accounts: Map<string, ProspectAccount>,
  purpose: ProspectPurpose,
): { dealers: SkuProspect[]; used: number; hidden: number } {
  const dealers: SkuProspect[] = []
  let used = 0
  let hidden = 0
  for (const d of candidates) {
    used += 1
    const a = accounts.get(d.customer_key)
    if (!a || a.active_flag !== 'Y' || a.internal_customer_flag === 'Y') continue
    const deactivated = !!a.deactivated_at
    if (deactivated && purpose === 'call') {
      hidden += 1
      continue
    }
    dealers.push({
      ...d,
      customer_name: (a.customer_name as string | null) ?? null,
      city: (a.sold_to_city as string | null) ?? null,
      state: (a.sold_to_state as string | null) ?? null,
      repName:
        (a.assigned_sales_rep_name as string | null) ??
        (a.assigned_sales_rep_id as string | null) ??
        null,
      deactivated,
    })
    if (dealers.length === MAX_DEALERS) break
  }
  return { dealers, used, hidden }
}

export function useSkuProspects(
  part: MaybeRefOrGetter<ProspectPart | null>,
  purposeIn: MaybeRefOrGetter<ProspectPurpose> = 'call',
) {
  const current = computed(() => toValue(part))
  const partKey = computed(() => current.value?.part_key ?? '')
  const purpose = computed(() => toValue(purposeIn))

  /** Ranked buyers → listed dealers, reading names for a few extra keys so
   *  skipping inactive ones still fills the list. */
  async function list(ranked: RankedProspect[]) {
    if (ranked.length === 0) return { dealers: [], used: 0, hidden: 0 }
    const candidates = ranked.slice(0, MAX_DEALERS + 15)
    const keys = candidates.map((d) => d.customer_key)
    // v_account_list has the names and deactivations but not the internal
    // flag; dim_customer has it. Side by side, same keys, same RLS.
    const [list, flags] = await Promise.all([
      db
        .from('v_account_list')
        .select(
          'customer_key, customer_name, sold_to_city, sold_to_state, assigned_sales_rep_id, assigned_sales_rep_name, active_flag, deactivated_at',
        )
        .in('customer_key', keys),
      erp.from('dim_customer').select('customer_key, internal_customer_flag').in('customer_key', keys),
    ])
    if (list.error) throw list.error
    if (flags.error) throw flags.error
    const internal = new Map(
      ((flags.data ?? []) as Record<string, unknown>[]).map((c) => [
        String(c.customer_key),
        c.internal_customer_flag,
      ]),
    )
    const accounts = new Map(
      ((list.data ?? []) as ProspectAccount[]).map((a) => [
        String(a.customer_key),
        { ...a, internal_customer_flag: internal.get(String(a.customer_key)) ?? null },
      ]),
    )
    return listProspects(candidates, accounts, purpose.value)
  }

  const query = useQuery({
    queryKey: computed(() => skuProspectsKey(partKey.value, purpose.value)),
    enabled: computed(() => !!partKey.value),
    staleTime: 10 * 60_000,
    retry: (failureCount, error) => !isMissingDbObject(error) && failureCount < 1,
    queryFn: async (): Promise<SkuProspects> => {
      const p = current.value!
      let ranked = rankProspects(await readSales({ part_key: p.part_key }))
      let match: SkuProspects['match'] = 'exact'
      let picked = await list(ranked)
      // Counted from the exact part only: "nobody bought THIS" is the claim
      // it protects.
      const hidden = picked.hidden

      // The fallback is decided AFTER the account filter: an exact buyer
      // that was skipped must not block "these bought other <family>".
      const family = realSpec(p.product_family)
      const chambering = realSpec(p.chambering)
      if (picked.dealers.length === 0 && (family || chambering)) {
        const similar = rankProspects(
          await readSales({
            ...(family ? { product_family: family } : {}),
            ...(chambering ? { chambering } : {}),
          }),
        )
        const similarPicked = await list(similar)
        if (similarPicked.dealers.length > 0) {
          match = 'similar'
          ranked = similar
          picked = similarPicked
        }
      }
      if (picked.dealers.length === 0) return { match: 'none', dealers: [], more: 0, hidden }
      return {
        match,
        dealers: picked.dealers,
        // Not checked for activity, so "about".
        more: Math.max(0, ranked.length - picked.used),
        hidden,
      }
    },
  })

  return { ...query, unavailable: computed(() => isMissingDbObject(query.error.value)) }
}
