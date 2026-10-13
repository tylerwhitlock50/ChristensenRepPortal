import { unref } from 'vue'
import { QueryClient, type QueryKey } from '@tanstack/vue-query'

/**
 * Query key convention (TECH_STACK §2.3) — flat and explicit so invalidation
 * after a write is one line:
 *
 *   ['account', customerKey]
 *   ['account', customerKey, 'orders']
 *   ['account', customerKey, 'recommendations']
 *   ['me', 'needs-attention']
 *   ['admin', 'coverage', { from, to }]
 *
 * Everything under `account` is a suffix of `qk.account.root(key)`, so one
 * `invalidateQueries({ queryKey: qk.account.root(key) })` after a write clears
 * the whole account page — summary, revenue, visits, the AI summary, the lot.
 *
 * DUPLICATES, ON PURPOSE (for now): several feature composables were written
 * before this registry could be edited and define their own identical copies.
 * They are the ones actually in use; the entries here are the canonical shape
 * and must stay byte-identical to them:
 *
 *   qk.account.visits        = visitsQueryKey()      src/composables/useVisits.ts
 *   qk.account.summary       ┐ accountMetricsKeys    src/composables/useAccountMetrics.ts
 *   qk.account.revenueMonthly┘ (also reuses .orders / .shipments below)
 *   qk.tasks.*               = taskKeys              src/composables/useTasks.ts
 *
 * When one of those files is next touched, re-point it at `qk` and delete its
 * local const. Changing a key here without changing it there breaks
 * invalidation silently, so change both or neither.
 */
export const qk = {
  me: {
    needsAttention: () => ['me', 'needs-attention'] as const,
    accounts: () => ['me', 'accounts'] as const,
    activity: () => ['me', 'activity'] as const,
  },
  /** Feature flags (public.app_settings). One list, long staleTime. */
  settings: () => ['app-settings'] as const,
  /** "As of / Data through" stamp (public.v_data_freshness). */
  freshness: () => ['data-freshness'] as const,
  /**
   * Territory-scoped intel — the Overview and the Sales Intel section.
   * These are the caller's whole book (RLS is the filter), so they carry no
   * account key. Account-scoped intel lives under `account` below so the
   * root-invalidation sweep covers it.
   */
  intel: {
    territoryYoy: () => ['intel', 'territory-yoy'] as const,
    territoryRecentOrders: () => ['intel', 'territory-recent-orders'] as const,
    territorySku: () => ['intel', 'territory-sku'] as const,
    backlog: () => ['intel', 'backlog'] as const,
    ats: () => ['intel', 'ats'] as const,
    global: (months: number) => ['intel', 'global', months] as const,
    /** public.account_signals across the book — the nightly behaviour scores. */
    signals: () => ['intel', 'signals'] as const,
  },
  /** Cached AI Action output (public.ai_briefs). subject '' = territory. */
  aiBrief: (action: string, subject = '') =>
    ['ai-brief', action, subject] as const,
  account: {
    root: (key: string) => ['account', key] as const,
    detail: (key: string) => ['account', key, 'detail'] as const,
    recommendations: (key: string) => ['account', key, 'recommendations'] as const,
    orders: (key: string) => ['account', key, 'orders'] as const,
    invoices: (key: string) => ['account', key, 'invoices'] as const,
    shipments: (key: string) => ['account', key, 'shipments'] as const,
    notes: (key: string) => ['account', key, 'notes'] as const,
    contacts: (key: string) => ['account', key, 'contacts'] as const,
    activity: (key: string) => ['account', key, 'activity'] as const,
    visits: (key: string) => ['account', key, 'visits'] as const,
    photos: (key: string) => ['account', key, 'photos'] as const,
    aiSummary: (key: string) => ['account', key, 'ai-summary'] as const,
    status: (key: string) => ['account', key, 'status'] as const,
    summary: (key: string) => ['account', key, 'summary'] as const,
    revenueMonthly: (key: string) => ['account', key, 'revenue-monthly'] as const,
    skuSales: (key: string) => ['account', key, 'sku-sales'] as const,
    backlogSku: (key: string) => ['account', key, 'backlog-sku'] as const,
    goal: (key: string) => ['account', key, 'goal'] as const,
    signals: (key: string) => ['account', key, 'signals'] as const,
    skuGaps: (key: string) => ['account', key, 'sku-gaps'] as const,
  },
  /**
   * Rep-entered account goals (migration 023). The per-account read lives
   * under `qk.account.goal` so account-root invalidation still sweeps it;
   * these are the book-wide reads, which no account key covers.
   */
  goals: {
    root: () => ['goals'] as const,
    forAccounts: (year: number, keys: string[]) =>
      ['goals', 'accounts', year, keys] as const,
    behind: (year: number) => ['goals', 'behind', year] as const,
    rollup: (year: number) => ['goals', 'rollup', year] as const,
  },
  /**
   * Personal follow-ups. Scoped by user id so signing in as someone else on a
   * shared truck iPad can't read the previous rep's cached list.
   */
  tasks: {
    root: () => ['tasks'] as const,
    mine: (userId: string) => ['tasks', 'mine', userId] as const,
    due: (userId: string) => ['tasks', 'due', userId] as const,
    closed: (userId: string) => ['tasks', 'closed', userId] as const,
    forAccount: (userId: string, key: string) =>
      ['tasks', 'account', userId, key] as const,
  },
  /**
   * Published price lists (20260817000100): the downloadable approved
   * sheets and the structured lists the order writer sells from. Global,
   * not account-scoped — every rep reads the same lists.
   */
  priceLists: {
    root: () => ['price-lists'] as const,
    files: () => ['price-lists', 'files'] as const,
    lists: () => ['price-lists', 'lists'] as const,
    items: (listId: number) => ['price-lists', 'items', listId] as const,
    effective: (customerType: string) =>
      ['price-lists', 'effective', customerType] as const,
  },
  /**
   * Portal-written orders (20260817000200). List reads are scoped by user
   * id for the same shared-truck-iPad reason as `tasks`; the queue is the
   * entry/admin view over everyone's post-draft orders.
   */
  orders: {
    root: () => ['orders'] as const,
    list: (userId: string) => ['orders', 'list', userId] as const,
    detail: (id: number) => ['orders', 'detail', id] as const,
    queue: () => ['orders', 'queue'] as const,
  },
  admin: {
    execution: () => ['admin', 'execution'] as const,
    goals: () => ['admin', 'goals'] as const,
    coverage: (range: { from: string; to: string }) =>
      ['admin', 'coverage', range] as const,
    users: () => ['admin', 'users'] as const,
    missions: () => ['admin', 'missions'] as const,
    missionDetail: (batchId: number) => ['admin', 'missions', batchId] as const,
    activity: () => ['admin', 'activity'] as const,
    salesReps: () => ['admin', 'sales-reps'] as const,
    scoreSettings: () => ['admin', 'score-settings'] as const,
    rules: () => ['admin', 'rules'] as const,
    repGoals: () => ['admin', 'rep-goals'] as const,
    /** Reports tab (20260816120000): channel and rep-group rollups. */
    channels: () => ['admin', 'channels'] as const,
    repGroupPerformance: () => ['admin', 'rep-group-performance'] as const,
  },
} as const

