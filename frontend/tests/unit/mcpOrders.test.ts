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
  MCP_ORDERS_LIMIT_FIELDS,
  canSubmitWithAck,
  customerPoOf,
  dealerPo,
  isNoPoWarning,
  isPortalReference,
  poForSave,
  poInputError,
  priceMismatch,
  emailSourceRef,
  isMcpOrdersUserAllowed,
  needsAcknowledgement,
  noPoHint,
  parseMcpOrdersParams,
  portalPoReference,
  rpcErrorText,
  ordersSectionOpen,
  canEditDraftInWriter,
  handEntryAllows,
  sourceBadgeLabel,
  submitOrderArgs,
  validateMcpOrdersParams,
  warningList,
} from '../../src/lib/mcpOrders'
import * as gate from '../../src/lib/ordersGate'

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
// 20261113090000 (D6): admins and inside sales count drafts against their own key.
t('the pricers\' daily cap defaults to 200, as mcp_order_apply does',
  MCP_ORDERS_DEFAULTS.admin_max_drafts_per_user_per_day, 200)
t(
  '…is read when stored, apart from the rep cap',
  parseMcpOrdersParams({ max_drafts_per_user_per_day: 10, admin_max_drafts_per_user_per_day: '60' }),
  { ...MCP_ORDERS_DEFAULTS, max_drafts_per_user_per_day: 10, admin_max_drafts_per_user_per_day: 60 },
)
t(
  '…and falls back when it is not a whole number above zero',
  parseMcpOrdersParams({ admin_max_drafts_per_user_per_day: 0 }).admin_max_drafts_per_user_per_day,
  200,
)
t(
  'the editor shows both daily caps, each saying whose it is',
  MCP_ORDERS_LIMIT_FIELDS.filter((f) => f.key.endsWith('drafts_per_user_per_day')).map((f) => [f.key, f.label]),
  [
    ['max_drafts_per_user_per_day', 'Max drafts per rep per day'],
    ['admin_max_drafts_per_user_per_day', 'Max drafts per day (admins and inside sales)'],
  ],
)

