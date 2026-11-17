import { computed } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'

/**
 * Apps the signed-in person has connected to the portal with OAuth
 * (migration 20261116120000): what the Connect page lists and disconnects.
 *
 * Two sources, and the split matters:
 *
 *   Supabase Auth      owns the truth. `auth.oauth.listGrants()` is every app
 *                      this person has approved and not revoked;
 *                      `revokeGrant()` ends one: the consent is marked
 *                      revoked and its sessions and refresh tokens are
 *                      deleted, so the app's very next request is refused.
 *   mcp_oauth_connections   only knows when an app last actually used the
 *                      MCP endpoint. Decoration, joined on the client id; a
 *                      grant that has never been used simply has no row.
 *
 * Nothing here is a secret. Unlike a crp_ token there is no value to copy or
 * lose: the app holds its own tokens and the portal never sees them.
 */

/** 20261116120000 lands after database.types.ts was last generated. */
const db = supabase as unknown as SupabaseClient

export interface McpConnectedApp {
  /** auth.oauth_clients.id: what revokeGrant() takes. */
  clientId: string
  name: string
  grantedAt: string
  lastUsedAt: string | null
}

export interface McpConnectedApps {
  /**
   * False when the project's OAuth server is switched off. The page then
   * says so instead of offering a sign-in that cannot work.
   */
  enabled: boolean
  apps: McpConnectedApp[]
}

export const mcpOAuthKeys = {
  root: () => ['mcp-oauth'] as const,
  mine: (userId: string) => ['mcp-oauth', userId] as const,
}

/** Supabase Auth answers 404 `feature_disabled` on the grant endpoints while
 *  the OAuth server is off (Dashboard → Authentication → OAuth Server). */
export function isOAuthServerDisabled(error: unknown): boolean {
  const e = error as { code?: unknown; status?: unknown; message?: unknown } | null
  return (
    e?.code === 'feature_disabled' ||
    /oauth server is disabled/i.test(String(e?.message ?? '')) ||
    (e?.status === 404 && /oauth/i.test(String(e?.message ?? '')))
  )
}

async function fetchConnectedApps(userId: string): Promise<McpConnectedApps> {
  const { data: grants, error } = await supabase.auth.oauth.listGrants()
  if (error) {
    if (isOAuthServerDisabled(error)) return { enabled: false, apps: [] }
    throw error
  }
  if (!grants?.length) return { enabled: true, apps: [] }

  // Best effort: a database without the migration yet, or a slow read, must
  // not hide the list of apps someone may need to disconnect.
  const lastUsed = new Map<string, string>()
  const { data: rows } = await db
    .from('mcp_oauth_connections')
    .select('client_id, last_used_at')
    .eq('user_id', userId)
  for (const row of (rows ?? []) as { client_id: string; last_used_at: string }[]) {
    lastUsed.set(row.client_id, row.last_used_at)
  }

  return {
    enabled: true,
    apps: grants
      .map((grant) => ({
        clientId: grant.client.id,
        name: grant.client.name?.trim() || 'Unnamed app',
        grantedAt: grant.granted_at,
        lastUsedAt: lastUsed.get(grant.client.id) ?? null,
      }))
      .sort((a, b) => b.grantedAt.localeCompare(a.grantedAt)),
  }
}

export function useMcpConnectedApps() {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')

  return useQuery({
    queryKey: computed(() => mcpOAuthKeys.mine(userId.value)),
    queryFn: () => fetchConnectedApps(userId.value),
    enabled: computed(() => Boolean(userId.value)),
    // Someone arriving here straight from approving Claude should see it.
    staleTime: 30_000,
  })
}

export function useDisconnectMcpApp() {
  const qc = useQueryClient()
  const session = useSessionStore()

  return useMutation({
    mutationFn: async (clientId: string) => {
      const { error } = await supabase.auth.oauth.revokeGrant({ clientId })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: mcpOAuthKeys.mine(session.user?.id ?? '') })
    },
  })
}

/** Claude Code: add the server, then sign in from `/mcp` inside Claude Code. */
export function claudeCodeOAuthCommand(mcpUrl: string): string {
  return `claude mcp add --transport http rep-portal ${mcpUrl}`
}
