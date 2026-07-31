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
 */
export const qk = {
  me: {
    needsAttention: () => ['me', 'needs-attention'] as const,
    accounts: () => ['me', 'accounts'] as const,
    activity: () => ['me', 'activity'] as const,
  },
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
  },
  admin: {
    execution: () => ['admin', 'execution'] as const,
    coverage: (range: { from: string; to: string }) =>
      ['admin', 'coverage', range] as const,
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
