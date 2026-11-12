/*============================================================================
  orderTools.test.ts — order drafting over MCP: who sees the tools, what the
  write tools forward (never a price or an FFL), how SQL refusals read to the
  model, and that every write is logged without the log masking the result.

      deno test --allow-env --allow-net supabase/functions/mcp/
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import * as mcpAuth from '../_shared/mcpAuth.ts'
import { extractToken, jwtClaims, knownScopes, type McpCaller } from '../_shared/mcpAuth.ts'
import { describeTool, ToolError, TOOLS, type ToolDef } from './tools.ts'
import {
  ADMIN_ORDERING_INSTRUCTIONS,
  decoratePreview,
  draftPayload,
  forbiddenKeysIn,
  type McpOrdersSetting,
  NEXT_STEP,
  hasCustomerPo,
  isAdminCaller,
  ORDER_TOOLS,
  ORDERING_INSTRUCTIONS,
  orderAccess,
  orderToolError,
  OrderToolError,
  parseRpcError,
  partLabel,
  structuredDetail,
  readMcpOrderListed,
  readMcpOrdersSetting,
  toolsFor,
  withOrdering,
} from './orderTools.ts'
import { documentDisplayName, orderDocumentPath, sanitizeDocumentName } from './orderDocuments.ts'

type Row = Record<string, unknown>

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}

function eq(got: unknown, want: unknown, what: string): void {
  assert(
    JSON.stringify(got) === JSON.stringify(want),
    `${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`,
  )
}

const TYLER = '11111111-1111-1111-1111-111111111111'
const OTHER = '22222222-2222-2222-2222-222222222222'
const ORDER_TOOL_NAMES = ORDER_TOOLS.map((t) => t.name)

function caller(over: Partial<McpCaller> = {}): McpCaller {
  return {
    tokenId: 'aaaaaaaa-0000-0000-0000-000000000001',
    userId: TYLER,
    fullName: 'Pilot Admin',
    role: 'admin',
    realRole: 'admin',
    salesRepKey: null,
    repGroupVendorId: null,
    tokenExpiresAt: '2027-01-01T00:00:00Z',
    tokenVia: 'header',
    tokenScopes: [],
    ...over,
  }
}

function setting(enabled: boolean): McpOrdersSetting {
  return {
    enabled,
    params: {
      max_lines: 40,
      max_units_per_line: 200,
      max_order_value: 250000,
      max_drafts_per_user_per_day: 25,
      duplicate_window_days: 14,
    },
  }
}

function names(tools: ToolDef[]): string[] {
  return tools.map((t) => t.name)
}

/*----------------------------------------------------------------------------
  A fake supabase client: rpc() answers from a table of handlers and records
  every call; from() answers from canned rows and records the filters.
----------------------------------------------------------------------------*/
type RpcHandler = (params: Record<string, unknown>) => { data: unknown; error: unknown } | Promise<never>

function fakeDb(
  rpcs: Record<string, RpcHandler> = {},
  tables: Record<string, unknown> = {},
) {
  const rpcCalls: { name: string; params: Record<string, unknown> }[] = []
  const tableCalls: { table: string; filters: [string, unknown][]; columns: string[] }[] = []

  function builder(table: string) {
    const filters: [string, unknown][] = []
    const columns: string[] = []
    tableCalls.push({ table, filters, columns })
    const result = () => {
      const data = tables[table]
      return { data: data ?? null, error: null }
    }
    const b: Record<string, unknown> = {
      select: (cols?: string) => (columns.push(...String(cols ?? '').split(',').map((c) => c.trim())), b),
      eq: (col: string, v: unknown) => (filters.push([col, v]), b),
      is: () => b,
      in: () => b,
      order: () => b,
      limit: () => b,
      maybeSingle: () => {
        const r = result()
        return Promise.resolve({ ...r, data: Array.isArray(r.data) ? r.data[0] ?? null : r.data })
      },
      then: (ok: (v: unknown) => unknown, bad?: (e: unknown) => unknown) =>
        Promise.resolve(result()).then(ok, bad),
    }
    return b
  }

  const db = {
    rpc(name: string, params: Record<string, unknown>) {
      rpcCalls.push({ name, params })
      const handler = rpcs[name]
      if (!handler) return Promise.resolve({ data: null, error: { message: `no fake for ${name}` } })
      try {
        return Promise.resolve(handler(params))
      } catch (e) {
        return Promise.reject(e)
      }
    },
    from: (table: string) => builder(table),
    schema: () => ({ from: (table: string) => builder(`erp.${table}`) }),
  }
  return { db: db as unknown as SupabaseClient, rpcCalls, tableCalls }
}

const ok = (data: unknown) => () => ({ data, error: null })
const raise = (message: string) => () => ({ data: null, error: { message, code: 'P0001' } })

const PREVIEW = {
  order_id: 4321,
  status: 'draft',
  replayed: false,
  source: 'mcp',
  customer_key: 'C100',
  customer_name: 'Example Outdoors',
  requires_ffl: true,
  ffl: { on_file: true, current: true },
  lines: [{ part_id: 'CA-RIDGE-65', qty: 1, unit_price: 1899, line_total: 1899 }],
  total_amount: 1899,
  would_submit: { ok: true, error: null },
  warnings: [],
  portal_path: '/orders/4321',
}

function tool(name: string): ToolDef {
  const t = ORDER_TOOLS.find((x) => x.name === name)
  assert(t, `tool ${name} exists`)
  return t!
}

function ctxFor(db: SupabaseClient, c: McpCaller = caller()) {
  return { db, caller: c, orders: orderAccess(c, setting(true), true) }
}

async function rejects(p: Promise<unknown>): Promise<Error> {
  try {
    await p
  } catch (e) {
    return e as Error
  }
  throw new Error('FAILED: expected a rejection')
}

/** Every key anywhere in a JSON value. */
function allKeys(value: unknown, out = new Set<string>()): Set<string> {
  if (Array.isArray(value)) value.forEach((v) => allKeys(v, out))
  else if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      out.add(k)
      allKeys(v, out)
    }
  }
  return out
}

/*============================================================================
  Visibility
============================================================================*/

Deno.test('visibility: the matrix', () => {
  const readOnly = names(TOOLS)
  const cases: [string, McpCaller, McpOrdersSetting | null, boolean, boolean][] = [
    ['setting row missing', caller(), null, true, false],
    ['flag off', caller(), setting(false), true, false],
    ['flag off, not on the list', caller(), setting(false), false, false],
    ['flag on, not on the list', caller(), setting(true), false, false],
    ['flag on, not on the list, scoped header token', caller({ tokenScopes: ['orders:draft'] }), setting(true), false, false],
    // Since 2026-11-11 any valid token works once the user is on the list.
    ['flag on, on the list, header token, no scopes', caller(), setting(true), true, true],
    ['flag on, on the list, read-only token in the URL', caller({ tokenVia: 'url' }), setting(true), true, true],
    ['flag on, on the list, scoped token in the URL',
      caller({ tokenVia: 'url', tokenScopes: ['orders:draft'] }), setting(true), true, true],
    ['flag on, on the list, scoped header token', caller({ tokenScopes: ['orders:draft'] }), setting(true), true, true],
    // A leftover params key from the old design grants nothing.
    ['flag on, stale allowed_user_ids "*" but no row', caller({ userId: OTHER }),
      { enabled: true, params: { allowed_user_ids: ['*'] } }, false, false],
  ]
  for (const [what, c, s, onList, listed] of cases) {
    const got = names(toolsFor(c, s, onList))
    for (const name of readOnly) assert(got.includes(name), `${what}: read tool ${name} always listed`)
    for (const name of ORDER_TOOL_NAMES) {
      assert(got.includes(name) === listed, `${what}: ${name} ${listed ? 'listed' : 'hidden'}`)
    }
    eq(orderAccess(c, s, onList).order_tools_listed, listed, `${what}: order_tools_listed`)
  }
})

Deno.test('visibility: reasons say what to fix', () => {
  assert(/switched off/.test(orderAccess(caller(), setting(false), true).reason ?? ''), 'flag off')
  eq(
    orderAccess(caller({ userId: OTHER }), setting(true), false).reason,
    'This user is not on the order-drafting list (Admin → Feature flags → Claude order drafting).',
    'not on the list',
  )
  eq(orderAccess(caller(), setting(true), true).reason, null, 'allowed: no reason')
  // Capabilities whoami reports: a URL token with no scopes is fully allowed.
  const url = orderAccess(caller({ tokenVia: 'url' }), setting(true), true)
  eq(url, { mcp_orders: true, order_tools_listed: true, reason: null }, 'url token: allowed')
  assert(!('write_scope_active' in url), 'no write_scope_active any more')
})

