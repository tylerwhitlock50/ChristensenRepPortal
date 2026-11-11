import { computed } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk, queryClient } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'

/**
 * Who may have Claude draft orders: public.mcp_order_users (one row per
 * person, no wildcard). The server checks the same table in
 * mcp_orders_user_allowed() / mcp_orders_gate(); this only decides what the
 * screen offers.
 *
 * RLS: a user reads only their own row; admins read, add and remove any row.
 * An MCP session cannot write it at all. There is no update — a change is a
 * remove + add, and both apply immediately (no Save).
 */

/** The table lands after database.types.ts was last generated — same
 *  untyped-handle convention as useAppSettings.ts. */
const db = supabase as unknown as SupabaseClient

/* ------------------------------------------------------------ own row */

async function fetchOnAllowList(userId: string): Promise<boolean> {
  const { data, error } = await db
    .from('mcp_order_users')
    .select('user_id')
    .eq('user_id', userId)
    .maybeSingle()
  if (error) throw error
  return !!data
}

function mineQueryOptions(userId: string) {
  return {
    queryKey: qk.mcpOrderUsers.mine(userId),
    queryFn: () => fetchOnAllowList(userId),
    // Changes when an admin edits the list — rarely. The admin mutations
    // invalidate it; refetchOnWindowFocus catches everyone else.
    staleTime: 10 * 60_000,
  }
}

/**
 * Router-guard path: whether this user has a row, outside component setup.
 * FAILS CLOSED — an error, the table not there yet, or no answer within
 * `waitMs` (no signal: a navigation must never hang on this) reads as
 * "not listed". Normally a cache hit.
 */
export async function ensureOnMcpOrderList(
  userId: string | null | undefined,
  waitMs = 8_000,
): Promise<boolean> {
  if (!userId) return false
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    const listed = await Promise.race([
      queryClient.ensureQueryData(mineQueryOptions(userId)),
      new Promise<boolean>((resolve) => {
        timer = setTimeout(() => resolve(false), waitMs)
      }),
    ])
    return listed === true
  } catch {
    return false
  } finally {
    clearTimeout(timer)
  }
}

/**
 * The signed-in user's own allow-list row as a boolean. False while loading,
 * on error and when signed out (fail closed).
 */
export function useMyMcpOrderAccess() {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')
  const query = useQuery(
    computed(() => ({
      ...mineQueryOptions(userId.value),
      enabled: !!userId.value,
    })),
  )
  return {
    onAllowList: computed(() => !!userId.value && query.data.value === true),
    isLoading: query.isLoading,
  }
}

/* ---------------------------------------------------------- admin list */

export interface McpOrderUser {
  user_id: string
  added_by: string | null
  added_at: string
  note: string | null
  full_name: string | null
  email: string | null
  /** False for a deactivated profile: still listed, but the gate refuses it. */
  active: boolean
  added_by_name: string | null
}

interface ProfileLite {
  user_id: string
  full_name: string | null
  email: string | null
  active: boolean | null
}

async function fetchMcpOrderUsers(): Promise<McpOrderUser[]> {
  const [rows, people] = await Promise.all([
    db
      .from('mcp_order_users')
      .select('user_id, added_by, added_at, note')
      .order('added_at', { ascending: true })
      .order('user_id', { ascending: true }),
    db.from('profiles').select('user_id, full_name, email, active'),
  ])
  if (rows.error) throw rows.error
  if (people.error) throw people.error
  const byId = new Map(
    ((people.data ?? []) as ProfileLite[]).map((p) => [p.user_id, p] as const),
  )
  return ((rows.data ?? []) as Record<string, unknown>[]).map((r) => {
    const userId = String(r.user_id)
    const addedBy = (r.added_by as string | null) ?? null
    const p = byId.get(userId)
    const adder = addedBy ? byId.get(addedBy) : undefined
    return {
      user_id: userId,
      added_by: addedBy,
      added_at: String(r.added_at),
      note: (r.note as string | null) ?? null,
      full_name: p?.full_name ?? null,
      email: p?.email ?? null,
      active: p?.active === true,
      added_by_name: adder ? adder.full_name || adder.email || null : null,
    }
  })
}

/** Admin: everyone on the list, with their profile. RLS returns only your
 *  own row to a non-admin, so render this only for admins. */
export function useMcpOrderUsers() {
  return useQuery({
    queryKey: qk.mcpOrderUsers.list(),
    queryFn: fetchMcpOrderUsers,
  })
}

/** Admin: put someone on the list. added_by / added_at default server-side. */
export function useAddMcpOrderUser() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { userId: string; note?: string | null }) => {
      const note = input.note?.trim() ? input.note.trim().slice(0, 200) : null
      const { error } = await db
        .from('mcp_order_users')
        .insert({ user_id: input.userId, note })
      if (error) throw error
    },
    onSettled: () => qc.invalidateQueries({ queryKey: qk.mcpOrderUsers.root() }),
  })
}

/** Admin: take someone off the list. Their next MCP request is refused. */
export function useRemoveMcpOrderUser() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (userId: string) => {
      const { error } = await db.from('mcp_order_users').delete().eq('user_id', userId)
      if (error) throw error
    },
    onSettled: () => qc.invalidateQueries({ queryKey: qk.mcpOrderUsers.root() }),
  })
}
