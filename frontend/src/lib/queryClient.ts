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
 * This is the only place query keys are defined. Four composables used to keep
 * their own byte-identical copies (useVisits, useAiSummary, useAccountMetrics,
 * useTasks) because they were written before this file could be edited; they
 * now all import from here. Keep it that way — a key that drifts out of sync
 * does not throw, it just stops matching, and the symptom is a write that
 * silently leaves stale data on screen.
 */
export const qk = {
  me: {
    needsAttention: () => ['me', 'needs-attention'] as const,
    accounts: () => ['me', 'accounts'] as const,
    activity: () => ['me', 'activity'] as const,
    /**
     * Headlines for the accounts currently on screen — a batch read for the
     * Today cards, so it is keyed by the visible set rather than by account.
     * Callers must pass a de-duplicated, sorted list or the same set of
     * accounts in a different order becomes a second cache entry.
     */
    aiHeadlines: (keys: string[]) => ['me', 'ai-headlines', keys] as const,
  },
  account: {
    root: (key: string) => ['account', key] as const,
    detail: (key: string) => ['account', key, 'detail'] as const,
    recommendations: (key: string) => ['account', key, 'recommendations'] as const,
    orders: (key: string) => ['account', key, 'orders'] as const,
    invoices: (key: string) => ['account', key, 'invoices'] as const,
    shipments: (key: string) => ['account', key, 'shipments'] as const,
    /**
     * The drill-in modals. Deliberately suffixes of `.orders` / `.shipments`
     * so invalidating the header list also drops the line detail behind it —
     * lines that outlive their header would show a modal contradicting the
     * card that opened it.
     */
    orderLines: (key: string, orderId: string) =>
      ['account', key, 'orders', orderId] as const,
    shipmentLines: (key: string, packlistId: string) =>
      ['account', key, 'shipments', packlistId] as const,
    notes: (key: string) => ['account', key, 'notes'] as const,
    contacts: (key: string) => ['account', key, 'contacts'] as const,
    activity: (key: string) => ['account', key, 'activity'] as const,
    visits: (key: string) => ['account', key, 'visits'] as const,
    photos: (key: string) => ['account', key, 'photos'] as const,
    aiSummary: (key: string) => ['account', key, 'ai-summary'] as const,
    status: (key: string) => ['account', key, 'status'] as const,
    summary: (key: string) => ['account', key, 'summary'] as const,
    revenueMonthly: (key: string) => ['account', key, 'revenue-monthly'] as const,
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