Deno.test('visibility: the setting is read through ctx.db, fails closed', async () => {
  const { db, tableCalls } = fakeDb({}, { app_settings: { enabled: true, params: { max_lines: 40 } } })
  const s = await readMcpOrdersSetting(db)
  eq(s?.enabled, true, 'enabled read')
  eq(tableCalls[0].filters, [['setting_key', 'feature.mcp_orders']], 'one row, by key')

  const broken = {
    from: () => ({ select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: null, error: { message: 'boom' } }) }) }) }),
  } as unknown as SupabaseClient
  eq(await readMcpOrdersSetting(broken), null, 'error → null')
  eq(toolsFor(caller(), null, true).length, TOOLS.length, 'null setting → read tools only')
})

Deno.test('visibility: the allow-list row is the caller’s own, read through ctx.db, fails closed', async () => {
  const listed = fakeDb({}, { mcp_order_users: { user_id: TYLER } })
  eq(await readMcpOrderListed(listed.db, TYLER), true, 'row present → on the list')
  eq(listed.tableCalls.map((c) => c.table), ['mcp_order_users'], 'reads mcp_order_users')
  eq(listed.tableCalls[0].filters, [['user_id', TYLER]], 'own row, by user_id')

  const absent = fakeDb({}, {})
  eq(await readMcpOrderListed(absent.db, TYLER), false, 'no row → not on the list')

  const errored = {
    from: () => ({ select: () => ({ eq: () => ({ maybeSingle: () => Promise.resolve({ data: null, error: { message: 'boom' } }) }) }) }),
  } as unknown as SupabaseClient
  eq(await readMcpOrderListed(errored, TYLER), false, 'query error → not on the list')

  const thrown = {
    from: () => { throw new Error('network down') },
  } as unknown as SupabaseClient
  eq(await readMcpOrderListed(thrown, TYLER), false, 'throw → not on the list')
})

Deno.test('auth: header vs URL tokens, scopes, JWT claims', () => {
  const h = extractToken(new Request('https://x/functions/v1/mcp', { headers: { Authorization: 'Bearer crp_abc' } }))
  eq(h, { token: 'crp_abc', via: 'header' }, 'Authorization header')
  const x = extractToken(new Request('https://x/functions/v1/mcp', { headers: { 'x-mcp-token': 'crp_abc' } }))
  eq(x, { token: 'crp_abc', via: 'header' }, 'x-mcp-token header')
  eq(extractToken(new Request('https://x/functions/v1/mcp?token=crp_abc'))?.via, 'url', 'query token')
  eq(extractToken(new Request('https://x/functions/v1/mcp/crp_abc'))?.via, 'url', 'path token')
  // The gateway's anon JWT riding in Authorization is not ours; the URL one is.
  eq(
    extractToken(new Request('https://x/functions/v1/mcp?token=crp_abc', { headers: { Authorization: 'Bearer a.b.c' } })),
    { token: 'crp_abc', via: 'url' },
    'anon JWT ignored, URL token used',
  )

  eq(knownScopes(['orders:draft', 'admin:all', 'orders:draft']), ['orders:draft'], 'unknown scopes dropped')
  eq(knownScopes(null), [], 'no scopes column')
  // The URL refusal and the header-only scope rule are gone (2026-11-11).
  const gone = mcpAuth as unknown as Record<string, unknown>
  eq([typeof gone.assertTokenTransport, typeof gone.effectiveScopes], ['undefined', 'undefined'], 'no transport rule')

  const header = jwtClaims(caller({ tokenScopes: ['orders:draft'] }), 1000)
  eq(header.app_metadata, {
    provider: 'mcp',
    mcp_token_id: 'aaaaaaaa-0000-0000-0000-000000000001',
    mcp_scopes: ['orders:draft'],
  }, 'header token claims')
  eq(header.role, 'authenticated', 'never service_role')
  // Transport changes nothing in the claims; mcp_scopes is the stored set.
  eq(
    jwtClaims(caller({ tokenVia: 'url', tokenScopes: ['orders:draft'] }), 1000).app_metadata,
    header.app_metadata,
    'URL token claims identical to header token claims',
  )
  eq(jwtClaims(caller({ tokenVia: 'url' }), 1000).app_metadata.mcp_token_id,
    'aaaaaaaa-0000-0000-0000-000000000001', 'gate still gets the token id')
})

Deno.test('annotations: reads read-only, writes say so', () => {
  const ann = (name: string) => describeTool(tool(name)).annotations as Record<string, unknown>
  for (const name of ['get_order_context', 'search_order_products', 'get_order_status', 'list_my_order_drafts']) {
    eq(ann(name).readOnlyHint, true, `${name} readOnly`)
  }
  eq([ann('create_order_draft').readOnlyHint, ann('create_order_draft').idempotentHint, ann('create_order_draft').destructiveHint], [false, true, false], 'create')
  eq([ann('update_order_draft').readOnlyHint, ann('update_order_draft').destructiveHint], [false, false], 'update')
  eq([ann('cancel_order_draft').readOnlyHint, ann('cancel_order_draft').destructiveHint], [false, true], 'cancel')
  for (const t of ORDER_TOOLS) assert(!('requiresScope' in t), `${t.name} needs no token scope`)
  for (const t of TOOLS) eq(describeTool(t).annotations.readOnlyHint, true, `${t.name} stays read-only`)
})

Deno.test('instructions: Ordering only when the tools are listed', () => {
  eq(withOrdering('BASE', false), 'BASE', 'not listed')
  const on = withOrdering('BASE', true)
  assert(on.startsWith('BASE\n\n') && on.includes(ORDERING_INSTRUCTIONS), 'listed')
  for (const phrase of ['get_order_context', 'search_order_products', 'create_order_draft', 'update_order_draft', 'allow_duplicate', 'FFL', 'untrusted']) {
    assert(ORDERING_INSTRUCTIONS.includes(phrase), `Ordering mentions ${phrase}`)
  }
  assert(!on.includes(ADMIN_ORDERING_INSTRUCTIONS), 'no admin paragraph by default')
  const admin = withOrdering('BASE', true, true)
  assert(admin.endsWith(ADMIN_ORDERING_INSTRUCTIONS), 'admin paragraph for an admin')
  eq(withOrdering('BASE', false, true), 'BASE', 'nothing when the tools are hidden')
  for (const phrase of ['unit_price', 'price_override_reason', 'resolve_order_parts', 'last_paid_price', 'UNMATCHED']) {
    assert(ADMIN_ORDERING_INSTRUCTIONS.includes(phrase), `admin paragraph mentions ${phrase}`)
  }
})

/*============================================================================
  What the write tools forward
============================================================================*/

const GOOD_ARGS = {
  idempotency_key: 'req-2026-11-11-0001',
  customer_key: 'C100',
  ship_to_key: 'C100|1',
  po_number: 'PO-77',
  ship_to_confirmed: true,
  lines: [{ part_id: 'CA-RIDGE-65', qty: 1, part_confirmed: true }],
}

Deno.test('forward: only whitelisted keys reach the RPC', async () => {
  const { db, rpcCalls } = fakeDb({ mcp_create_order_draft: ok(PREVIEW), mcp_log_call: ok(null) })
  await tool('create_order_draft').handler(
    {
      ...GOOD_ARGS,
      surprise: 'dropped',
      source_ref: { kind: 'email', sender: 'buyer@example.com', excerpt: 'one Ridgeline', evil: 'x' },
      customer_confirmed: 'yes',
      is_test: true,
      lines: [{ part_id: 'CA-RIDGE-65', qty: 2, price_list_id: 7, note: 'dropped', part_confirmed: true, expected_unit_price: '1485' }],
    },
    ctxFor(db),
  )
  const call = rpcCalls.find((c) => c.name === 'mcp_create_order_draft')!
  eq(Object.keys(call.params), ['p'], 'one jsonb argument')
  eq(call.params.p, {
    idempotency_key: 'req-2026-11-11-0001',
    customer_key: 'C100',
    ship_to_key: 'C100|1',
    po_number: 'PO-77',
    ship_to_confirmed: true,
    is_test: true,
    source_ref: { kind: 'email', sender: 'buyer@example.com', excerpt: 'one Ridgeline' },
    lines: [{ part_id: 'CA-RIDGE-65', qty: 2, price_list_id: 7, part_confirmed: true, expected_unit_price: 1485 }],
  }, 'payload (a non-boolean confirmation is dropped, not coerced)')
})

const REP = () => caller({ role: 'rep', realRole: 'rep', fullName: 'Field Rep' })

