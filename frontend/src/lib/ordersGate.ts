/**
 * Who the Orders section is open to, and the feature.mcp_orders caps — the
 * part of the order rules the app shell, the router and the settings read
 * on every page. Kept apart from lib/mcpOrders.ts (the order screens' own
 * rules) so the entry chunk carries only these few lines: Rollup puts a
 * module, with every export any chunk uses, wherever its first importer
 * is, so one shell import of mcpOrders.ts would ship all of it up front.
 * lib/mcpOrders.ts re-exports everything here for the screens and tests.
 *
 * The database is the authority: mcp_orders_gate() decides who may draft
 * (a row in public.mcp_order_users). These only decide what the app OFFERS.
 */

/**
 * public.app_settings 'feature.mcp_orders' params, with the seeded defaults.
 * WHO may draft is not a param: it is the public.mcp_order_users table
 * (composables/useMcpOrderUsers.ts), with no wildcard.
 */
export interface McpOrdersParams {
  max_lines: number
  max_units_per_line: number
  max_order_value: number
  max_drafts_per_user_per_day: number
  /**
   * The daily draft count for whoever may price orders, admins and inside
   * sales (20261113090000: mcp_order_apply reads this key instead of
   * max_drafts_per_user_per_day for them, so raising it never raises a rep's).
   */
  admin_max_drafts_per_user_per_day: number
  duplicate_window_days: number
}

export const MCP_ORDERS_DEFAULTS: McpOrdersParams = {
  max_lines: 40,
  max_units_per_line: 200,
  max_order_value: 250000,
  max_drafts_per_user_per_day: 25,
  admin_max_drafts_per_user_per_day: 200,
  duplicate_window_days: 14,
}

/** The numeric caps, in the order the admin editor shows them. */
export const MCP_ORDERS_LIMIT_FIELDS: {
  key: keyof McpOrdersParams
  label: string
}[] = [
  { key: 'max_lines', label: 'Max lines per order' },
  { key: 'max_units_per_line', label: 'Max units per line' },
  { key: 'max_order_value', label: 'Max order value ($)' },
  { key: 'max_drafts_per_user_per_day', label: 'Max drafts per rep per day' },
  {
    key: 'admin_max_drafts_per_user_per_day',
    label: 'Max drafts per day (admins and inside sales)',
  },
  { key: 'duplicate_window_days', label: 'Duplicate check window (days)' },
]

function positiveInt(value: unknown, fallback: number): number {
  const n = typeof value === 'string' && value.trim() !== '' ? Number(value) : value
  return typeof n === 'number' && Number.isFinite(n) && Number.isInteger(n) && n > 0
    ? n
    : fallback
}

/**
 * Read the stored params defensively: anything missing or malformed falls
 * back to the default. Keys that are not caps (a stale allowed_user_ids
 * included) are dropped.
 */
export function parseMcpOrdersParams(raw: unknown): McpOrdersParams {
  const p = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>
  const out: McpOrdersParams = { ...MCP_ORDERS_DEFAULTS }
  for (const { key } of MCP_ORDERS_LIMIT_FIELDS) {
    out[key] = positiveInt(p[key], MCP_ORDERS_DEFAULTS[key])
  }
  return out
}

/**
 * Same rule as mcp_orders_user_allowed(): a signed-in user with their own row
 * in public.mcp_order_users. `onAllowList` is that own-row read
 * (useMcpOrderUsers.ts); anything but a definite true — loading, an error,
 * no row — is refused (fail closed). There is no wildcard.
 */
export function isMcpOrdersUserAllowed(
  onAllowList: boolean | null | undefined,
  userId: string | null | undefined,
): boolean {
  return !!userId && onAllowList === true
}

/**
 * Whether the Orders section (list, detail, queue, draft editor) is open to
 * this user. Hand entry (feature.orders) opens it to everyone it is on for.
 * Claude drafting opens it only to someone it is FOR: a user on the
 * allow-list, or inside sales (order_entry), who processes the submitted
 * orders whether or not they draft with Claude themselves.
 */
export function ordersSectionOpen(opts: {
  ordersOn: boolean
  mcpOrdersOn: boolean
  mcpUserAllowed: boolean
  isOrderEntry: boolean
}): boolean {
  return opts.ordersOn || (opts.mcpOrdersOn && (opts.mcpUserAllowed || opts.isOrderEntry))
}
