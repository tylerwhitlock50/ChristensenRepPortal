/**
 * Unit tests for lib/mcpOrders.ts — what the portal offers around
 * Claude-drafted orders (feature.mcp_orders).
 *
 * Run with:  npm run test:unit -- mcpOrders
 *
 * What matters: nobody drafts without their own mcp_order_users row, a non-portal order can't
 * be submitted without the tick, and the submit arguments always carry an
 * explicit boolean.
 */
import {
  MCP_ORDERS_DEFAULTS,
  canSubmitWithAck,
  emailSourceRef,
  isMcpOrdersUserAllowed,
  needsAcknowledgement,
  parseMcpOrdersParams,
  rpcErrorText,
  ordersSectionOpen,
  canEditDraftInWriter,
  sourceBadgeLabel,
  submitOrderArgs,
  validateMcpOrdersParams,
  warningList,
} from '../../src/lib/mcpOrders'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(`FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`)
  }
}

// ------------------------------------------------------------- params
t('missing params → defaults', parseMcpOrdersParams(undefined), MCP_ORDERS_DEFAULTS)
t('garbage params → defaults', parseMcpOrdersParams('x'), MCP_ORDERS_DEFAULTS)
t(
  'bad caps fall back, good ones kept',
  parseMcpOrdersParams({ max_lines: -3, max_units_per_line: '50', max_order_value: 1.5 }),
  { ...MCP_ORDERS_DEFAULTS, max_units_per_line: 50 },
)
t(
  'stale allowed_user_ids dropped (the list is a table now)',
  parseMcpOrdersParams({ allowed_user_ids: ['*'], max_lines: 5 }),
  { ...MCP_ORDERS_DEFAULTS, max_lines: 5 },
)
t('no allow-list key in the defaults', 'allowed_user_ids' in MCP_ORDERS_DEFAULTS, false)

t('validate: good', validateMcpOrdersParams({ ...MCP_ORDERS_DEFAULTS }).ok, true)
t('validate: array refused', validateMcpOrdersParams([]).ok, false)
t(
  'validate: zero cap refused, not reset',
  validateMcpOrdersParams({ ...MCP_ORDERS_DEFAULTS, max_lines: 0 }),
  { ok: false, error: 'Max lines per order must be a whole number above zero.' },
)
t(
  'validate: cleaned params carry no allow-list',
  validateMcpOrdersParams({ ...MCP_ORDERS_DEFAULTS, allowed_user_ids: ['*'] }),
  { ok: true, params: MCP_ORDERS_DEFAULTS },
)

// ------------------------------------------- allow-list (mcp_order_users)
t('own row present = allowed', isMcpOrdersUserAllowed(true, 'u1'), true)
t('no own row = refused', isMcpOrdersUserAllowed(false, 'u1'), false)
t('still loading / errored (undefined) = refused', isMcpOrdersUserAllowed(undefined, 'u1'), false)
t('null = refused', isMcpOrdersUserAllowed(null, 'u1'), false)
t('signed out refused even with a row', isMcpOrdersUserAllowed(true, null), false)

// -------------------------------------------------- acknowledgement gate
t('portal needs no ack', needsAcknowledgement('portal'), false)
t('missing source (pre-migration row) needs no ack', needsAcknowledgement(undefined), false)
t('mcp needs ack', needsAcknowledgement('mcp'), true)
t('inbox needs ack', needsAcknowledgement('inbox'), true)
t('portal submits without tick', canSubmitWithAck('portal', false), true)
t('mcp blocked without tick', canSubmitWithAck('mcp', false), false)
t('mcp submits with tick', canSubmitWithAck('mcp', true), true)
t('submit args carry explicit false', submitOrderArgs(7, false), { p_order_id: 7, p_acknowledged: false })
t('submit args carry true', submitOrderArgs(7, true), { p_order_id: 7, p_acknowledged: true })

t('badge: portal none', sourceBadgeLabel('portal'), '')
t('badge: mcp', sourceBadgeLabel('mcp'), 'Drafted by Claude')
t('badge: inbox', sourceBadgeLabel('inbox'), 'From email (Claude)')

// ------------------------------------------------------ warnings / email
t('warnings: strings and message objects', warningList(['a', { message: 'b' }, 3, ' ', null]), ['a', 'b'])
t('warnings: not an array', warningList({ a: 1 }), [])
t(
  'email ref read',
  emailSourceRef({ kind: 'email', sender: 'x@y.com', subject: ' PO 12 ', excerpt: 'hi' }),
  { sender: 'x@y.com', subject: 'PO 12', received_at: null, excerpt: 'hi' },
)
t('non-email ref ignored', emailSourceRef({ kind: 'voice', sender: 'x' }), null)
t('empty email ref ignored', emailSourceRef({ kind: 'email' }), null)

// --------------------------------------------------------- errors / scope
t('rpc error code stripped', rpcErrorText('acknowledge_required: Tick the box first.'), 'Tick the box first.')
t('rpc error code with detail stripped', rpcErrorText('part_not_orderable:ABC-1: Not on a list.'), 'Not on a list.')
t('plain message passes through', rpcErrorText('Order 5 is not a draft'), 'Order 5 is not a draft')
t('two-segment detail stripped', rpcErrorText('invalid_input:unknown_field:colour: not an order field'), 'not an order field')
t('detail with a space stripped', rpcErrorText('ship_to_invalid:MR MONEY|2: not one of this account'), 'not one of this account')
t('empty message', rpcErrorText(undefined), '')

const sec = (ordersOn: boolean, mcpOrdersOn: boolean, mcpUserAllowed: boolean, isOrderEntry: boolean) =>
  ordersSectionOpen({ ordersOn, mcpOrdersOn, mcpUserAllowed, isOrderEntry })
t('orders section: hand entry on opens it', sec(true, false, false, false), true)
t('orders section: drafting on opens it for an allowed user', sec(false, true, true, false), true)
t('orders section: drafting on does NOT open it for a rep off the list', sec(false, true, false, false), false)
t('orders section: drafting on opens the queue for order entry', sec(false, true, false, true), true)
t('orders section: both off', sec(false, false, true, true), false)
t('writer: hand entry off refuses a hand-typed draft', canEditDraftInWriter(false, 'portal'), false)
t('writer: hand entry off still edits a Claude draft', canEditDraftInWriter(false, 'mcp'), true)
t('writer: hand entry on edits any draft', canEditDraftInWriter(true, 'portal'), true)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
