/*============================================================================
  orderTools.test.ts — order drafting over MCP: who sees the tools, what the
  write tools forward (never a price or an FFL), how SQL refusals read to the
  model, and that every write is logged without the log masking the result.

      deno test --allow-env --allow-net supabase/functions/mcp/
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import * as mcpAuth from '../_shared/mcpAuth.ts'
import { extractToken, jwtClaims, knownScopes, type McpCaller } from '../_shared/mcpAuth.ts'
import { describeTool, TOOLS, type ToolDef } from './tools.ts'
import {
  ADMIN_ORDERING_INSTRUCTIONS,
  decoratePreview,
  draftPayload,
  forbiddenKeysIn,
  type McpOrdersSetting,
  NEXT_STEP,
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
  const tableCalls: { table: string; filters: [string, unknown][] }[] = []

  function builder(table: string) {
    const filters: [string, unknown][] = []
    tableCalls.push({ table, filters })
    const result = () => {
      const data = tables[table]
      return { data: data ?? null, error: null }
    }
    const b: Record<string, unknown> = {
      select: () => b,
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

Deno.test('confirmations: schemas require the PO and part_confirmed', () => {
  for (const name of ['create_order_draft', 'update_order_draft']) {
    const schema = tool(name).inputSchema as {
      required: string[]
      properties: Record<string, { items?: { required: string[]; properties: Record<string, unknown> } }>
    }
    assert(schema.required.includes('po_number'), `${name}: po_number required`)
    for (const f of ['customer_confirmed', 'ship_to_confirmed', 'is_test']) {
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
