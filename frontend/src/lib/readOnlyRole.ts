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
 * anyway. Pure, so lib/supabase.ts, lib/mcpOrders.ts, lib/queryClient.ts and
 * lib/submitQueue.ts share it without importing each other.
 */
export const READ_ONLY_ROLE_MESSAGE = 'Inside sales can view this but not change it.'

/**
 * The refusal is the code 'read_only_role' followed by ': ', at the start of
 * the message or after a non-word character (another function may wrap it:
 * 'could not save: read_only_role: …'). The bare word is not enough: the
 * trigger function block_writes_for_read_only_role and the triggers
 * trg_<table>_read_only_role carry it too, and an error naming one of them
 * is not this refusal.
 */
const REFUSAL = /(?:^|[^A-Za-z0-9_])read_only_role: /

/**
 * Where the database's own words are kept once a screen-facing message has
 * replaced them (lib/queryClient.ts): the only record of which table refused.
 */
export const READ_ONLY_ROLE_ORIGINAL = 'readOnlyRoleOriginal'

/** True for the trigger's refusal, as an error object or its message, before or after it was reworded. */
export function isReadOnlyRoleError(error: unknown): boolean {
  if (error && typeof error === 'object') {
    const kept = (error as Record<string, unknown>)[READ_ONLY_ROLE_ORIGINAL]
    if (typeof kept === 'string') return true
  }
  const message =
    typeof error === 'string' ? error : (error as { message?: unknown } | null)?.message
  return typeof message === 'string' && REFUSAL.test(message)
}

/** The database's own words for a refusal, reworded or not; null for any other error. */
export function readOnlyRoleOriginal(error: unknown): string | null {
  if (!isReadOnlyRoleError(error)) return null
  if (typeof error === 'string') return error
  const e = error as Record<string, unknown>
  const kept = e[READ_ONLY_ROLE_ORIGINAL]
  if (typeof kept === 'string') return kept
  return typeof e.message === 'string' ? e.message : null
}