Deno.test('forward: a rep never forwards a price or FFL key', async () => {
  const attempts: Record<string, unknown>[] = [
    { ...GOOD_ARGS, unit_price: 1 },
    { ...GOOD_ARGS, price: 1 },
    { ...GOOD_ARGS, ffl_license_number: '1-23-456-78-9A-12345' },
    { ...GOOD_ARGS, FFL_License_Number: 'x' },
    { ...GOOD_ARGS, price_override_reason: 'because' },
    { ...GOOD_ARGS, lines: [{ part_id: 'CA-RIDGE-65', qty: 1, unit_price: 1 }] },
    { ...GOOD_ARGS, lines: [{ part_id: 'CA-RIDGE-65', qty: 1, price: 1 }] },
    { ...GOOD_ARGS, lines: [{ part_id: 'CA-RIDGE-65', qty: 1, discount_pct: 50 }] },
  ]
  for (const tname of ['create_order_draft', 'update_order_draft']) {
    for (const args of attempts) {
      const { db, rpcCalls } = fakeDb({ mcp_create_order_draft: ok(PREVIEW), mcp_update_order_draft: ok(PREVIEW), mcp_log_call: ok(null) })
      const err = await rejects(tool(tname).handler({ ...args, order_id: 4321 }, ctxFor(db, REP())))
      assert(err instanceof OrderToolError && err.outcome === 'refused', `${tname} ${JSON.stringify(args)} refused`)
      assert(/never accepted/.test(err.message), 'says prices/FFLs are never accepted')
      assert(!rpcCalls.some((c) => c.name.startsWith('mcp_') && c.name !== 'mcp_log_call'), `${tname}: draft RPC not called`)
      const log = rpcCalls.find((c) => c.name === 'mcp_log_call')!
      eq(log.params.p_outcome, 'refused', `${tname}: refusal logged`)
      const logged = allKeys(log.params.p_args)
      for (const bad of ['unit_price', 'price', 'ffl_license_number', 'FFL_License_Number', 'discount_pct', 'price_override_reason']) {
        assert(!logged.has(bad), `${tname}: ${bad} not written to the audit log`)
      }
      assert(logged.has('rejected_keys'), 'the attempt is recorded by key name')
    }
  }
  // And the builder itself, directly.
  eq(forbiddenKeysIn({ lines: [{ ffl: 'x' }], total_amount: 3 }).sort(), ['lines[0].ffl', 'total_amount'], 'nested + top level')
  const keys = allKeys(draftPayload({ ...GOOD_ARGS }, true))
  for (const bad of ['unit_price', 'price', 'ffl_license_number']) assert(!keys.has(bad), `payload has no ${bad}`)
})

Deno.test('forward: an admin may send PO prices and the reason, never an FFL', async () => {
  const { db, rpcCalls } = fakeDb({ mcp_create_order_draft: ok(PREVIEW), mcp_log_call: ok(null) })
  await tool('create_order_draft').handler(
    {
      ...GOOD_ARGS,
      price_override_reason: 'Distributor stocking order at program price',
      lines: [
        { part_id: '801-15025-01', qty: 2, unit_price: 798.7, customer_part_ref: 'CHR801-15025-01',
          customer_description: 'CHRISTENSEN EVOKE HNTR 6.5PRC 22" GN' },
        { part_id: 'CA-RIDGE-65', qty: 1 },
      ],
    },
    ctxFor(db),
  )
  const call = rpcCalls.find((c) => c.name === 'mcp_create_order_draft')!
  eq((call.params.p as Row).price_override_reason, 'Distributor stocking order at program price', 'reason forwarded')
  eq((call.params.p as Row).lines, [
    { part_id: '801-15025-01', qty: 2, unit_price: 798.7, customer_part_ref: 'CHR801-15025-01',
      customer_description: 'CHRISTENSEN EVOKE HNTR 6.5PRC 22" GN' },
    { part_id: 'CA-RIDGE-65', qty: 1 },
  ], 'line prices and PO refs forwarded')
  const log = rpcCalls.find((c) => c.name === 'mcp_log_call')!
  eq(((log.params.p_args as Row).lines as Row[])[0].unit_price, 798.7, 'an admin price is in the audit log')

  for (const args of [
    { ...GOOD_ARGS, unit_price: 1 },
    { ...GOOD_ARGS, lines: [{ part_id: 'X', qty: 1, unit_price: 1, ffl: 'x' }] },
    { ...GOOD_ARGS, lines: [{ part_id: 'X', qty: 1, discount_pct: 5 }] },
  ]) {
    const fake = fakeDb({ mcp_create_order_draft: ok(PREVIEW), mcp_log_call: ok(null) })
    const err = await rejects(tool('create_order_draft').handler(args, ctxFor(fake.db)))
    assert(err instanceof OrderToolError && err.outcome === 'refused', `admin ${JSON.stringify(args)} refused`)
  }
  eq(forbiddenKeysIn({ unit_price: 1, lines: [{ unit_price: 1 }] }, true), ['unit_price'], 'admin: only a line price')
})

Deno.test('schemas: only an admin sees unit_price; everyone gets resolve_order_parts', () => {
  const schemaOf = (c: McpCaller, name: string) =>
    describeTool(toolsFor(c, setting(true), true).find((t) => t.name === name)!).inputSchema as Row
  const lineProps = (s: Row) => (((s.properties as Row).lines as Row).items as Row).properties as Row
  const admin = schemaOf(caller(), 'create_order_draft')
  const rep = schemaOf(REP(), 'create_order_draft')
  assert('unit_price' in lineProps(admin) && 'price_override_reason' in (admin.properties as Row), 'admin schema')
  assert(!('unit_price' in lineProps(rep)) && !('price_override_reason' in (rep.properties as Row)), 'rep schema')
  assert('customer_part_ref' in lineProps(rep), 'a rep may pass the PO item number')
  assert('unit_price' in lineProps(schemaOf(caller(), 'update_order_draft')), 'admin update schema')
  for (const c of [caller(), REP()]) {
    assert(names(toolsFor(c, setting(true), true)).includes('resolve_order_parts'), `${c.role}: resolve listed`)
  }
})

Deno.test('resolve_order_parts: forwards the items and summarises', async () => {
  const { db, rpcCalls } = fakeDb({
    order_resolve_parts: ok({
      customer_type: 'DISTRIBUTOR',
      items: [
        { index: 0, ref: 'CHR801-15025-01', status: 'matched', candidates: [{ part_id: '801-15025-01', list_price: null }] },
        { index: 1, ref: '801-06145-00', status: 'check_description', candidates: [{ part_id: '801-06145-00' }] },
        { index: 2, ref: 'NOPE', status: 'unmatched', candidates: [] },
      ],
    }),
  })
  const res = await tool('resolve_order_parts').handler(
    { customer_key: 'RSR GROU', items: [{ ref: 'CHR801-15025-01', description: 'EVOKE' }, { ref: '801-06145-00' }, { ref: 'NOPE', extra: 1 }] },
    ctxFor(db),
  ) as Row
  eq(rpcCalls[0].params, {
    p_customer_key: 'RSR GROU',
    p_items: [{ ref: 'CHR801-15025-01', description: 'EVOKE' }, { ref: '801-06145-00' }, { ref: 'NOPE' }],
  }, 'only ref/description forwarded')
  eq(res.summary, { matched: 1, check_description: 1, ambiguous: 0, description_only: 0, unmatched: 1 }, 'summary')
  assert((res.guidance as string[]).some((g) => /descriptions/.test(g)), 'says to show both descriptions')
  assert(describeTool(tool('resolve_order_parts')).annotations.readOnlyHint === true, 'read-only')
})

Deno.test('forward: required inputs refused locally and logged', async () => {
  for (const [what, args] of [
    ['no idempotency_key', { ...GOOD_ARGS, idempotency_key: undefined }],
    ['short idempotency_key', { ...GOOD_ARGS, idempotency_key: 'abc' }],
    ['idempotency_key with spaces (SQL refuses it too)', { ...GOOD_ARGS, idempotency_key: 'order for Bob 1' }],
    ['no lines', { ...GOOD_ARGS, lines: [] }],
  ] as const) {
    const { db, rpcCalls } = fakeDb({ mcp_log_call: ok(null) })
    const err = await rejects(tool('create_order_draft').handler(args as Record<string, unknown>, ctxFor(db)))
    assert(err instanceof OrderToolError, `${what}: refused`)
    eq(rpcCalls.map((c) => c.name), ['mcp_log_call'], `${what}: only the log call`)
  }
})

/*============================================================================
  Error mapping
============================================================================*/