/* -------------------------------------------------------------------------
 * ERP reads: cached by the nightly load, not by a timer.
 *
 * Everything the ETL lands changes once a night, so treating it as volatile
 * (a short staleTime, a refetch every time the rep comes back to the app)
 * spent 6-16 requests per return on numbers that could not have moved.
 * Instead:
 *
 *   - ERP queries stay fresh for ERP_STALE_TIME and are NOT refetched on
 *     window focus.
 *   - useErpHeartbeat (useDataFreshness.ts) checks v_data_freshness on
 *     focus and every 15 minutes; when the load stamp or a data horizon
 *     moves (freshnessStamp) it invalidates every query isErpQueryKey()
 *     matches. Coming back to the app costs that one tiny request.
 *   - Their gcTime is 24 hours so the persisted cache (queryPersist.ts) can
 *     hold them that long.
 *
 * Hours, not Infinity: the rows don't change during the day, but WHOSE rows
 * they are can — an admin reassigning an account changes my_customer_keys()
 * with no ETL run to announce it. A few hours bounds how long a reassigned
 * account keeps showing.
 *
 * isErpQueryKey() is deliberately an allow-list, checked against what each
 * query actually reads. Not on it, on purpose: goals (rep-written), the
 * accounts list and table (v_account_table joins rep goals and
 * deactivations), contacts (rep-entered rows), the admin reports (they join
 * account_goals, actions and profiles), AI output, and data-freshness itself
 * (it is the heartbeat). Also off: ['intel', 'sku-prospects', …] (it reads
 * v_account_list for names and deactivations), AI feedback, call-list
 * reactions and deactivations (['call-list', …]), and the header search.
 * A new key is NOT ERP until it is added here.
 * ------------------------------------------------------------------------- */

export const ERP_STALE_TIME = 3 * 60 * 60_000
export const ERP_GC_TIME = 24 * 60 * 60_000

