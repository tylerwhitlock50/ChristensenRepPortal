import { computed } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk, queryClient } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'
import { useMyMcpOrderAccess } from '@/composables/useMcpOrderUsers'
import {
  isMcpOrdersUserAllowed,
  parseMcpOrdersParams,
  type McpOrdersParams,
} from '@/lib/ordersGate'

/**
 * Feature flags (public.app_settings, migration 024).
 *
 * The data-first restructure hides every data-CAPTURE surface —
 * recommendations/missions, visit surveys & photos, tasks, action logging &
 * notes — behind admin-controlled flags so they can return, one at a time,
 * once the portal is the reps' daily habit. The flags are plain rows: reps
 * read them, admins flip them from the Settings page, nothing redeploys.
 *
 * FAIL CLOSED: every flag computed below is FALSE until the settings query
 * has resolved. A hidden feature must never flash into view while the list
 * loads; a visible feature appearing a beat late is fine.
 */

/** 024 lands after database.types.ts was last generated — same untyped-handle
 *  convention as useAccountMetrics.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

export interface AppSettingRow {
  setting_key: string
  enabled: boolean
  params: Record<string, unknown>
  description: string | null
  updated_at: string
}

export const FEATURE_KEYS = [
  'feature.recommendations',
  'feature.visits',
  'feature.tasks',
  'feature.action_logging',
  'feature.orders',
  'feature.quick_log',
  /** Claude drafts orders over MCP. Independent of feature.orders (hand entry). */
  'feature.mcp_orders',
] as const
export type FeatureKey = (typeof FEATURE_KEYS)[number]

async function fetchSettings(): Promise<AppSettingRow[]> {
  const { data, error } = await db
    .from('app_settings')
    .select('setting_key, enabled, params, description, updated_at')
    .order('setting_key')
  if (error) throw error
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    setting_key: String(r.setting_key),
    enabled: r.enabled === true,
    params: (r.params as Record<string, unknown>) ?? {},
    description: (r.description as string | null) ?? null,
    updated_at: String(r.updated_at),
  }))
}

const settingsQueryOptions = {
  queryKey: qk.settings(),
  queryFn: fetchSettings,
  // Flags change when an admin flips one — rarely. The mutation below writes
  // the cache directly, and refetchOnWindowFocus catches everyone else.
  staleTime: 10 * 60_000,
}

export function useAppSettings() {
  return useQuery(settingsQueryOptions)
}

/**
 * Router-guard path: resolve the flag list OUTSIDE component setup. Cached
 * after the first navigation, so this is one round trip per session.
 */
export function ensureSettings(): Promise<AppSettingRow[]> {
  return queryClient.ensureQueryData(settingsQueryOptions)
}

export function isFeatureEnabled(
  settings: AppSettingRow[] | undefined,
  key: FeatureKey,
): boolean {
  return settings?.find((s) => s.setting_key === key)?.enabled === true
}

/**
 * The capture-feature switches as ready-to-gate computeds, all false
 * while loading (see header).
 */
export function useFeatureFlags() {
  const query = useAppSettings()
  const flag = (key: FeatureKey) =>
    computed(() => isFeatureEnabled(query.data.value, key))
  return {
    recommendations: flag('feature.recommendations'),
    visits: flag('feature.visits'),
    tasks: flag('feature.tasks'),
    actionLogging: flag('feature.action_logging'),
    orders: flag('feature.orders'),
    /** After a Call tap on a list, ask how it went (20261013130000). */
    quickLog: flag('feature.quick_log'),
    /** Claude order drafting over MCP (feature.mcp_orders). */
    mcpOrders: flag('feature.mcp_orders'),
    isLoading: query.isLoading,
  }
}

/** The feature.mcp_orders params, defaults filled in, from a settings list. */
export function mcpOrdersParamsOf(settings: AppSettingRow[] | undefined): McpOrdersParams {
  return parseMcpOrdersParams(
    settings?.find((s) => s.setting_key === 'feature.mcp_orders')?.params,
  )
}

/**
 * Claude order drafting for the signed-in user: the flag, its params, and
 * whether this user has a row in public.mcp_order_users. `available` is the
 * one to gate on; it is false while either read is loading (fail closed, like
 * every flag here). The server applies the same rule in mcp_orders_gate().
 */
export function useMcpOrders() {
  const query = useAppSettings()
  const session = useSessionStore()
  const access = useMyMcpOrderAccess()
  const enabled = computed(() => isFeatureEnabled(query.data.value, 'feature.mcp_orders'))
  const params = computed(() => mcpOrdersParamsOf(query.data.value))
  const userAllowed = computed(() =>
    isMcpOrdersUserAllowed(access.onAllowList.value, session.user?.id ?? null),
  )
  return {
    enabled,
    params,
    userAllowed,
    available: computed(() => enabled.value && userAllowed.value),
    isLoading: query.isLoading,
  }
}

/** Admin: flip one flag and/or replace its params. RLS rejects non-admins server-side. */
export function useUpdateAppSetting() {
  const qc = useQueryClient()
  const session = useSessionStore()

  return useMutation({
    mutationFn: async (input: {
      setting_key: string
      enabled?: boolean
      params?: Record<string, unknown>
    }) => {
      const patch: Record<string, unknown> = { updated_by: session.user?.id ?? null }
      if (input.enabled !== undefined) patch.enabled = input.enabled
      if (input.params !== undefined) patch.params = input.params
      const { data, error } = await db
        .from('app_settings')
        .update(patch)
        .eq('setting_key', input.setting_key)
        .select('setting_key, enabled, params, description, updated_at')
        .single()
      if (error) throw error
      return data as unknown as AppSettingRow
    },
    onSuccess: (row) => {
      qc.setQueryData<AppSettingRow[]>(qk.settings(), (prev) =>
        (prev ?? []).map((s) =>
          s.setting_key === row.setting_key ? { ...s, ...row } : s,
        ),
      )
      // Nav items and page sections read the same query — no invalidation
      // needed beyond the cache write above.
    },
  })
}