Deno.test('errors: parse code, detail, text', () => {
  eq(parseRpcError('mcp_orders_disabled: Order drafting is off.'), { code: 'mcp_orders_disabled', detail: null, text: 'Order drafting is off.' }, 'plain')
  eq(parseRpcError('possible_duplicate:4120: Same PO within 14 days.'), { code: 'possible_duplicate', detail: '4120', text: 'Same PO within 14 days.' }, 'with detail')
  eq(parseRpcError('part_not_orderable:CA-14-6.5CM: not priced'), { code: 'part_not_orderable', detail: 'CA-14-6.5CM', text: 'not priced' }, 'part id detail')
  eq(parseRpcError('permission denied for function x').code, null, 'not a code')
  eq(parseRpcError('invalid_input:unknown_field:colour: not an order field'),
    { code: 'invalid_input', detail: 'unknown_field:colour', text: 'not an order field' }, 'two-segment detail')
  eq(parseRpcError('ship_to_invalid:MR MONEY|2: not one of this account'),
    { code: 'ship_to_invalid', detail: 'MR MONEY|2', text: 'not one of this account' }, 'detail with a space')
  eq(parseRpcError('customer_not_in_book: X is not on your book: ask'),
    { code: 'customer_not_in_book', detail: null, text: 'X is not on your book: ask' }, 'later colons stay in the text')
})

Deno.test('errors: refusals become actionable text', () => {
  const dup = orderToolError({ message: 'possible_duplicate:4120: Same PO within 14 days.' })
  assert(dup.outcome === 'refused' && dup.code === 'possible_duplicate', 'refused')
  assert(/ask/.test(dup.message) && /allow_duplicate: true/.test(dup.message) && /4120/.test(dup.message), 'ask before allow_duplicate')
  assert(/Do\s+NOT retry on your own/.test(dup.message), 'no silent retry')

  const ack = orderToolError({ message: 'acknowledge_required: A person must acknowledge.' })
  assert(/portal/.test(ack.message), 'acknowledge → finish in the portal')
  const ffl = orderToolError({ message: 'ffl_required: No current FFL on file.' })
  assert(/portal/.test(ffl.message) && /Do not ask for one or pass one/.test(ffl.message), 'ffl → portal, never pass one')

  const gate = orderToolError({ message: 'mcp_user_not_allowed: not on the list' })
  assert(/order-drafting list/.test(gate.message), 'not on the list → admin controls the list')
  // mcp_scope_missing is no longer raised (20261111150000); if an old gate
  // ever did, it passes through like any unknown code.
  const stale = orderToolError({ message: 'mcp_scope_missing: no orders:draft' })
  assert(stale.outcome === 'refused' && /mcp_scope_missing/.test(stale.message), 'stale scope code passes through')
  const unknown = orderToolError({ message: 'brand_new_code: something' })
  assert(unknown.outcome === 'refused' && /brand_new_code: something/.test(unknown.message), 'unknown code passes through')
  const crash = orderToolError(new Error('fetch failed'))
  eq(crash.outcome, 'error', 'no code → error')
  assert(/get_order_status|list_my_order_drafts/.test(crash.message), 'tells the model to check before retrying')
})

/*============================================================================
  Logging
============================================================================*/

Deno.test('logging: success logs ok with the order id', async () => {
  Deno.env.set('PORTAL_URL', 'https://portal.example.test/')
  const { db, rpcCalls } = fakeDb({ mcp_create_order_draft: ok(PREVIEW), mcp_log_call: ok(null) })
  const res = (await tool('create_order_draft').handler(GOOD_ARGS, ctxFor(db))) as Record<string, unknown>
  eq(rpcCalls.map((c) => c.name), ['mcp_create_order_draft', 'mcp_log_call'], 'RPC, then the log')
  const log = rpcCalls[1].params
  eq([log.p_tool, log.p_outcome, log.p_error, log.p_order_id], ['create_order_draft', 'ok', null, 4321], 'log row')
  eq(res.portal_url, 'https://portal.example.test/orders/4321', 'portal_url')
  eq(res.next, NEXT_STEP, 'next step')
  Deno.env.delete('PORTAL_URL')
})

Deno.test('logging: refusal logs refused with the raw SQL text', async () => {
  const { db, rpcCalls } = fakeDb({
    mcp_update_order_draft: raise('possible_duplicate:4120: Same lines within 14 days.'),
    mcp_log_call: ok(null),
  })
  const err = await rejects(tool('update_order_draft').handler({ ...GOOD_ARGS, order_id: 4321 }, ctxFor(db)))
  assert(/allow_duplicate/.test(err.message), 'mapped')
  const log = rpcCalls.find((c) => c.name === 'mcp_log_call')!.params
  eq([log.p_tool, log.p_outcome, log.p_error, log.p_order_id], ['update_order_draft', 'refused', 'possible_duplicate:4120: Same lines within 14 days.', 4321], 'log row')
})

Deno.test('logging: an unexpected failure logs error', async () => {
  const { db, rpcCalls } = fakeDb({
    mcp_cancel_order_draft: () => {
      throw new Error('socket hang up')
    },
    mcp_log_call: ok(null),
  })
  const err = await rejects(tool('cancel_order_draft').handler({ order_id: 9 }, ctxFor(db)))
  assert(err instanceof OrderToolError && err.outcome === 'error', 'error outcome')
  const log = rpcCalls.find((c) => c.name === 'mcp_log_call')!.params
  eq([log.p_outcome, log.p_order_id], ['error', 9], 'logged as error')
})

Deno.test('logging: a failing log never masks the result', async () => {
  // The log RPC returns an error…
  const a = fakeDb({ mcp_cancel_order_draft: ok({ order_id: 9, status: 'cancelled' }), mcp_log_call: raise('not_mcp_session: no') })
  eq(await tool('cancel_order_draft').handler({ order_id: 9 }, ctxFor(a.db)), { order_id: 9, status: 'cancelled' }, 'result survives a log error')
  // …or throws.
  const b = fakeDb({
    mcp_cancel_order_draft: ok({ order_id: 9, status: 'cancelled' }),
    mcp_log_call: () => {
      throw new Error('network')
    },
  })
  eq(await tool('cancel_order_draft').handler({ order_id: 9 }, ctxFor(b.db)), { order_id: 9, status: 'cancelled' }, 'result survives a log throw')
  // And a refusal stays the refusal, not the log's failure.
  const c = fakeDb({ mcp_cancel_order_draft: raise('mcp_orders_disabled: off'), mcp_log_call: raise('boom: log') })
  const err = await rejects(tool('cancel_order_draft').handler({ order_id: 9 }, ctxFor(c.db)))
  assert(/switched off/.test(err.message), 'refusal text kept')
})

Deno.test('logging: reads are not logged', async () => {
  const { db, rpcCalls } = fakeDb({ order_product_search: ok({ customer_type: 'Dealer', items: [] }) })
  await tool('search_order_products').handler({ customer_key: 'C100', query: '6.5 cm ridgeline' }, ctxFor(db))
  eq(rpcCalls.map((c) => c.name), ['order_product_search'], 'no mcp_log_call')
})

/*============================================================================
  Read tools
============================================================================*/

Deno.test('search: arguments and ambiguity guidance', async () => {
  const items = [
    { part_id: 'A', match_score: 3, options: [{ price_list_id: 1 }, { price_list_id: 2 }] },
    { part_id: 'B', match_score: 3, options: [{ price_list_id: 1 }] },
  ]
  const { db, rpcCalls } = fakeDb({ order_product_search: ok({ customer_type: 'Dealer', items }) })
  const res = (await tool('search_order_products').handler({ customer_key: 'C100', query: 'ridgeline fft', limit: 99 }, ctxFor(db))) as { guidance: string[] }
  eq(rpcCalls[0].params, { p_customer_key: 'C100', p_query: 'ridgeline fft', p_limit: 25 }, 'params, limit capped')
  assert(res.guidance.some((g) => /ask which one/.test(g)), 'tie → ask')
  assert(res.guidance.some((g) => /price_list_id/.test(g)), 'several lists → say so')
})

Deno.test('search: SQL ties and fits_request drive the guidance, not raw scores', async () => {
  const run = async (row: Record<string, unknown>) => {
    const { db } = fakeDb({ order_product_search: ok(row) })
    const res = (await tool('search_order_products').handler({ customer_key: 'C100', query: 'x y' }, ctxFor(db))) as { guidance?: string[] }
    return res.guidance ?? []
  }
  // Equal scores but SQL says one fitting part: no question.
  const one = await run({ ties: 1, items: [
    { part_id: 'A', match_score: 0.8, fits_request: true, options: [] },
    { part_id: 'B', match_score: 0.8, fits_request: false, options: [] }] })
  assert(!one.some((g) => /ask which one/.test(g)), 'one fitting part: no question')
  const tie = await run({ ties: 2, items: [
    { part_id: 'A', match_score: 0.8, fits_request: true, options: [] },
    { part_id: 'B', match_score: 0.7, fits_request: true, options: [] }] })
  assert(tie.some((g) => /ask which one/.test(g)), 'SQL tie → ask')
  const none = await run({ ties: 0, items: [{ part_id: 'A', match_score: 0.5, fits_request: false, options: [] }] })
  assert(none.some((g) => /chambering or model/.test(g)), 'nothing fits → say so')
})