/** ['intel', <one of these>, …] — the caller's whole book, all ETL-landed. */
const ERP_INTEL_KEYS = new Set([
  'territory-yoy', //          v_territory_account_yoy (dim_customer + agg_account_rollup)
  'territory-recent-orders', // v_territory_recent_orders (fact_order_line)
  'territory-sku', //          v_territory_sku_sales
  'backlog', //                v_backlog_by_sku
  'ats', //                    v_ats_list
  'global', //                 report_global_product_sales()
  'signals', //                account_signals (rebuilt by the ETL's post-load step)
  'call-list', //              account_signals top of the ranking (useCallList)
  'territory-recent-events', // v_territory_recent_events: facts + the ETL's order_change_events
  //                            (+ its fallback, v_territory_recent_orders)
])

/** ['account', <key>, <one of these>, …] */
const ERP_ACCOUNT_KEYS = new Set([
  'detail', //          erp.dim_customer
  'summary', //         v_account_summary
  'revenue-monthly', // v_account_revenue_monthly
  'orders', //          v_account_recent_order_headers (+ lines under it)
  'shipments', //       v_account_recent_shipment_headers (+ lines under it)
  'sku-sales', //       v_sku_sales_by_account
  'backlog-sku', //     v_backlog_by_sku
  'signals', //         account_signals
  'sku-gaps', //        report_account_sku_gaps()
  'reorders', //        report_reorder_candidates()
])

/** True for a query whose data only changes when the nightly ETL runs. */
export function isErpQueryKey(queryKey: readonly unknown[]): boolean {
  const [root, second, third] = queryKey.map((part) => unref(part))
  if (root === 'intel') return ERP_INTEL_KEYS.has(second as string)
  if (root === 'account') {
    return typeof second === 'string' && ERP_ACCOUNT_KEYS.has(third as string)
  }
  return false
}

/** The three columns of public.v_data_freshness that version the ERP cache. */
export interface FreshnessStampFields {
  data_loaded_at?: string | null
  data_through?: string | null
  orders_through?: string | null
}

/**
 * The version of the ERP cache: what useErpHeartbeat watches, and what a
 * late cache restore compares (queryPersist.ts). A change means new ERP data
 * landed, so every isErpQueryKey() query is invalidated.
 *
 * data_loaded_at alone is not enough. It is the last FULLY successful run,
 * and the ETL also rebuilds the rollups and signals on a night when only a
 * table nothing downstream reads failed (etl/views.yml post_load_requires).
 * That night's etl:run is an error, so data_loaded_at stays put while new
 * facts and rollups land. The two data horizons (newest invoice, newest
 * order) move with the facts, so the stamp is all three. At worst a horizon
 * steps onto a future-dated row at midnight with no load: one extra refetch.
 *
 * undefined when there is no row yet (not loaded), so "not loaded" is never
 * mistaken for a stamp. A null column is part of the stamp: a cleared
 * data_loaded_at is a change like any other.
 */
export function freshnessStamp(
  row: FreshnessStampFields | null | undefined,
): string | undefined {
  if (row === undefined || row === null) return undefined
  return JSON.stringify([
    row.data_loaded_at ?? null,
    row.data_through ?? null,
    row.orders_through ?? null,
  ])
}

const ERP_QUERY_DEFAULTS = {
  staleTime: ERP_STALE_TIME,
  gcTime: ERP_GC_TIME,
  refetchOnWindowFocus: false,
} as const

/**
 * Applies ERP_QUERY_DEFAULTS by key. They slot in where setQueryDefaults()
 * values do — over the client-wide defaults below, under whatever a query
 * passes itself — so a composable's explicit staleTime still wins. That
 * slot is the reason for a subclass: setQueryDefaults() matches key
 * prefixes, and ['account', <any key>, 'summary'] is not a prefix.
 */
class RepPortalQueryClient extends QueryClient {
  override getQueryDefaults(queryKey: Parameters<QueryClient['getQueryDefaults']>[0]) {
    const defaults = super.getQueryDefaults(queryKey)
    const key = unref(queryKey) as QueryKey | undefined
    return Array.isArray(key) && isErpQueryKey(key)
      ? { ...ERP_QUERY_DEFAULTS, ...defaults }
      : defaults
  }
}

export const queryClient = new RepPortalQueryClient({
  defaultOptions: {
    queries: {
      // ERP data only changes once a night; app data changes when the rep acts
      // on it, and those paths invalidate explicitly. A minute of staleness
      // saves a lot of round trips on LTE.
      staleTime: 60_000,
      gcTime: 15 * 60_000,
      // The rep leaves for a call and comes back — show them fresh data.
      refetchOnWindowFocus: true,
      refetchOnReconnect: true,
      // One retry. Bad signal deserves a second chance; a 403 from RLS does
      // not deserve four.
      retry: 1,
    },
    mutations: {
      retry: 0,
    },
  },
})
