/**
 * The customer's PO number and the portal's stand-in for a missing one
 * (20261113090000). A PO is encouraged, not required: submit_order() gives
 * an order with a blank one the reference PORTAL-<order id>, and the order
 * loader writes that to Visual, so it comes back from the ERP as the
 * order's "customer PO". Neither the dealer nor anyone else holds that
 * number, so the screens and the text sent to a dealer treat it as no PO.
 *
 * Kept tiny and on its own: the account page, the activity feed and the
 * header search read it as well as the order screens. Unit tested in
 * tests/unit/mcpOrders.test.ts.
 */

/** The reference submit_order() gives an order with no customer PO. */
export function portalPoReference(orderId: number): string {
  return `PORTAL-${orderId}`
}

/**
 * PORTAL-<digits>: a reference the portal assigned, not a dealer's PO. Any
 * letter case, as mcp_order_apply matches it (~*).
 */
export function isPortalReference(po: string | null | undefined): boolean {
  return /^PORTAL-\d+$/i.test((po ?? '').trim())
}

/**
 * The PO the dealer is holding, for text a rep reads or sends them: null
 * when there is none (blank, or a PORTAL- reference the portal assigned).
 */
export function dealerPo(po: string | null | undefined): string | null {
  const p = (po ?? '').trim()
  return p && !isPortalReference(p) ? p : null
}

/**
 * A portal order's customer PO, '' when it has none. Blank is blank after
 * trimming (String.prototype.trim also takes tabs, line breaks and no-break
 * spaces, as the server's btrim does), and a draft still carrying its own
 * PORTAL-<id> has no customer PO either (one recalled before recall_order
 * cleared it).
 */
export function customerPoOf(po: string | null | undefined, orderId: number | null | undefined): string {
  const p = (po ?? '').trim()
  if (!p) return ''
  return orderId != null && p.toUpperCase() === portalPoReference(orderId) ? '' : p
}

/**
 * What to save for a typed PO: the trimmed text, or null for none. The
 * order's own PORTAL-<id> counts as none.
 */
export function poForSave(po: string | null | undefined, orderId: number | null | undefined): string | null {
  return customerPoOf(po, orderId) || null
}

/** The ERP's customer PO field; mcp_order_apply holds Claude to it too. */
export const PO_MAX_LENGTH = 40

/**
 * Why a typed PO cannot be saved, or ''. A PORTAL-<n> reference is the
 * portal's to give (Claude is refused one too): typing another order's
 * would make two orders claim the same reference.
 */
export function poInputError(po: string | null | undefined, orderId: number | null | undefined): string {
  const p = customerPoOf(po, orderId)
  if (isPortalReference(p)) {
    return `${p} is a reference the portal assigns. Type the customer's own PO, or leave it blank.`
  }
  if (p.length > PO_MAX_LENGTH) {
    return `The customer PO can be ${PO_MAX_LENGTH} characters at most.`
  }
  return ''
}
