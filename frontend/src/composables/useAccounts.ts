import { computed, unref, type MaybeRef } from 'vue'
import { useInfiniteQuery, useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { erp, isSchemaNotExposed, supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { isViewMissing } from '@/composables/useAccountMetrics'
import type { DimCustomerRow } from '@/types/erp'

const LIST_COLUMNS =
  'customer_key, customer_name, sold_to_city, sold_to_state, assigned_sales_rep_id, assigned_sales_rep_name, territory, last_order_date, active_flag'

/**
 * The list reads public.v_account_list (migration 015), not erp.dim_customer:
 * same columns, but last_order_date is derived from order history instead of
 * the ERP's unmaintained CUSTOMER.LAST_ORDER_DATE field, which is NULL for
 * most accounts and made the list say "Last order never" for accounts with
 * plenty of orders. Untyped handle for the same reason as useAccountMetrics —
 * the view postdates the generated types.
 */
const db = supabase as unknown as SupabaseClient

export const ACCOUNTS_PAGE_SIZE = 50

/**
 * PostgREST parses `or=(a.ilike.*x*,b.ilike.*y*)` positionally, so a comma,
 * paren, or quote typed into the search box would corrupt the filter — or
 * change which columns it matches. Strip them rather than trying to quote.
 */
function sanitizeSearch(raw: string): string {
  return raw.trim().replace(/[,()"'\\*%]/g, '').slice(0, 80)
}

export interface AccountPage {
  rows: DimCustomerRow[]
  total: number
  page: number
}

/**
 * The account list, paged and searched **in Postgres**.
 *
 * Deliberately not a fetch-all-then-filter-client-side: an admin's book is
 * every customer in the ERP (41k+ rows at time of writing), and a client-side
 * filter behind a row limit silently truncates the list with no indication
 * that anything is missing.
 *
 * RLS still does the scoping — no owner filter is written here. A rep's
 * unscoped select returns exactly their book because has_account_access()
 * says so (TECH_STACK §3.1).
 */
export function useAccountSearch(
  search: MaybeRef<string>,
  activeOnly: MaybeRef<boolean>,
) {
  const term = computed(() => sanitizeSearch(unref(search)))
  const active = computed(() => unref(activeOnly))

  return useInfiniteQuery({
    queryKey: computed(
      () => [...qk.me.accounts(), { q: term.value, active: active.value }] as const,
    ),
    initialPageParam: 0,
    queryFn: async ({ pageParam }): Promise<AccountPage> => {
      const page = pageParam as number
      const from = page * ACCOUNTS_PAGE_SIZE

      const runPage = (relation: 'v_account_list' | 'dim_customer') => {
        const client =
          relation === 'v_account_list' ? db : (erp as unknown as SupabaseClient)
        // Built as one expression so the query-builder type doesn't need to be
        // re-narrowed on each conditional filter.
        const base = client.from(relation).select(LIST_COLUMNS, { count: 'exact' })
        const scoped = active.value ? base.eq('active_flag', 'Y') : base
        const filtered = term.value
          ? scoped.or(
              `customer_name.ilike.*${term.value}*,` +
                `customer_key.ilike.*${term.value}*,` +
                `sold_to_city.ilike.*${term.value}*`,
            )
          : scoped
        return filtered
          .order('customer_name', { ascending: true })
          .range(from, from + ACCOUNTS_PAGE_SIZE - 1)
      }

      let { data, error, count } = await runPage('v_account_list')
      if (error && isViewMissing(error)) {
        // 015 not applied yet — fall back to the raw ERP column so the page
        // keeps working; its last_order_date is just the stale field.
        ;({ data, error, count } = await runPage('dim_customer'))
      }
      if (error) throw error
      return {
        rows: (data ?? []) as unknown as DimCustomerRow[],
        total: count ?? 0,
        page,
      }
    },
    getNextPageParam: (last) =>
      last.rows.length === ACCOUNTS_PAGE_SIZE ? last.page + 1 : undefined,
    // The ETL lands this once a night.
    staleTime: 10 * 60_000,
  })
}

export function useAccount(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.detail(key.value)),
    enabled: computed(() => !!key.value),
    queryFn: async (): Promise<DimCustomerRow | null> => {
      const { data, error } = await erp
        .from('dim_customer')
        .select('*')
        .eq('customer_key', key.value)
        .maybeSingle()
      if (error) throw error
      return (data ?? null) as unknown as DimCustomerRow | null
    },
    staleTime: 10 * 60_000,
  })
}

/**
 * customer_key → customer_name for a set of keys, so lists that only carry
 * keys (recommendations, actions) can show a name.
 *
 * Degrades on purpose: if `erp` isn't exposed to PostgREST yet, this resolves
 * to an empty map instead of erroring, and callers fall back to the key. A
 * missing display name must never take down the to-do list.
 */
export function useAccountNames(keys: MaybeRef<string[]>) {
  const list = computed(() => [...new Set(unref(keys))].sort())
  return useQuery({
    queryKey: computed(() => ['account-names', list.value] as const),
    enabled: computed(() => list.value.length > 0),
    staleTime: 10 * 60_000,
    queryFn: async (): Promise<Record<string, string>> => {
      const { data, error } = await erp
        .from('dim_customer')
        .select('customer_key, customer_name')
        .in('customer_key', list.value)
      if (error) {
        if (isSchemaNotExposed(error)) return {}
        throw error
      }
      const map: Record<string, string> = {}
      for (const row of (data ?? []) as { customer_key: string; customer_name: string | null }[]) {
        if (row.customer_name) map[row.customer_key] = row.customer_name
      }
      return map
    },
  })
}
