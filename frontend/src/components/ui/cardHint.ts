import type { Ref } from 'vue'

/**
 * The collapsed-header hint for a card whose body is a query result.
 *
 * A collapsed card is a decision: open it or don't. The hint is the only
 * evidence the rep has, so it has to say something true in every state,
 * including the three where there is no data to summarise. Those three read
 * the same on every card — this returns them, and `null` when there IS data,
 * which is the caller's cue to write its own summary:
 *
 *   const hint = computed(
 *     () => cardHintState(query, rows.value.length) ?? `${rows.value.length} SKUs`,
 *   )
 *
 * Kept next to AppCollapsibleCard rather than in lib/format because it is
 * about query state, not about formatting a value.
 */
export function cardHintState(
  query: { isPending: Ref<boolean>; error: Ref<unknown> },
  rowCount: number,
): string | null {
  if (query.isPending.value) return '···'
  if (query.error.value) return 'Unavailable'
  if (rowCount === 0) return 'None'
  return null
}