Deno.test('context: contacts ranked, order keys exposed', async () => {
  const { db, rpcCalls } = fakeDb({
    order_context: ok({
      customer: { customer_key: 'C100', customer_name: 'Example Outdoors' },
      orderable: true,
      blockers: [],
      ship_tos: [{ ship_to_key: 'C100|1', orderable: true, name: null }],
      default_ship_to_key: 'C100|1',
      contacts: [
        { contact_key: 'erp-77', source: 'erp', name: 'Accounts Payable', email: 'ap@example.com', is_primary: true },
        { contact_key: 'erp-78', source: 'erp', name: 'Pat Buyer', title: 'Buyer', phone: '555-0100' },
        { contact_key: 'rep-5', source: 'rep', name: 'Sam', phone: '555-0101' },
      ],
    }),
  })
  const res = (await tool('get_order_context').handler({ customer_key: 'C100' }, ctxFor(db))) as {
    contacts: { best_contact: Record<string, unknown>; ranked: Record<string, unknown>[] }
    ship_tos: Record<string, unknown>[]
  }
  eq(rpcCalls[0], { name: 'order_context', params: { p_customer_key: 'C100' } }, 'rpc')
  eq(res.contacts.best_contact.customer_contact_key, '78', 'the buyer, not the AP primary')
  eq(res.contacts.ranked.at(-1)?.name, 'Accounts Payable', 'billing last')
  eq(res.contacts.ranked.find((c) => c.name === 'Sam')?.customer_contact_key, undefined, 'rep-entered contact has no order key')
  eq(res.ship_tos[0], { ship_to_key: 'C100|1', orderable: true }, 'nulls stripped')
})

Deno.test('preview: would_submit failure gets a portal hint', () => {
  const out = decoratePreview({ ...PREVIEW, would_submit: { ok: false, error: 'ffl_required: no current FFL on file' } })
  const ws = out.would_submit as Record<string, unknown>
  assert(/portal/.test(String(ws.hint)), 'hint points at the portal')
  eq(out.portal_path, '/orders/4321', 'path kept')
  eq(out.next, NEXT_STEP, 'next')
})

Deno.test('status and list: scoped to the caller where "mine" matters', async () => {
  const a = fakeDb({}, { orders: { id: 5, status: 'draft', source: 'mcp' }, order_lines: [], order_qc_results: [] })
  await tool('get_order_status').handler({ idempotency_key: 'req-2026-11-11-0001' }, ctxFor(a.db))
  eq(a.tableCalls[0].filters, [['client_request_id', 'req-2026-11-11-0001'], ['user_id', TYLER]], 'by key: own orders only')

  const b = fakeDb({}, { orders: [{ id: 5, status: 'draft', source: 'mcp' }] })
  const res = (await tool('list_my_order_drafts').handler({}, ctxFor(b.db))) as { orders: Record<string, unknown>[] }
  eq(b.tableCalls[0].filters, [['user_id', TYLER], ['status', 'draft'], ['source', 'mcp']], 'defaults')
  eq(res.orders[0].order_id, 5, 'order_id')
})

/*============================================================================
  Confirmations (20261112090000): enforced in SQL, surfaced here
============================================================================*/

Deno.test('confirmations: schemas ask for the PO (optional) and require part_confirmed', () => {
  for (const name of ['create_order_draft', 'update_order_draft']) {
    const schema = tool(name).inputSchema as {
      required: string[]
      properties: Record<string, { items?: { required: string[]; properties: Record<string, unknown> } }>
    }
    // 20261113090000: the PO is asked for, not required (no_po_confirmed).
    assert(!schema.required.includes('po_number'), `${name}: po_number not required`)
    assert('po_number' in schema.properties, `${name}: po_number accepted`)
    for (const f of ['customer_confirmed', 'ship_to_confirmed', 'is_test', 'no_po_confirmed']) {
      assert(f in schema.properties, `${name}: ${f} accepted`)
    }
    const line = schema.properties.lines.items!
    assert(line.required.includes('part_confirmed'), `${name}: part_confirmed required on a line`)
    assert('expected_unit_price' in line.properties, `${name}: expected_unit_price accepted`)
  }
  assert(/Never invent one/.test(ORDERING_INSTRUCTIONS), 'instructions: never invent a PO')
  for (const step of ['customer_confirmed', 'ship_to_confirmed', 'part_confirmed', 'expected_unit_price']) {
    assert(ORDERING_INSTRUCTIONS.includes(step), `instructions name ${step}`)
  }
})

Deno.test('confirmations: a refusal carries its choices, part choices labelled', () => {
  const details = JSON.stringify({
    error: 'part_confirmation_required',
    lines: [{
      line: 0,
      part_id: '801-06159-00',
      choices: [
        { part_id: '801-06159-00', family: 'RIDGELINE FLASH FORGED TECHNOLOGY', handedness: 'RIGHT',
          stock_color: 'CARBON / GRAY', chambering: '300 PRC', barrel_length: '22', unit_price: 1566.67, as_sent: true },
        { part_id: '801-06227-00', family: 'RIDGELINE TITANIUM FLASH FORGED TECHNOLOGY', handedness: 'RIGHT',
          stock_color: 'CARBON / METALLIC GRAY', chambering: '300 PRC', barrel_length: '22', unit_price: 2310.79 },
      ],
    }],
  })
  const err = orderToolError({
    message: 'part_confirmation_required:801-06159-00: 1 line(s) were not confirmed by the user',
    details,
  })
  eq(err.code, 'part_confirmation_required', 'code')
  assert(/show the\s+user the top 2-3 choices/.test(err.message), 'tells the model to ask')
  const s = err.structured as { lines: { choices: { label: string }[] }[] }
  eq(s.lines[0].choices.map((c) => c.label), [
    'RH · Ridgeline FFT · Carbon/Gray · 300 PRC · 22 in · $1,566.67',
    'RH · Ridgeline Ti FFT · Carbon/Metallic Gray · 300 PRC · 22 in · $2,310.79',
  ], 'labels')
  assert(err.message.includes('"label":"RH · Ridgeline FFT'), 'choices are in the text the model reads')

  const ship = orderToolError({
    message: 'ship_to_confirmation_required:ALS SPORT: ALS SPORT has 5 orderable ship-tos',
    details: JSON.stringify({ error: 'ship_to_confirmation_required', choices: [
      { ship_to_key: 'ALS SPORT|2', ship_to_id: '002', city: 'Logan', ffl_number: '1-87-000', ffl_expires: '2028-01-01', ffl_current: true },
      { ship_to_key: 'ALS SPORT|5', ship_to_id: '005', city: 'Boise', ffl_number: null, ffl_current: false },
    ] }),
  })
  assert(/FFL number, expiry/.test(ship.message) && /ship_to_confirmed: true/.test(ship.message), 'ship-to guidance')
  eq((ship.structured as { choices: unknown[] }).choices.length, 2, 'ship-to choices kept')
  eq(structuredDetail('not json'), null, 'a plain DETAIL is ignored')
  eq(structuredDetail(undefined), null, 'no DETAIL')

  const po = orderToolError({ message: "po_required: the customer's PO number is required" })
  assert(/never\s+invent one/.test(po.message), 'po_required → ask, never invent')
  const noPo = orderToolError({ message: 'po_confirmation_required: no customer PO number was given' })
  assert(
    /no_po_confirmed: true/.test(noPo.message) && /Never invent/.test(noPo.message),
    'po_confirmation_required → ask; no_po_confirmed only on the user\'s word',
  )
  const acct = orderToolError({ message: 'customer_confirmation_required:ALS SPORT: 4 active accounts' })
  assert(/customer_confirmed: true/.test(acct.message), 'account guidance')
})

Deno.test('confirmations: search items carry a label from the general list price', async () => {
  const { db } = fakeDb({ order_product_search: ok({ ties: 3, items: [
    { part_id: 'L', family: 'RIDGELINE FLASH FORGED TECHNOLOGY', handedness: 'LEFT', stock_color: 'CARBON / GRAY',
      chambering: '300 PRC', barrel_length: '22', fits_request: true,
      options: [{ price_list_id: 9, is_special: true, unit_price: 1 }, { price_list_id: 2, is_special: false, unit_price: 1566.67 }] },
  ] }) })
  const res = (await tool('search_order_products').handler({ customer_key: 'C100', query: 'ridgeline 300 prc' }, ctxFor(db))) as {
    items: { label: string }[]
  }
  eq(res.items[0].label, 'LH · Ridgeline FFT · Carbon/Gray · 300 PRC · 22 in · $1,566.67', 'label')
  eq(partLabel({ part_id: 'X' }), 'X', 'nothing to say → the part id')
})

/*============================================================================
  Inside sales, the optional PO and order documents (20261113090000)
============================================================================*/

const INSIDE = () => caller({ role: 'rep', realRole: 'order_entry', fullName: 'Inside Sales' })

