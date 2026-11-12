/**
 * Whose order it is, for the order screens (20261113090000). Inside sales
 * and admins read every order, drafts included, so the list, the queue and
 * the order page say who drafted each one. profiles shows a user only their
 * own row, so the names come from order_owner_names() (a display name and a
 * role, never an email; composables/useOrders.ts useOrderOwnerNames).
 *
 * Pure, unit tested in tests/unit/orderOwners.test.ts.
 */

/** One row of order_owner_names(). 'order_entry' arrives as 'inside_sales'. */
export interface OrderOwnerName {
  user_id: string
  display_name: string
  role: string
}

/** The ids to ask about: each once, blanks dropped, sorted so a query key is stable. */
export function uniqueUserIds(ids: readonly (string | null | undefined)[]): string[] {
  return [...new Set(ids.filter((id): id is string => !!id && id.trim() !== ''))].sort()
}

/**
 * "you", "Dana Reyes (inside sales)", "Sam Ortiz". '' when the name is not
 * known (not loaded yet, or a user the caller may not name): the screen then
 * says less rather than guess.
 */
export function ownerLabel(
  owner: OrderOwnerName | null | undefined,
  opts: { isViewer: boolean },
): string {
  if (opts.isViewer) return 'you'
  if (!owner) return ''
  const role = owner.role === 'inside_sales' ? ' (inside sales)' : owner.role === 'admin' ? ' (admin)' : ''
  return `${owner.display_name}${role}`
}

/**
 * The orders list for someone who reads everyone's (an admin or inside
 * sales): their own by default, everyone's on request.
 */
export type OrderListScope = 'mine' | 'everyone'

/** Remembered per browser tab (sessionStorage): a new tab starts on Mine. */
export const ORDER_LIST_SCOPE_KEY = 'rep-portal:orders-list-scope'

type ScopeStorage = Pick<Storage, 'getItem' | 'setItem'>

function tabStorage(): ScopeStorage | null {
  try {
    return typeof window === 'undefined' ? null : window.sessionStorage
  } catch {
    return null
  }
}

/** The tab's choice, 'mine' when there is none or storage is unavailable. */
export function readListScope(storage: ScopeStorage | null = tabStorage()): OrderListScope {
  try {
    return storage?.getItem(ORDER_LIST_SCOPE_KEY) === 'everyone' ? 'everyone' : 'mine'
  } catch {
    return 'mine'
  }
}

/** Remember the choice for this tab; a private window that refuses is fine. */
export function writeListScope(scope: OrderListScope, storage: ScopeStorage | null = tabStorage()): void {
  try {
    storage?.setItem(ORDER_LIST_SCOPE_KEY, scope)
  } catch {
    /* the choice just isn't remembered */
  }
}

/** 'mine' keeps the viewer's own orders; 'everyone' keeps them all. */
export function scopeOrders<T extends { user_id: string }>(
  rows: readonly T[],
  scope: OrderListScope,
  viewerId: string | null | undefined,
): T[] {
  return scope === 'everyone' ? [...rows] : rows.filter((o) => !!viewerId && o.user_id === viewerId)
}
