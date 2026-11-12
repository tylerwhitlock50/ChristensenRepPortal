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
import { READ_ONLY_ROLE_MESSAGE, isReadOnlyRoleError } from '@/lib/readOnlyRole'
import { MCP_ORDERS_LIMIT_FIELDS, parseMcpOrdersParams, type McpOrdersParams } from '@/lib/ordersGate'
import { customerPoOf, portalPoReference } from '@/lib/portalPo'

// The shell's half (who the section is open to, the caps) lives in
// lib/ordersGate.ts: the app shell, the router and the settings import it
// from there, so this module stays out of the entry chunk. The PO rules are
// in lib/portalPo.ts. Both are re-exported here for the order screens.
// Import from this module only on the order screens, never in the shell.
export {
  MCP_ORDERS_DEFAULTS,
  MCP_ORDERS_LIMIT_FIELDS,
  isMcpOrdersUserAllowed,
  ordersSectionOpen,
  parseMcpOrdersParams,
  type McpOrdersParams,
} from '@/lib/ordersGate'
export {
  customerPoOf,
  dealerPo,
  isPortalReference,
  poForSave,
  poInputError,
  portalPoReference,
  PO_MAX_LENGTH,
} from '@/lib/portalPo'

export type OrderSource = 'portal' | 'mcp' | 'inbox'

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
 * With hand entry off, the draft editor opens only a draft Claude wrote: a
 * hand-typed draft would put the whole writer back in reach by URL.
 */
export function canEditDraftInWriter(ordersOn: boolean, source: string | null | undefined): boolean {
  return handEntryAllows(ordersOn, source)
}

/**
 * Whether hand entry (feature.orders) allows acting on this order: always for
 * a Claude draft, otherwise only while hand entry is on. Same rule as the
 * server's orders_hand_entry_guard() (20261111160000), which refuses to create
 * or submit a hand-typed order while the flag is off. The order detail page
 * gates Edit, Submit and Recall on it.
 */
export function handEntryAllows(ordersOn: boolean, source: string | null | undefined): boolean {
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

/**
 * The muted line under a blank PO on a draft, or '' when there is a PO (or
 * the order is past draft, where the stored po_number is already the
 * reference). A PO is optional (20261113090000): submit_order() gives an
 * order with a blank one the reference PORTAL-<order id>. A draft still
 * carrying its own PORTAL-<id> has no customer PO (lib/portalPo.ts). A
 * draft not saved yet has no number to show, and nothing has gone wrong on
 * an untouched form, so it gets a plain helper instead of the warning.
 */
export function noPoHint(
  poNumber: string | null | undefined,
  orderId: number | null | undefined,
  status: string | null | undefined = 'draft',
): string {
  if (status !== 'draft' || customerPoOf(poNumber, orderId)) return ''
  return orderId == null
    ? 'Optional. Without one the order gets a PORTAL- reference.'
    : `No customer PO: it will be submitted as ${portalPoReference(orderId)}.`
}

/**
 * The server's own no-PO warning (mcp_order_preview), stored when Claude
 * drafted the order. It goes stale once the order has a customer PO.
 */
export function isNoPoWarning(warning: string): boolean {
  return warning.startsWith('No customer PO')
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
 * passes through. The read-only-role refusal names a table in its human
 * half, so it gets its own sentence (lib/readOnlyRole.ts).
 */
export function rpcErrorText(message: string | null | undefined): string {
  const m = (message ?? '').trim()
  if (isReadOnlyRoleError(m)) return READ_ONLY_ROLE_MESSAGE
  const match = /^[a-z][a-z0-9_]*(?::\S.*?)?: (.+)$/s.exec(m)
  return match ? match[1].trim() : m
}
