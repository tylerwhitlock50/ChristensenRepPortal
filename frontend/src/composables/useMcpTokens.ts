import { computed } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'

/**
 * MCP tokens (migration 20260816120000) — the credential a rep pastes into
 * Claude so it can query their sales data.
 *
 * The plaintext exists for exactly one render. `mcp_token_create` returns it
 * once and stores only a SHA-256, so it is never in a query cache, never
 * refetchable, and gone on reload. The mutation therefore does NOT write the
 * token into the token list cache — the page holds it in local state, shows
 * it with a copy button, and drops it. Do not "fix" that by caching it.
 *
 * The table is column-granted (no `token_hash` for `authenticated`), so the
 * select below must name its columns: `select('*')` is a 42501 by design.
 */

/** The MCP endpoint lives next to the other Edge Functions. */
const FUNCTIONS_BASE = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1`
export const MCP_URL = `${FUNCTIONS_BASE}/mcp`

/** 20260816120000 lands after database.types.ts was last generated — same
 *  untyped-handle convention as useAppSettings.ts; delete after regeneration. */
const db = supabase as unknown as SupabaseClient

export interface McpTokenRow {
  id: string
  name: string
  token_prefix: string
  created_at: string
  expires_at: string
  last_used_at: string | null
  revoked_at: string | null
}

export interface MintedToken {
  id: string
  token: string
  name: string
  expires_at: string
}

export const mcpTokenKeys = {
  root: () => ['mcp-tokens'] as const,
  mine: (userId: string) => ['mcp-tokens', userId] as const,
}

async function fetchTokens(userId: string): Promise<McpTokenRow[]> {
  const { data, error } = await db
    .from('mcp_tokens')
    .select('id, name, token_prefix, created_at, expires_at, last_used_at, revoked_at')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as unknown as McpTokenRow[]
}

export function useMcpTokens() {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')

  return useQuery({
    queryKey: computed(() => mcpTokenKeys.mine(userId.value)),
    queryFn: () => fetchTokens(userId.value),
    enabled: computed(() => Boolean(userId.value)),
    // A credential list is short and rarely changes; the mutations below
    // invalidate it directly.
    staleTime: 5 * 60_000,
  })
}

/** True while the token can still be used — not revoked and not expired. */
export function isLive(token: McpTokenRow): boolean {
  return !token.revoked_at && new Date(token.expires_at).getTime() > Date.now()
}

export function useCreateMcpToken() {
  const qc = useQueryClient()
  const session = useSessionStore()

  return useMutation({
    mutationFn: async (input: { name?: string; days?: number }) => {
      const { data, error } = await db.rpc('mcp_token_create', {
        p_name: input.name?.trim() || 'Claude',
        p_days: input.days ?? 365,
      })
      if (error) throw error
      // A `returns table` RPC comes back as a one-row array.
      const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | null
      if (!row?.token) {
        throw new Error('The token was created but not returned. Reload and check the list.')
      }
      return {
        id: String(row.token_id),
        token: String(row.token),
        name: String(row.token_name ?? 'Claude'),
        expires_at: String(row.expires_at),
      } satisfies MintedToken
    },
    onSuccess: () => {
      // Refetch the list for the new row's metadata. The plaintext is
      // deliberately not seeded into any cache — see the file header.
      qc.invalidateQueries({ queryKey: mcpTokenKeys.mine(session.user?.id ?? '') })
    },
  })
}

export function useRevokeMcpToken() {
  const qc = useQueryClient()
  const session = useSessionStore()

  return useMutation({
    mutationFn: async (id: string) => {
      const { data, error } = await db.rpc('mcp_token_revoke', { p_id: id })
      if (error) throw error
      return data === true
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: mcpTokenKeys.mine(session.user?.id ?? '') })
    },
  })
}

/**
 * The URL form for clients that cannot send a header — claude.ai custom
 * connectors take a URL and nothing else. Header auth is preferred wherever
 * it is available; see the Connect page for the guidance the rep reads.
 */
export function connectorUrl(token: string): string {
  return `${MCP_URL}?token=${encodeURIComponent(token)}`
}

/** The Claude Code / Claude Desktop config block, ready to paste. */
export function claudeCodeCommand(token: string): string {
  return `claude mcp add --transport http rep-portal ${MCP_URL} --header "Authorization: Bearer ${token}"`
}