Deno.test('inside sales: priced like an admin, a rep is not', () => {
  assert(isAdminCaller(INSIDE()), 'order_entry takes the pricing schemas')
  assert(isAdminCaller(caller()), 'so does an admin')
  assert(!isAdminCaller(REP()), 'a rep does not')
  const create = toolsFor(INSIDE(), setting(true), true).find((t) => t.name === 'create_order_draft')!
  const line = (create.inputSchema as { properties: { lines: { items: { properties: Record<string, unknown> } } } })
    .properties.lines.items.properties
  assert('unit_price' in line && 'customer_part_ref' in line, 'inside sales may send the PO price and item number')
  const repCreate = toolsFor(REP(), setting(true), true).find((t) => t.name === 'create_order_draft')!
  const repLine = (repCreate.inputSchema as { properties: { lines: { items: { properties: Record<string, unknown> } } } })
    .properties.lines.items.properties
  assert(!('unit_price' in repLine), 'a rep\'s schema has no unit_price')
  assert(/Free goods/.test(ADMIN_ORDERING_INSTRUCTIONS), 'the pricing paragraph explains free goods lines')
})

Deno.test('optional PO: no_po_confirmed is forwarded, and only as a boolean', () => {
  const base = {
    idempotency_key: 'k-12345678',
    customer_key: 'C100',
    lines: [{ part_id: 'P1', qty: 1, part_confirmed: true }],
  }
  const p = draftPayload({ ...base, no_po_confirmed: true }, true)
  eq(p.no_po_confirmed, true, 'forwarded')
  assert(!('po_number' in p), 'no PO is sent')
  assert(!('no_po_confirmed' in draftPayload({ ...base, no_po_confirmed: 'yes' }, true)), 'a non-boolean is dropped')
  assert(/no_po_confirmed/.test(ORDERING_INSTRUCTIONS) && /PORTAL-/.test(ORDERING_INSTRUCTIONS),
    'instructions explain the no-PO path')
})


Deno.test('optional PO: a PO or item number sent as a number is kept, as its digits', () => {
  const base = {
    idempotency_key: 'k-12345678',
    customer_key: 'C100',
    lines: [{ part_id: 'P1', qty: 1, part_confirmed: true, customer_part_ref: 801150250 }],
  }
  const p = draftPayload({ ...base, po_number: 197065, no_po_confirmed: true }, true)
  eq(p.po_number, '197065', 'a numeric PO is forwarded, not dropped')
  eq((p.lines as Row[])[0].customer_part_ref, '801150250', 'a numeric PO item number is forwarded')
  eq(draftPayload({ ...base, po_number: '  4471-A ' }, true).po_number, '4471-A', 'a string is trimmed as before')
  const big = (() => {
    try {
      draftPayload({ ...base, po_number: 12345678901234567890 }, true)
    } catch (e) {
      return e as OrderToolError
    }
    return null
  })()
  assert(big instanceof OrderToolError && big.code === 'invalid_input' && /as a string/.test(big.message),
    'an integer too large to be exact is refused, not rounded')
})

Deno.test('optional PO: the update path says to resend the PO; a removed PO is refused with that advice', () => {
  assert(/On update_order_draft, send the PO already on the draft again as po_number/.test(ORDERING_INSTRUCTIONS.replace(/\s+/g, ' ')),
    'instructions: resend the PO on update')
  const noPo = orderToolError({ message: 'po_confirmation_required: no customer PO number was given' })
  assert(/On update_order_draft, send the PO already on the draft again/.test(noPo.message), 'po_confirmation_required says so')
  const removed = orderToolError({
    message: 'po_would_be_removed: this draft has the customer PO 197065; send it again as po_number',
  })
  eq(removed.outcome, 'refused', 'refused')
  assert(/as po_number/.test(removed.message) && /only a person removes a PO/.test(removed.message) && /portal/.test(removed.message),
    'resend it; only a person removes it, in the portal')
  assert(/197065/.test(removed.message), 'the stored PO the SQL named is in the text')
  const withDetail = orderToolError({ message: 'po_would_be_removed:197065: send it again' })
  assert(/customer PO \(197065\)/.test(withDetail.message), 'a PO in the detail is named')
  const schema = tool('update_order_draft').inputSchema as { properties: Record<string, { description: string }> }
  assert(/resend that PO as po_number/.test(schema.properties.no_po_confirmed.description), 'no_po_confirmed never removes a PO')
  assert(/written to the sales order in the ERP/.test(schema.properties.notes.description) &&
    /internal remarks/.test(schema.properties.notes.description), 'notes: written to the ERP, no internal remarks')
  eq(hasCustomerPo('PORTAL-41', 41), false, 'PORTAL-<own id> is no customer PO')
  eq(hasCustomerPo('portal-41', 41), false, 'in any letter case, as the SQL compares upper(po)')
  eq(hasCustomerPo(' Portal-41 ', 41), false, 'trimmed, then any case')
  eq(hasCustomerPo('  \t', 41), false, 'blank after trimming no-break spaces')
  eq(hasCustomerPo('PORTAL-42', 41), true, 'another order\'s reference is just text here (SQL refuses it on write)')
  eq(hasCustomerPo('197065', 41), true, 'a real PO')
})