t('validate: good', validateMcpOrdersParams({ ...MCP_ORDERS_DEFAULTS }).ok, true)
t('validate: array refused', validateMcpOrdersParams([]).ok, false)
t(
  'validate: zero cap refused, not reset',
  validateMcpOrdersParams({ ...MCP_ORDERS_DEFAULTS, max_lines: 0 }),
  { ok: false, error: 'Max lines per order must be a whole number above zero.' },
)
t(
  'validate: a zero pricers\' cap is refused by its own name',
  validateMcpOrdersParams({ ...MCP_ORDERS_DEFAULTS, admin_max_drafts_per_user_per_day: 0 }),
  { ok: false, error: 'Max drafts per day (admins and inside sales) must be a whole number above zero.' },
)
t(
  'validate: the pricers\' cap is saved as typed',
  validateMcpOrdersParams({ ...MCP_ORDERS_DEFAULTS, admin_max_drafts_per_user_per_day: '75' }),
  { ok: true, params: { ...MCP_ORDERS_DEFAULTS, admin_max_drafts_per_user_per_day: 75 } },
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
// 20261113090000: the human half of the new refusals.
t('not_owner: the human half',
  rpcErrorText("not_owner: only the order's owner or an admin can set prices on it"),
  "only the order's owner or an admin can set prices on it")
t('po_would_be_removed: the human half, PO and all',
  rpcErrorText('po_would_be_removed: the draft has the customer PO BS-4500; send it again as po_number (a person can clear it in the portal if it really must go)'),
  'the draft has the customer PO BS-4500; send it again as po_number (a person can clear it in the portal if it really must go)')
t('ship_date_past: the human half',
  rpcErrorText('ship_date_past: the requested ship date 2026-11-01 has passed; change it before submitting'),
  'the requested ship date 2026-11-01 has passed; change it before submitting')
t('admin_price_requires_admin: the reworded human half',
  rpcErrorText('admin_price_requires_admin: order 502 has 2 line(s) priced by hand; only an admin, or inside sales on their own order, can submit it'),
  'order 502 has 2 line(s) priced by hand; only an admin, or inside sales on their own order, can submit it')
t('the read-only-role refusal gets its own sentence, not a table name',
  rpcErrorText('read_only_role: inside sales can view account_notes but not change it'),
  'Inside sales can view this but not change it.')

// ------------------------------------------------- optional customer PO
t('PO reference is PORTAL-<id>', portalPoReference(8123), 'PORTAL-8123')
t('blank PO on a draft: the hint names the reference', noPoHint(null, 8123, 'draft'), 'No customer PO: it will be submitted as PORTAL-8123.')
t('whitespace is blank', noPoHint('   ', 8123), 'No customer PO: it will be submitted as PORTAL-8123.')
t('a PO: no hint', noPoHint('4471', 8123, 'draft'), '')
t('past draft: no hint (the stored PO is already the reference)', noPoHint(null, 8123, 'submitted'), '')
t('a draft not saved yet: a neutral helper, not a warning', noPoHint('', null), 'Optional. Without one the order gets a PORTAL- reference.')
t('a draft still on its own PORTAL-<id> has no customer PO', noPoHint('PORTAL-8123', 8123, 'draft'), 'No customer PO: it will be submitted as PORTAL-8123.')
t('tabs, line breaks and no-break spaces are blank', noPoHint('\t\r\n\u00A0 ', 8123), 'No customer PO: it will be submitted as PORTAL-8123.')

t('PORTAL reference recognised', [isPortalReference('PORTAL-8123'), isPortalReference(' portal-8 '), isPortalReference('PORTAL-'), isPortalReference('PO-8123'), isPortalReference(null)], [true, true, false, false, false])
t('dealer PO: theirs kept, a PORTAL- reference and blanks dropped', [dealerPo(' 4471 '), dealerPo('PORTAL-8124'), dealerPo('  '), dealerPo(null)], ['4471', null, null, null])
t('customer PO of a draft: its own reference is none, another stays', [customerPoOf('PORTAL-8123', 8123), customerPoOf('portal-8123', 8123), customerPoOf('PORTAL-9', 8123), customerPoOf(' BS-4500 ', 8123), customerPoOf('PORTAL-8123', null)], ['', '', 'PORTAL-9', 'BS-4500', 'PORTAL-8123'])
t('PO saved: trimmed, or null for none', [poForSave(' BS-4500 ', 1), poForSave('', 1), poForSave('PORTAL-1', 1)], ['BS-4500', null, null])
t('typed PO: another order\'s reference refused, its own is fine (none)', [poInputError('PORTAL-9', 8123) !== '', poInputError('PORTAL-8123', 8123), poInputError('BS-4500', 8123)], [true, '', ''])
t('typed PO: 40 characters at most', [poInputError('x'.repeat(40), 1), poInputError('x'.repeat(41), 1) !== ''], ['', true])
t('the server\'s stored no-PO warning is recognised', [isNoPoWarning('No customer PO: it will be submitted as PORTAL-5. Ask the customer for a PO number if they use them.'), isNoPoWarning('Stock: 2 left')], [true, false])

// The shell imports the gate from lib/ordersGate.ts; the screens' re-exports are the same functions.
t('gate re-exported unchanged', [gate.ordersSectionOpen === ordersSectionOpen, gate.isMcpOrdersUserAllowed === isMcpOrdersUserAllowed, gate.parseMcpOrdersParams === parseMcpOrdersParams], [true, true, true])

const sec = (ordersOn: boolean, mcpOrdersOn: boolean, mcpUserAllowed: boolean, isOrderEntry: boolean) =>
  ordersSectionOpen({ ordersOn, mcpOrdersOn, mcpUserAllowed, isOrderEntry })
t('orders section: hand entry on opens it', sec(true, false, false, false), true)
t('orders section: drafting on opens it for an allowed user', sec(false, true, true, false), true)
t('orders section: drafting on does NOT open it for a rep off the list', sec(false, true, false, false), false)
t('orders section: drafting on opens the queue for inside sales (order_entry)', sec(false, true, false, true), true)
t('orders section: inside sales on the allow-list too', sec(false, true, true, true), true)
t('orders section: hand entry on opens it for inside sales', sec(true, false, false, true), true)
t('orders section: both off', sec(false, false, true, true), false)
t('writer: hand entry off refuses a hand-typed draft', canEditDraftInWriter(false, 'portal'), false)
t('writer: hand entry off still edits a Claude draft', canEditDraftInWriter(false, 'mcp'), true)
t('writer: hand entry on edits any draft', canEditDraftInWriter(true, 'portal'), true)

t('detail: hand entry off blocks a hand-typed order', handEntryAllows(false, 'portal'), false)
t('detail: hand entry off still allows a Claude draft', handEntryAllows(false, 'mcp'), true)
t('detail: hand entry off still allows an inbox draft', handEntryAllows(false, 'inbox'), true)
t('detail: hand entry on allows a hand-typed order', handEntryAllows(true, 'portal'), true)
t('detail: unknown source is treated as hand-typed', handEntryAllows(false, null), false)


// 20261112090000: a test draft never submits; expected-price mismatches
t('test draft never submits, even ticked', canSubmitWithAck('mcp', true, true), false)
t('mismatch shown', priceMismatch({ effective_unit_price: 1566.67, mcp_expected_unit_price: 1485 }), {
  expected: 1485,
  list: 1566.67,
  difference: 81.67,
})
t('match not shown', priceMismatch({ effective_unit_price: 1485, mcp_expected_unit_price: 1485 }), null)
t('no expectation', priceMismatch({ effective_unit_price: 1485, mcp_expected_unit_price: null }), null)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
