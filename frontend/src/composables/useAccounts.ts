import { computed, unref, type MaybeRef } from 'vue'
import { useInfiniteQuery, useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { erp, isSchemaNotExposed, supabase } from '@/lib/supabase'
import { fetchAllRows } from '@/lib/fetchAll'
import { qk } from '@/lib/queryClient'
import { isViewMissing } from '@/composables/useAccountMetrics'
import type { DimCustomerRow } from '@/types/erp'

const LIST_COLUMNS =
  'customer_key, customer_name, sold_to_city, sold_to_state, assigned_sales_rep_id, assigned_sales_rep_name, territory, last_order_date, active_flag'

/**
 * The view carries the portal deactivation columns (migration 023); the raw
 * dim_customer fallback below cannot. That's fine: the fallback only runs
 * when 015 isn't applied, and 023 can't be applied without 015, so on that
 * path there are no deactivations to filter either.
 */
const VIEW_COLUMNS = `${LIST_COLUMNS}, deactivated_at, deactivation_reason`

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

/** A v_account_list row: dim_customer identity plus the open deactivation. */
export type AccountListRow = DimCustomerRow & {
  deactivated_at?: string | null
  deactivation_reason?: string | null
}

export interface AccountPage {
  rows: AccountListRow[]
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
  /** Gate for pages with another mode (AccountsView's table) — a search
      keystroke must not cost server round trips for a list not rendered. */
  enabled: MaybeRef<boolean> = true,
) {
  const term = computed(() => sanitizeSearch(unref(search)))
  const active = computed(() => unref(activeOnly))

  return useInfiniteQuery({
    queryKey: computed(
      () => [...qk.me.accounts(), { q: term.value, active: active.value }] as const,
    ),
    enabled: computed(() => unref(enabled)),
    initialPageParam: 0,
    queryFn: async ({ pageParam }): Promise<AccountPage> => {
      const page = pageParam as number
      const from = page * ACCOUNTS_PAGE_SIZE

      const runPage = (relation: 'v_account_list' | 'dim_customer') => {
        const isView = relation === 'v_account_list'
        const client = isView ? db : (erp as unknown as SupabaseClient)
        // Built as one expression so the query-builder type doesn't need to be
        // re-narrowed on each conditional filter.
        const base = client
          .from(relation)
          .select(isView ? VIEW_COLUMNS : LIST_COLUMNS, { count: 'exact' })
        // "Active" = active in the ERP and not written off by the rep (023).
        const scoped = active.value
          ? isView
            ? base.eq('active_flag', 'Y').is('deactivated_at', null)
            : base.eq('active_flag', 'Y')
          : base
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
        rows: (data ?? []) as unknown as AccountListRow[],
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

/* ---- table mode ---------------------------------------------------------
   The accounts page's column view reads public.v_account_table
   (20260901000100): identity + the nightly rollup's ship/booking windows +
   the current-year goal, one row per account, no fact-table scans. Fetched
   WHOLE (fetchAllRows) rather than paged: sorting a metric column over a
   page of 50 would silently rank only the 50 that happened to load, and a
   rep's book is a few hundred rows at most. An admin's ~41k is the known
   cost of this v1 — the active-only server filter carries most of it.
------------------------------------------------------------------------- */

export interface AccountTableRow {
  customer_key: string
  customer_name: string | null
  sold_to_city: string | null
  sold_to_state: string | null
  active_flag: string | null
  assigned_sales_rep_name: string | null
  last_order_date: string | null
  last_invoice_date: string | null
  revenue_ytd: number
  revenue_prior_ytd: number
  revenue_prior_full: number
  bookings_ytd: number
  bookings_prior_ytd: number
  open_order_value: number
  open_order_count: number
  goal_amount: number | null
  goal_source: string | null
  attainment_pct: number | null
  on_track: boolean | null
  deactivated_at: string | null
}

function tableNum(value: unknown): number {
  const n = Number(value)
  return Number.isFinite(n) ? n : 0
}

export function useAccountTable(
  activeOnly: MaybeRef<boolean>,
  enabled: MaybeRef<boolean>,
) {
  const active = computed(() => unref(activeOnly))
  const on = computed(() => unref(enabled))
  return useQuery({
    queryKey: computed(
      () => [...qk.me.accounts(), 'table', { active: active.value }] as const,
    ),
    enabled: on,
    staleTime: 10 * 60_000,
    queryFn: async (): Promise<AccountTableRow[]> => {
      const rows = await fetchAllRows<Record<string, unknown>>((from, to) => {
        const base = db
          .from('v_account_table')
          // Explicit columns, not '*': the mapper below is the contract, and
          // over an admin's ~20k rows every stray column is real payload.
          .select(
            'customer_key, customer_name, sold_to_city, sold_to_state, ' +
              'active_flag, assigned_sales_rep_name, last_order_date, ' +
              'last_invoice_date, revenue_ytd, revenue_prior_ytd, ' +
              'revenue_prior_full, bookings_ytd, bookings_prior_ytd, ' +
              'open_order_value, open_order_count, goal_amount, goal_source, ' +
              'attainment_pct, on_track, deactivated_at',
            { count: 'exact' },
          )
        const scoped = active.value
          ? base.eq('active_flag', 'Y').is('deactivated_at', null)
          : base
        return scoped
          .order('customer_name', { ascending: true })
          .order('customer_key') // unique tiebreak — fetchAllRows contract
          .range(from, to)
          // The explicit column list defeats supabase-js's string-parsing
          // of select() on this untyped handle; assert the row shape the
          // mapper below consumes.
          .returns<Record<string, unknown>[]>()
      })
      return rows.map((r) => ({
        customer_key: String(r.customer_key),
        customer_name: (r.customer_name as string | null) ?? null,
        sold_to_city: (r.sold_to_city as string | null) ?? null,
        sold_to_state: (r.sold_to_state as string | null) ?? null,
        active_flag: (r.active_flag as string | null) ?? null,
        assigned_sales_rep_name:
          (r.assigned_sales_rep_name as string | null) ?? null,
        last_order_date: (r.last_order_date as string | null) ?? null,
        last_invoice_date: (r.last_invoice_date as string | null) ?? null,
        revenue_ytd: tableNum(r.revenue_ytd),
        revenue_prior_ytd: tableNum(r.revenue_prior_ytd),
        revenue_prior_full: tableNum(r.revenue_prior_full),
        bookings_ytd: tableNum(r.bookings_ytd),
        bookings_prior_ytd: tableNum(r.bookings_prior_ytd),
        open_order_value: tableNum(r.open_order_value),
        open_order_count: tableNum(r.open_order_count),
        goal_amount: r.goal_amount == null ? null : tableNum(r.goal_amount),
        goal_source: (r.goal_source as string | null) ?? null,
        attainment_pct:
          r.attainment_pct == null ? null : tableNum(r.attainment_pct),
        on_track: (r.on_track as boolean | null) ?? null,
        deactivated_at: (r.deactivated_at as string | null) ?? null,
      }))
    },
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
