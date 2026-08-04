import { QueryClient } from '@tanstack/vue-query'

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
  admin: {
    execution: () => ['admin', 'execution'] as const,
    coverage: (range: { from: string; to: string }) =>
      ['admin', 'coverage', range] as const,
    users: () => ['admin', 'users'] as const,
    missions: () => ['admin', 'missions'] as const,
    missionDetail: (batchId: number) => ['admin', 'missions', batchId] as const,
    activity: () => ['admin', 'activity'] as const,
    salesReps: () => ['admin', 'sales-reps'] as const,
    scoreSettings: () => ['admin', 'score-settings'] as const,
    rules: () => ['admin', 'rules'] as const,
  },
} as const

export const queryClient = new QueryClient({
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