Deno.test('errors: new SQL codes read as instructions (not_owner, ship_date_past, order_not_found)', () => {
  const owner = orderToolError({ message: "not_owner: only the order's owner or an admin can set prices on it" })
  assert(owner.outcome === 'refused' && /inside sales prices and submits only/.test(owner.message) &&
    /an admin submits anyone's/.test(owner.message), 'not_owner explains D1')
  const past = decoratePreview({
    ...PREVIEW,
    would_submit: { ok: false, error: 'ship_date_past: the requested ship date 2026-11-01 has passed; change it before submitting' },
  })
  const hint = String((past.would_submit as Row).hint)
  assert(/Ask the user\s+for a new date/.test(hint) && /update_order_draft/.test(hint), `ship_date_past hint: ${hint}`)
  const missing = orderToolError({ message: 'order_not_found: order 9 not found' })
  assert(/list_my_order_drafts/.test(missing.message) && /owner/.test(missing.message), 'order_not_found: whose drafts can change')
  const hand = orderToolError({ message: 'admin_price_requires_admin: order 9 has 1 line(s) priced by hand' })
  assert(/only an admin, or inside sales on their own order/.test(hand.message), 'hand-priced submit: D1 wording')
})

Deno.test('errors: a pricing caller is never told that prices are never accepted', () => {
  for (const [message, own] of [
    ['invalid_input:unit_price: line P1 has 1.234; use 0-1,000,000 with at most 2 decimals', /at most 2 decimals/],
    ['invalid_input:price_override_reason: 2 line(s) are admin-priced or unmatched; say why', /say why in\s+price_override_reason/],
    ['invalid_input:duplicate_line:P1: the part appears twice at the same price', /one line with the\s+total qty/],
    ['invalid_input:qty: must be a whole number', /Fix it and retry/],
  ] as const) {
    const priced = orderToolError({ message }, true)
    assert(!/prices?[^.]*never\s+accepted/i.test(priced.message), `pricing caller, ${message}: no "prices are never accepted"`)
    assert(own.test(priced.message), `pricing caller, ${message}: its own sentence`)
  }
  // A rep is still told, for the generic case.
  assert(/never accepted/.test(orderToolError({ message: 'invalid_input:qty: must be a whole number' }).message), 'rep: generic')
})

Deno.test('errors: a rep is never told to send unit_price 0 for a duplicate line', () => {
  // A rep earns duplicate_line from one part on two list-priced lines, and
  // draftPayload refuses a rep's unit_price, so the advice is one line.
  const rep = orderToolError(
    { message: 'invalid_input:duplicate_line:P1: the part appears twice at the same price; send one line with the total qty' },
    false,
  )
  eq(rep.outcome, 'refused', 'refused')
  assert(/one line with the total qty/.test(rep.message), `rep: one line (${rep.message})`)
  assert(!/unit_price/.test(rep.message.split(' [')[0]), `rep: never told to send a unit_price (${rep.message})`)
  assert(/an admin prices them in the\s+portal/.test(rep.message), 'rep: free goods are an admin\'s, in the portal')
})

Deno.test('errors: through the handler, inside sales gets the pricing wording', async () => {
  const { db } = fakeDb({
    mcp_create_order_draft: raise('invalid_input:duplicate_line:P1: the part appears twice at the same price; send one line with the total qty'),
    mcp_log_call: ok(null),
  })
  const err = await rejects(tool('create_order_draft').handler(GOOD_ARGS, ctxFor(db, INSIDE())))
  assert(!/never accepted/.test(err.message) && /free goods/.test(err.message), `duplicate line: ${err.message}`)

  // A key a pricing caller may not send either is refused locally, without
  // claiming prices are never accepted.
  const local = fakeDb({ mcp_log_call: ok(null) })
  const top = await rejects(tool('create_order_draft').handler({ ...GOOD_ARGS, unit_price: 5 }, ctxFor(local.db, INSIDE())))
  assert(/unit_price cannot be sent/.test(top.message) && /only as a line's unit_price/.test(top.message) &&
    !/never accepted: the server prices/.test(top.message), `top-level price: ${top.message}`)
})

Deno.test('wording: the pricing schemas served to inside sales say admin or inside sales', () => {
  const inside = toolsFor(INSIDE(), setting(true), true)
  const served = JSON.stringify(inside.filter((t) => ['create_order_draft', 'update_order_draft', 'resolve_order_parts'].includes(t.name)).map(describeTool))
  assert(!/Admin only|As an admin you|only an admin can submit/.test(served), 'no admin-only wording left')
  const create = inside.find((t) => t.name === 'create_order_draft')!
  assert(/As an admin or inside sales you may/.test(create.description), 'create: admin or inside sales')
  assert(/inside sales prices and submits only their own drafts/.test(create.description) &&
    /an admin\s+submits anyone's/.test(create.description), 'create: D1')
  assert(/no_customer_po/.test(create.description) && /no_po_confirmed/.test(create.description), 'create: the no-PO path')
  const lines = (create.inputSchema as { properties: { lines: Row; price_override_reason: Row } }).properties
  assert(/admin or inside sales/.test(String(lines.lines.description)), 'lines: admin or inside sales')
  assert(/Admin or inside sales/.test(String(((lines.lines.items as Row).properties as Record<string, Row>).unit_price.description)), 'unit_price')
  assert(/Admin or inside sales/.test(String(lines.price_override_reason.description)), 'price_override_reason')
  assert(/admin or inside sales/.test(ADMIN_ORDERING_INSTRUCTIONS) &&
    /inside\s+sales prices and submits only their own drafts/.test(ADMIN_ORDERING_INSTRUCTIONS), 'admin paragraph: D1')
  // A rep's create tool still says no price can be passed.
  const repCreate = toolsFor(REP(), setting(true), true).find((t) => t.name === 'create_order_draft')!
  assert(/No price or FFL can be passed/.test(repCreate.description), 'rep wording unchanged')
})

Deno.test('wording: unmatched items in resolve_order_parts name inside sales too', async () => {
  const { db } = fakeDb({ order_resolve_parts: ok({ items: [{ index: 0, ref: 'NOPE', status: 'unmatched', candidates: [] }] }) })
  const res = (await tool('resolve_order_parts').handler({ customer_key: 'C1', items: [{ ref: 'NOPE' }] }, ctxFor(db))) as Row
  assert((res.guidance as string[]).some((g) => /an admin or inside sales/.test(g)), 'guidance')
})

/*----------------------------------------------------------------------------
  get_order_status and list_my_order_drafts
----------------------------------------------------------------------------*/

Deno.test('status: the header an update must send back is returned', async () => {
  const { db, tableCalls } = fakeDb({}, {
    orders: { id: 41, status: 'submitted', source: 'mcp', po_number: 'PORTAL-41', notes: 'Back door', customer_contact_key: '78' },
    order_lines: [],
    order_qc_results: [],
  })
  const res = (await tool('get_order_status').handler({ order_id: 41 }, ctxFor(db))) as Row
  const cols = tableCalls[0].columns
  for (const c of ['notes', 'customer_contact_key', 'po_number', 'requested_ship_date', 'erp_order_number']) {
    assert(cols.includes(c), `get_order_status selects ${c}`)
  }
  eq([res.notes, res.customer_contact_key], ['Back door', '78'], 'returned')
  eq(res.no_customer_po, true, 'PORTAL-<id> is flagged as no customer PO')
  assert(/exact: true/.test(tool('get_order_status').description), 'the description says to use the exact lookup row')
})

Deno.test('list: scope "mine" is the default and filters by owner; erp_order_number comes back', async () => {
  const { db, tableCalls, rpcCalls } = fakeDb({}, {
    orders: [{ id: 5, user_id: TYLER, status: 'entered', source: 'mcp', erp_order_number: 'CO-77120', po_number: 'PO-1' }],
  })
  const res = (await tool('list_my_order_drafts').handler({ status: 'entered' }, ctxFor(db, REP()))) as { scope: string; orders: Row[] }
  eq(res.scope, 'mine', 'default scope')
  eq(tableCalls[0].filters, [['user_id', TYLER], ['status', 'entered'], ['source', 'mcp']], 'own orders')
  assert(tableCalls[0].columns.includes('erp_order_number'), 'erp_order_number selected')
  eq(res.orders[0].erp_order_number, 'CO-77120', 'erp_order_number returned')
  assert(!('owner_user_id' in res.orders[0]) && !('user_id' in res.orders[0]), 'no owner columns on "mine"')
  eq(rpcCalls.length, 0, 'no owner-name lookup for "mine"')
})

Deno.test('list: scope "everyone" is for an admin or inside sales, and names each owner', async () => {
  const refused = fakeDb({}, { orders: [] })
  const err = await rejects(tool('list_my_order_drafts').handler({ scope: 'everyone' }, ctxFor(refused.db, REP())))
  assert(err instanceof ToolError && /only for an admin or inside sales/.test(err.message), `rep refused: ${err.message}`)
  eq(refused.tableCalls.length, 0, 'nothing read for a refused scope')
  const bad = await rejects(tool('list_my_order_drafts').handler({ scope: 'all' }, ctxFor(refused.db, INSIDE())))
  assert(/"mine".*"everyone"/.test(bad.message), 'an unknown scope is named')

  const { db, tableCalls, rpcCalls } = fakeDb({
    order_owner_names: ok([{ user_id: OTHER, display_name: 'Field Rep', role: 'rep' }]),
  }, {
    orders: [
      { id: 7, user_id: OTHER, status: 'submitted', source: 'portal', po_number: null, customer_key: 'C100' },
      { id: 6, user_id: TYLER, status: 'submitted', source: 'mcp', po_number: 'PO-9', customer_key: 'C100' },
    ],
  })
  const res = (await tool('list_my_order_drafts').handler(
    { scope: 'everyone', status: 'submitted', source: 'any', customer_key: 'C100' },
    ctxFor(db, INSIDE()),
  )) as { scope: string; orders: Row[] }
  eq(tableCalls[0].filters, [['status', 'submitted'], ['customer_key', 'C100']], 'no owner filter; RLS decides')
  eq(rpcCalls[0], { name: 'order_owner_names', params: { p_user_ids: [OTHER, TYLER] } }, 'one owner-name lookup')
  eq([res.orders[0].owner_user_id, res.orders[0].owner_name, res.orders[0].owner_role, res.orders[0].no_customer_po],
    [OTHER, 'Field Rep', 'rep', true], 'the owner, by name')
  eq([res.orders[1].owner_user_id, res.orders[1].mine, res.orders[1].owner_name], [TYLER, true, undefined],
    'own row marked; an id with no name keeps the id')

  // Without order_owner_names the rows still come back, by owner id.
  const old = fakeDb({ order_owner_names: raise('function order_owner_names does not exist') }, {
    orders: [{ id: 7, user_id: OTHER, status: 'draft', source: 'mcp' }],
  })
  const fallback = (await tool('list_my_order_drafts').handler({ scope: 'everyone' }, ctxFor(old.db))) as { orders: Row[] }
  eq([fallback.orders[0].owner_user_id, fallback.orders[0].owner_name], [OTHER, undefined], 'owner id only')
})

/*----------------------------------------------------------------------------
  Order documents
----------------------------------------------------------------------------*/

Deno.test('order documents: object names follow the portal rule', () => {
  eq(sanitizeDocumentName('PO 197065 (signed).pdf'), 'PO_197065_signed.pdf', 'spaces and brackets become one _')
  eq(sanitizeDocumentName('注文書.pdf'), 'file.pdf', 'a non-Latin name keeps its extension')
  eq(sanitizeDocumentName('.pdf.pdf'), 'pdf.pdf', 'a dot-leading name keeps its extension')
  eq(orderDocumentPath(4321, 'PO 1.pdf', 1700000000000), '4321/1700000000000-PO_1.pdf', 'order folder, timestamp, name')
  eq(documentDisplayName('1700000000000-PO_1.pdf'), 'PO_1.pdf', 'the timestamp prefix is not shown')
  eq(documentDisplayName('2024-report.pdf'), '2024-report.pdf', 'a short number is part of the name')
})

function withStorage(db: SupabaseClient, storage: Record<string, unknown>): SupabaseClient {
  ;(db as unknown as { storage: unknown }).storage = { from: () => storage }
  return db
}

Deno.test('attach_order_document: a signed upload URL, the exact content type, audited with the object name', async () => {
  const fake = fakeDb({ mcp_log_call: ok(null) }, { orders: [{ id: 4321, status: 'submitted' }] })
  const signed: string[] = []
  const db = withStorage(fake.db, {
    createSignedUploadUrl: (name: string) => {
      signed.push(name)
      return Promise.resolve({ data: { signedUrl: 'https://x.test/upload?token=t', path: name }, error: null })
    },
  })
  const out = (await tool('attach_order_document').handler(
    { order_id: 4321, file_name: 'RE: PO 197065.msg' },
    { db, caller: REP() },
  )) as Record<string, unknown>
  eq(out.upload_url, 'https://x.test/upload?token=t', 'the URL is returned')
  assert(/^4321\/\d{13}-RE_PO_197065\.msg$/.test(signed[0]), `object name (portal rule): ${signed[0]}`)
  eq(out.object_name, signed[0], 'and reported')
  eq(out.content_type, 'application/vnd.ms-outlook', 'the exact content type for .msg')
  const how = String(out.how)
  assert(how.includes('-H "Content-Type: application/vnd.ms-outlook"'), `curl line carries it: ${how}`)
  assert(/required/.test(how) && /415/.test(how), 'the header is required; 415 means a wrong type')
  const log = fake.rpcCalls.find((c) => c.name === 'mcp_log_call')!
  eq([log.params.p_tool, log.params.p_outcome, log.params.p_order_id], ['attach_order_document', 'ok', 4321], 'audited')
  eq((log.params.p_args as Row).object_name, signed[0], 'the audit row names the stored object')
  assert(!JSON.stringify(log.params).includes('token=t'), 'the upload URL is never logged')
})

Deno.test('attach_order_document: an order the caller cannot see is a refusal, logged against no order', async () => {
  const fake = fakeDb({ mcp_log_call: ok(null) }, { orders: [] })
  let asked = false
  const db = withStorage(fake.db, {
    createSignedUploadUrl: () => {
      asked = true
      return Promise.resolve({ data: null, error: null })
    },
  })
  const err = await rejects(tool('attach_order_document').handler({ order_id: 9, file_name: 'x.pdf' }, { db, caller: REP() }))
  assert(err instanceof OrderToolError && err.outcome === 'refused' && err.code === 'order_not_found', 'refused, coded')
  assert(/^No order 9 that you can see/.test(err.message) && !/service failed/.test(err.message), `plain sentence: ${err.message}`)
  assert(!asked, 'storage was never asked')
  const log = fake.rpcCalls.find((c) => c.name === 'mcp_log_call')!
  eq([log.params.p_outcome, log.params.p_order_id], ['refused', null], 'refused, against no order')
})

Deno.test('attach_order_document: a file type the bucket refuses gets no URL', async () => {
  for (const name of ['scan.tif', 'po.xlsm', 'Scan', 'po.gif']) {
    const fake = fakeDb({ mcp_log_call: ok(null) }, { orders: [{ id: 4321, status: 'draft' }] })
    let asked = false
    const db = withStorage(fake.db, {
      createSignedUploadUrl: () => {
        asked = true
        return Promise.resolve({ data: { signedUrl: 'x' }, error: null })
      },
    })
    const err = await rejects(tool('attach_order_document').handler({ order_id: 4321, file_name: name }, { db, caller: REP() }))
    assert(err instanceof OrderToolError && err.outcome === 'refused', `${name}: refused`)
    assert(/\.pdf, \.xlsx/.test(err.message) && /\.msg/.test(err.message), `${name}: lists the accepted kinds`)
    assert(!asked, `${name}: no URL minted`)
    eq(fake.tableCalls.length, 0, `${name}: refused before any read`)
  }
  const bad = fakeDb({ mcp_log_call: ok(null) }, { orders: [] })
  const err = await rejects(tool('attach_order_document').handler({ order_id: 1.5, file_name: 'x.pdf' }, { db: withStorage(bad.db, {}), caller: REP() }))
  assert(err instanceof OrderToolError && /positive whole number/.test(err.message), 'a fractional order id is refused')
})

Deno.test('attach_order_document: the description says to use it only with a real HTTP PUT', () => {
  const d = tool('attach_order_document').description
  assert(/ONLY when you can make an HTTP PUT/.test(d) && /portal link/.test(d), 'only with a PUT, else the portal link')
  assert(/Only if you can make an HTTP PUT/.test(ORDERING_INSTRUCTIONS) && /do not call it/.test(ORDERING_INSTRUCTIONS),
    'instructions agree')
})

Deno.test('list_order_documents: one signing request, per-document link errors, has_more', async () => {
  const fake = fakeDb({}, { orders: [{ id: 4321, status: 'draft' }] })
  const listCalls: [string, Row][] = []
  const signCalls: [string[], number][] = []
  const db = withStorage(fake.db, {
    list: (prefix: string, opts: Row) => {
      listCalls.push([prefix, opts])
      return Promise.resolve({
        data: [
          { id: 'o2', name: '1700000000001-PO_2.pdf', created_at: '2026-11-13T16:00:00Z',
            metadata: { size: 99, mimetype: 'application/pdf' } },
          { id: 'o1', name: '1700000000000-PO_1.pdf', created_at: '2026-11-13T15:00:00Z',
            metadata: { size: 1234, mimetype: 'application/pdf' } },
          { id: null, name: 'sub' },
          { id: 'p', name: '.emptyFolderPlaceholder' },
        ],
        error: null,
      })
    },
    createSignedUrls: (paths: string[], seconds: number) => {
      signCalls.push([paths, seconds])
      return Promise.resolve({
        data: [
          { path: paths[0], signedUrl: null, error: 'Either the object does not exist or you do not have access to it' },
          { path: paths[1], signedUrl: `https://x.test/get/${paths[1]}`, error: null },
        ],
        error: null,
      })
    },
    createSignedUrl: () => {
      throw new Error('one request per file is not used any more')
    },
  })
  const out = (await tool('list_order_documents').handler({ order_id: 4321 }, { db, caller: REP() })) as {
    documents: Row[]
    has_more: boolean
    note: string
  }
  eq(listCalls[0][0], '4321', 'the order folder (Storage reads it as 4321/)')
  eq(listCalls[0][1].limit, 101, 'one more than shown, to know about the rest')
  eq(signCalls, [[['4321/1700000000001-PO_2.pdf', '4321/1700000000000-PO_1.pdf'], 600]], 'one signing call, 10 minutes')
  eq(out.documents.length, 2, 'folders and placeholders are not documents')
  eq([out.documents[0].name, out.documents[0].url, typeof out.documents[0].link_error], ['PO_2.pdf', undefined, 'string'],
    'a failed link says why')
  eq(
    [out.documents[1].name, out.documents[1].size_bytes, out.documents[1].content_type, out.documents[1].url],
    ['PO_1.pdf', 1234, 'application/pdf', 'https://x.test/get/4321/1700000000000-PO_1.pdf'],
    'display name, size, type and link',
  )
  eq(out.has_more, false, 'all listed')
  assert(/link_error/.test(out.note), 'the note mentions the missing link')

  // 101 documents: 100 shown, has_more.
  const many = Array.from({ length: 101 }, (_, i) => ({ id: `o${i}`, name: `${1700000000000 + i}-PO_${i}.pdf` }))
  const big = withStorage(fakeDb({}, { orders: [{ id: 4321 }] }).db, {
    list: () => Promise.resolve({ data: many, error: null }),
    createSignedUrls: (paths: string[]) =>
      Promise.resolve({ data: paths.map((p) => ({ path: p, signedUrl: `https://x.test/${p}`, error: null })), error: null }),
  })
  const res = (await tool('list_order_documents').handler({ order_id: 4321 }, { db: big, caller: REP() })) as {
    documents: Row[]
    has_more: boolean
    note: string
  }
  eq([res.documents.length, res.has_more], [100, true], '100 shown, more exist')
  assert(/newest 100/.test(res.note), 'and the note says so')

  // The whole signing call failing: every document says why.
  const down = withStorage(fakeDb({}, { orders: [{ id: 4321 }] }).db, {
    list: () => Promise.resolve({ data: many.slice(0, 2), error: null }),
    createSignedUrls: () => Promise.resolve({ data: null, error: { message: 'storage unavailable' } }),
  })
  const none = (await tool('list_order_documents').handler({ order_id: 4321 }, { db: down, caller: REP() })) as { documents: Row[] }
  eq(none.documents.map((d) => d.link_error), ['storage unavailable', 'storage unavailable'], 'per document')

  // An order the caller cannot see: the same refusal as attach.
  const hidden = withStorage(fakeDb({}, { orders: [] }).db, {})
  const err = await rejects(tool('list_order_documents').handler({ order_id: 9 }, { db: hidden, caller: REP() }))
  assert(err instanceof OrderToolError && err.code === 'order_not_found', 'order_not_found')
})
