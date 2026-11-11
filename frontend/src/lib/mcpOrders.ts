/**
 * Claude-drafted orders (feature.mcp_orders) — the pure rules the portal
 * applies around them, kept out of the views so they are unit tested
 * (tests/unit/mcpOrders.test.ts).
 *
 * The database is the authority on every one of these: mcp_orders_gate()
 * decides who may draft (a row in public.mcp_order_users), submit_order() refuses an unacknowledged non-portal
 * order, and a trigger stops a portal session writing the provenance columns.
 * What lives here only decides what the screen OFFERS, so a button is never
 * shown that the server will refuse.
 */

export type OrderSource = 'portal' | 'mcp' | 'inbox'

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
  duplicate_window_days: number
}

export const MCP_ORDERS_DEFAULTS: McpOrdersParams = {
  max_lines: 40,
  max_units_per_line: 200,
  max_order_value: 250000,
  max_drafts_per_user_per_day: 25,
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
  { key: 'max_drafts_per_user_per_day', label: 'Max drafts per user per day' },
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
 * Validate an admin's edit before it is saved. Returns the cleaned params or
 * the first problem in words. Unlike parseMcpOrdersParams this does NOT
 * fall back silently: a typo in a cap must be refused, not reset.
 */
export function validateMcpOrdersParams(
  raw: unknown,
): { ok: true; params: McpOrdersParams } | { ok: false; error: string } {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    return { ok: false, error: 'Settings must be an object.' }
  }
  const p = raw as Record<string, unknown>
  for (const { key, label } of MCP_ORDERS_LIMIT_FIELDS) {
    const v = p[key]
    const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v
    if (typeof n !== 'number' || !Number.isInteger(n) || n <= 0) {
      return { ok: false, error: `${label} must be a whole number above zero.` }
    }
  }
  return { ok: true, params: parseMcpOrdersParams(raw) }
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
 * allow-list, or order entry, who processes the submitted orders.
 */
export function ordersSectionOpen(opts: {
  ordersOn: boolean
  mcpOrdersOn: boolean
  mcpUserAllowed: boolean
  isOrderEntry: boolean
}): boolean {
  return opts.ordersOn || (opts.mcpOrdersOn && (opts.mcpUserAllowed || opts.isOrderEntry))
}

/**
 * With hand entry off, the draft editor opens only a draft Claude wrote: a
 * hand-typed draft would put the whole writer back in reach by URL.
 */
export function canEditDraftInWriter(ordersOn: boolean, source: string | null | undefined): boolean {
  return ordersOn || needsAcknowledgement(source)
}

/** Anything not hand-written in the portal needs a reviewer's acknowledgement. */
export function needsAcknowledgement(source: string | null | undefined): boolean {
  return !!source && source !== 'portal'
}

/** Badge text for a non-portal order, or '' for a hand-written one. */
export function sourceBadgeLabel(source: string | null | undefined): string {
  if (!needsAcknowledgement(source)) return ''
  return source === 'inbox' ? 'From email (Claude)' : 'Drafted by Claude'
}

/** The submit button is live only once a non-portal order is acknowledged. A test draft never submits. */
export function canSubmitWithAck(
  source: string | null | undefined,
  acknowledged: boolean,
  isTest = false,
): boolean {
  if (isTest) return false
  return !needsAcknowledgement(source) || acknowledged
}

/**
 * A line where the user told Claude a different price than the list gives:
 * the expected and the list price, or null when there is nothing to show.
 */
export function priceMismatch(line: {
  effective_unit_price: number | null
  mcp_expected_unit_price?: number | null
}): { expected: number; list: number; difference: number } | null {
  const expected = line.mcp_expected_unit_price
  const list = line.effective_unit_price
  if (expected == null || list == null) return null
  const difference = Math.round((Number(list) - Number(expected)) * 100) / 100
  return difference === 0 ? null : { expected: Number(expected), list: Number(list), difference }
}

/** The submit_order() arguments the portal sends (contract item 6). */
export function submitOrderArgs(
  orderId: number,
  acknowledged: boolean,
): { p_order_id: number; p_acknowledged: boolean } {
  return { p_order_id: orderId, p_acknowledged: acknowledged === true }
}

/** mcp_warnings is jsonb written by the server; show only its strings. */
export function warningList(raw: unknown): string[] {
  if (!Array.isArray(raw)) return []
  return raw
    .map((w) => {
      if (typeof w === 'string') return w
      if (w && typeof w === 'object') {
        const o = w as Record<string, unknown>
        const text = o.message ?? o.text ?? o.detail ?? o.code
        return typeof text === 'string' ? text : ''
      }
      return ''
    })
    .map((w) => w.trim())
    .filter(Boolean)
}

/** The email an order came from, when source_ref says so. */
export interface EmailSourceRef {
  sender: string | null
  subject: string | null
  received_at: string | null
  excerpt: string | null
}

export function emailSourceRef(raw: unknown): EmailSourceRef | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const r = raw as Record<string, unknown>
  if (r.kind !== 'email') return null
  const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : null)
  const ref = {
    sender: str(r.sender),
    subject: str(r.subject),
    received_at: str(r.received_at),
    excerpt: str(r.excerpt),
  }
  return ref.sender || ref.subject || ref.excerpt ? ref : null
}

/**
 * The order RPCs raise '<code>[:<detail>]: human text' (e.g.
 * 'acknowledge_required: …', 'invalid_input:unknown_field:foo: …'). Split on
 * the FIRST ': ' (colon, space) after the code, the same rule as the MCP
 * edge function. The screen shows the human half; an unprefixed message
 * passes through.
 */
export function rpcErrorText(message: string | null | undefined): string {
  const m = (message ?? '').trim()
  const match = /^[a-z][a-z0-9_]*(?::\S.*?)?: (.+)$/s.exec(m)
  return match ? match[1].trim() : m
}
