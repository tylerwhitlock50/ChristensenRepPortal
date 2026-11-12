/**
 * Inside sales (profiles.role = 'order_entry') reads every account and works
 * orders, and changes nothing else. The database enforces it:
 * block_writes_for_read_only_role() (20261113090000) raises
 *
 *   read_only_role: inside sales can view <table> but not change it   (42501)
 *
 * on a write to any table outside orders, their own Claude tokens, support
 * questions and the AI caches. The screens stop offering those writes
 * (session.canEditBook); this is the sentence for one that got through
 * anyway. Pure, so lib/supabase.ts, lib/mcpOrders.ts and lib/queryClient.ts
 * share it without importing each other.
 */
export const READ_ONLY_ROLE_MESSAGE = 'Inside sales can view this but not change it.'

/** True for the trigger's refusal, as an error object or its message. */
export function isReadOnlyRoleError(error: unknown): boolean {
  const message =
    typeof error === 'string' ? error : (error as { message?: unknown } | null)?.message
  return typeof message === 'string' && message.includes('read_only_role')
}
