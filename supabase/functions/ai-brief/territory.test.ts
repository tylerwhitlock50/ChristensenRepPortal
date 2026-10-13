/*============================================================================
  territory.test.ts — the territory brief's cache key, and the check on the
  model's tagged headlines.

      deno test --allow-env supabase/functions/

  No network, no database: the queries run against a stub client that
  answers each one from fixtures.
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { canonical, sha256Hex } from '../_shared/ai.ts'
import { buildTerritoryContext, parseBriefOutput, territoryPromptPayload } from './territory.ts'

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}
function assertEquals(got: unknown, want: unknown, what: string): void {
  const g = JSON.stringify(got)
  const w = JSON.stringify(want)
  if (g !== w) throw new Error(`FAILED: ${what}\n  got:  ${g}\n  want: ${w}`)
}

type Call = [string, unknown[]]

/** A client whose every query resolves to resolver(relation, calls). */
function stubClient(resolver: (relation: string, calls: Call[]) => unknown): SupabaseClient {
  const builder = (relation: string, calls: Call[]): unknown =>
    new Proxy(
      {},
      {
        get(_t, prop) {
          if (prop === 'then') {
            return (resolve: (v: unknown) => void) => resolve(resolver(relation, calls))
          }
          return (...args: unknown[]) => builder(relation, [...calls, [String(prop), args]])
        },
      },
    )
  return {
    from: (name: string) => builder(name, []),
    rpc: (name: string, params?: unknown) => builder(`rpc:${name}`, [['rpc', [params]]]),
  } as unknown as SupabaseClient
}

const account = (key: string, name: string, extra: Record<string, unknown> = {}) => ({
  customer_key: key,
  customer_name: name,
  sold_to_city: 'Bozeman',
  sold_to_state: 'MT',
  revenue_ytd: 50_000,
  revenue_prior_ytd: 40_000,
  revenue_trailing_12m: 60_000,
  last_invoice_date: '2026-09-30',
  open_order_value: 8_000,
  backlog_amount: 1_000,
  yoy_change_amount: 10_000,
  ...extra,
})

const GOAL_ROLLUP = { accounts_with_goal: 10, accounts_behind: 4, target_total: 1_200_000,
                      attainment_pct: 75, expected_pct: 78.2 }

const NOT_DEPLOYED = { data: null, error: { code: 'PGRST202', message: 'Could not find the function' } }

/** The rollups were rebuilt at 5:10 PM Mountain on Oct 12 (23:10Z). */
const FACTS = {
  figures_refreshed_at: '2026-10-12T23:10:00+00:00', bookings_ytd: 1_000_000,
  bookings_prior_ytd: 800_000, new_accounts_ytd: 3, orders_14d_count: 41,
  orders_14d_amount: 260_000, orders_14d_since: '2026-09-29',
}

const MIX = [
  { grain: 'family', product_family: 'Mesa', part_id: null, part_description: null, chambering: null,
    revenue: 120_000, qty: 80, prior_revenue: 100_000, prior_qty: 70,
    period_start: '2026-01-01', period_end: '2026-09-01', prior_start: '2025-01-01', prior_end: '2025-09-01' },
  { grain: 'family', product_family: 'Ridgeline', part_id: null, part_description: null, chambering: null,
    revenue: 0, qty: 0, prior_revenue: 40_000, prior_qty: 20,
    period_start: '2026-01-01', period_end: '2026-09-01', prior_start: '2025-01-01', prior_end: '2025-09-01' },
  { grain: 'sku', product_family: 'Mesa', part_id: 'MPR-308', part_description: 'Mesa 308', chambering: '308 WIN',
    revenue: 60_000, qty: 40, prior_revenue: 50_000, prior_qty: 35,
    period_start: '2026-01-01', period_end: '2026-09-01', prior_start: '2025-01-01', prior_end: '2025-09-01' },
]

type Options = {
  goalRollup?: Record<string, unknown>
  facts?: Record<string, unknown> | null
  mix?: Record<string, unknown>[] | null
  admin?: boolean
  dataThrough?: string
}

function territory(
  goalRollup: Record<string, unknown> = GOAL_ROLLUP,
  opts: Omit<Options, 'goalRollup'> = {},
): SupabaseClient {
  const facts = opts.facts === undefined ? FACTS : opts.facts
  const mix = opts.mix === undefined ? MIX : opts.mix
  return stubClient((relation, calls) => {
    const has = (method: string, column?: string) =>
      calls.some(([m, args]) => m === method && (column === undefined || args[0] === column))
    switch (relation) {
      case 'rpc:report_territory_summary':
        return {
          data: {
            accounts: 42, accounts_with_ytd_revenue: 30, revenue_ytd: 900_000,
            revenue_prior_ytd: 850_000, revenue_trailing_12m: 1_100_000,
            open_order_value: 120_000, backlog_amount: 30_000,
          },
          error: null,
        }
      case 'v_my_goal_rollup':
        return { data: goalRollup, error: null }
      case 'v_territory_account_yoy':
        if (has('lt', 'last_invoice_date')) {
          return { data: [account('C9', 'Canyon Creek', { last_invoice_date: '2026-06-05' })], error: null, count: 3 }
        }
        if (has('lt', 'yoy_change_amount')) {
          return { data: [account('C3', 'Ridgeline Guns', { yoy_change_amount: -21_000 })], error: null, count: 7 }
        }
        if (has('gt', 'yoy_change_amount')) {
          return { data: [account('C2', 'Big Sky Sporting')], error: null, count: 12 }
        }
        return { data: [account('C1', 'Fixture Outfitters'), account('C2', 'Big Sky Sporting')], error: null }
      case 'v_territory_recent_orders':
        return {
          data: [{ customer_key: 'C7', customer_name: 'Teton Range', order_date: '2026-10-08',
                   order_id: 'O9', order_amount: 4_200, has_backlog: true }],
          error: null,
          count: 17,
        }
      case 'v_territory_sku_sales':
        return { data: [{ part_id: 'OLD-1', part_description: 'Old list', product_family: 'Mesa',
                          chambering: '308 WIN', revenue: 9_000, qty: 6 }], error: null }
      case 'v_data_freshness':
        // Moves every business day, whatever this book did.
        return { data: { data_through: opts.dataThrough ?? '2026-10-09' }, error: null }
      case 'rpc:report_territory_brief_facts':
        return facts === null ? NOT_DEPLOYED : { data: facts, error: null }
      case 'rpc:report_territory_product_mix':
        return mix === null ? NOT_DEPLOYED : { data: mix, error: null }
      case 'rpc:is_admin':
        return { data: opts.admin === true, error: null }
      default:
        return { data: [], error: null }
    }
  })
}

const hashOf = async (v: unknown) => await sha256Hex(JSON.stringify(canonical(v)))

Deno.test('the hashed territory context does not move with the calendar', async () => {
  const oct13 = await buildTerritoryContext(territory(), '', new Date('2026-10-13T13:00:00Z'))
  const oct14 = await buildTerritoryContext(territory(), '', new Date('2026-10-14T13:00:00Z'))
  assertEquals(await hashOf(oct13.context), await hashOf(oct14.context), 'Oct 13 vs Oct 14')
  const hashed = JSON.stringify(oct13.context)
  assert(!hashed.includes('days_since_invoice'), 'no day counts in the hash')
  assert(!hashed.includes('data_through'), 'the warehouse watermark is not in the hash')
})

Deno.test('goal pace moves with the clock: in the payload, not the hash', async () => {
  // v_my_goal_rollup.expected_pct and accounts_behind come from current_date
  // (v_account_goal_progress), so they differ between two days of the same
  // data. Only target and attainment are data.
  const paced = (expected: number, behind: number) =>
    territory({ accounts_with_goal: 10, accounts_behind: behind, target_total: 1_200_000,
                attainment_pct: 75, expected_pct: expected })
  const oct13 = await buildTerritoryContext(paced(78.2, 4), '', new Date('2026-10-13T13:00:00Z'))
  const oct14 = await buildTerritoryContext(paced(78.5, 5), '', new Date('2026-10-14T13:00:00Z'))
  assertEquals(await hashOf(oct13.context), await hashOf(oct14.context), 'pace moved, data did not')
  assertEquals(oct13.context.goal, { target: 1_200_000, attainment_pct: 75, accounts_with_goal: 10 }, 'hashed goal is data only')
  const payload = territoryPromptPayload(oct14, new Date('2026-10-14T13:00:00Z'))
  assertEquals(payload.goal, {
    target: 1_200_000, attainment_pct: 75, accounts_with_goal: 10,
    expected_pct: 78.5, accounts_behind_pace: 5,
  }, 'the model reads today\'s pace on `goal`, where the prompt describes it')
})

Deno.test('the model still gets day counts, the watermark and today', async () => {
  const today = new Date('2026-10-13T13:00:00Z')
  const built = await buildTerritoryContext(territory(), '', today)
  const payload = territoryPromptPayload(built, today)
  assertEquals(payload.dormant[0].days_since_invoice, 130, 'Jun 5 → Oct 13')
  assertEquals(payload.data_through, '2026-10-09', 'data_through')
  assertEquals(payload.today, '2026-10-13', 'today')
})

Deno.test('every account in the context carries its key, and is a valid chip target', async () => {
  const built = await buildTerritoryContext(territory(), '', new Date('2026-10-13T13:00:00Z'))
  assertEquals(built.context.top_accounts[0].customer_key, 'C1', 'top accounts keyed')
  assertEquals(built.context.recent_orders.largest[0].customer_key, 'C7', 'recent orders keyed')
  assertEquals(
    Object.keys(built.subjects).sort(),
    ['C1', 'C2', 'C3', 'C7', 'C9'],
    'subjects = every key the model was shown',
  )
  assertEquals(built.subjects.C9, 'Canyon Creek', 'names come from the context')
})

Deno.test('headline keys are kept only when they were in the context', () => {
  const subjects = { C1: 'Fixture Outfitters', C9: 'Canyon Creek' }
  const reply = JSON.stringify({
    content: 'HEADLINES\n• Territory up 6%\n• Canyon Creek quiet since June\n\nBody.',
    headlines: [
      { text: 'Territory up 6%', customer_key: null },
      { text: '• Canyon Creek quiet since June', customer_key: 'C9' },
      { text: 'Somebody else up 40%', customer_key: 'C404' },
      { text: '   ', customer_key: 'C1' },
    ],
  })
  const out = parseBriefOutput(reply, subjects)
  assert(out.content.startsWith('HEADLINES'), 'prose kept for the deployed card')
  assertEquals(out.items, {
    headlines: [
      { text: 'Territory up 6%', customer_key: null, account_name: null },
      { text: 'Canyon Creek quiet since June', customer_key: 'C9', account_name: 'Canyon Creek' },
      { text: 'Somebody else up 40%', customer_key: null, account_name: null },
    ],
  }, 'invented key nulled, bullet stripped, empty headline dropped')
})

Deno.test('a reply that is not JSON is kept as prose, with no items', () => {
  const out = parseBriefOutput('HEADLINES\n• Flat year\n\nNothing moved.', {})
  assertEquals(out.items, null, 'no items')
  assert(out.content.includes('Flat year'), 'prose kept')
})

Deno.test('JSON cut off at the token ceiling is an error, never stored as prose', () => {
  const full = JSON.stringify({
    content: 'HEADLINES\n• Territory up 8%\n\nA steady month.',
    headlines: [{ text: 'Territory up 8%', customer_key: null }],
  })
  let threw = false
  try {
    parseBriefOutput(full.slice(0, 40), {})
  } catch {
    threw = true
  }
  assert(threw, 'a truncated object throws instead of becoming the brief')
})

Deno.test('JSON with no content is an error, not an empty brief', () => {
  let threw = false
  try {
    parseBriefOutput(JSON.stringify({ content: ' ', headlines: [] }), {})
  } catch {
    threw = true
  }
  assert(threw, 'empty content throws')
})

Deno.test('a key that is an Object prototype name is not an account', () => {
  const out = parseBriefOutput(
    JSON.stringify({ content: 'HEADLINES\n• x', headlines: [{ text: 'x', customer_key: 'constructor' }] }),
    { C1: 'Fixture Outfitters' },
  )
  assertEquals(out.items?.headlines[0].customer_key, null, 'constructor is not in subjects')
})

/*----------------------------------------------------------------------------
  v3.0.0 — what the brief was missing
----------------------------------------------------------------------------*/

const OCT13 = new Date('2026-10-13T13:00:00Z')

Deno.test('figures carry the rollup rebuild date, and say when newer invoices exist', async () => {
  // Rebuilt Oct 12 (Mountain); the warehouse has invoices through Oct 9 → current.
  const current = await buildTerritoryContext(territory(), '', OCT13)
  assertEquals(current.context.figures_as_of, '2026-10-12', 'Mountain date of the rebuild')
  assertEquals(current.context.figures_behind_newer_invoices, false, 'not behind')

  // The 2026-10-13 incident: rebuilt Oct 3, invoices through Oct 9.
  const stale = await buildTerritoryContext(
    territory(GOAL_ROLLUP, {
      facts: { ...FACTS, figures_refreshed_at: '2026-10-03T23:10:00+00:00' },
      dataThrough: '2026-10-09',
    }),
    '',
    OCT13,
  )
  assertEquals(stale.context.figures_as_of, '2026-10-03', 'figures are from Oct 3')
  assertEquals(stale.context.figures_behind_newer_invoices, true, 'and the warehouse is ahead')

  // A rebuild just after midnight UTC is still the evening before in Mountain.
  const lateEvening = await buildTerritoryContext(
    territory(GOAL_ROLLUP, { facts: { ...FACTS, figures_refreshed_at: '2026-10-13T03:30:00+00:00' } }),
    '',
    OCT13,
  )
  assertEquals(lateEvening.context.figures_as_of, '2026-10-12', '03:30Z is 9:30 PM Mountain')
})

Deno.test('windows are anchored on the rebuild date, not the wall clock', async () => {
  let dormantCutoff: unknown
  let mixParams: unknown
  const base = territory(GOAL_ROLLUP, {
    facts: { ...FACTS, figures_refreshed_at: '2026-10-03T23:10:00+00:00' },
  })
  // Wrap the stub to capture the arguments the builder sends.
  const spy = {
    from: (name: string) => {
      const b = base.from(name) as unknown as Record<string, (...a: unknown[]) => unknown>
      if (name !== 'v_territory_account_yoy') return b
      return new Proxy(b, {
        get(t, prop) {
          const f = (t as Record<string | symbol, unknown>)[prop]
          if (prop !== 'select' || typeof f !== 'function') return f
          return (...args: unknown[]) => {
            const q = (f as (...a: unknown[]) => unknown)(...args)
            return wrapLt(q)
          }
        },
      })
    },
    rpc: (name: string, params?: unknown) => {
      if (name === 'report_territory_product_mix') mixParams = params
      return base.rpc(name, params as never)
    },
  } as unknown as SupabaseClient
  // deno-lint-ignore no-explicit-any
  function wrapLt(q: any): any {
    return new Proxy(q, {
      get(t, prop) {
        const f = t[prop]
        if (typeof f !== 'function' || prop === 'then') return f
        return (...args: unknown[]) => {
          if (prop === 'lt' && args[0] === 'last_invoice_date') dormantCutoff = args[1]
          return wrapLt(f(...args))
        }
      },
    })
  }
  await buildTerritoryContext(spy, '', OCT13)
  assertEquals(dormantCutoff, '2026-07-05', 'quiet = 90 days before Oct 3, not before today')
  assertEquals(mixParams, { p_through_month: '2026-09-01', p_sku_limit: 8 },
    'product mix through the last whole month before the rebuild')
})

Deno.test('accounts carry open orders and past-promise dollars, named for what they are', async () => {
  const built = await buildTerritoryContext(territory(), '', OCT13)
  const a = built.context.top_accounts[0]
  assertEquals([a.open_order_value, a.past_promise_amount], [8_000, 1_000], 'both on every account')
  assert(!('backlog_amount' in a), 'the misleading name is gone')
  assertEquals(built.context.totals.open_order_value, 120_000, 'totals: open orders')
  assertEquals(built.context.totals.past_promise_amount, 30_000, 'totals: past promise')
  assertEquals([built.context.totals.bookings_ytd, built.context.totals.bookings_prior_ytd],
    [1_000_000, 800_000], 'bookings')
  assertEquals(built.context.new_accounts_this_year, 3, 'new accounts')
})

Deno.test('recent orders: every order counted and totalled, the list is only the largest', async () => {
  const today = OCT13
  const built = await buildTerritoryContext(territory(), '', today)
  assertEquals(built.context.recent_orders.count, 41, 'all 41 orders, not the excerpt')
  assertEquals(built.context.recent_orders.total, 260_000, 'their total')
  assertEquals(built.context.recent_orders.largest.length, 1, 'the excerpt')
  assert(!JSON.stringify(built.context).includes('2026-09-29'), 'the window start is not hashed')
  const payload = territoryPromptPayload(built, today)
  assertEquals(payload.recent_orders.since, '2026-09-29', 'the model is told where the window starts')
  assertEquals(payload.recent_orders.count, 41, 'and keeps the count')
})

Deno.test('product mix over the same months, with the change worked out', async () => {
  const built = await buildTerritoryContext(territory(), '', OCT13)
  const mix = built.context.product_mix
  assertEquals(mix.this_period, { from: '2026-01-01', through_month: '2026-09-01' }, 'this period')
  assertEquals(mix.prior_period, { from: '2025-01-01', through_month: '2025-09-01' }, 'same months last year')
  assertEquals(mix.families.map((f: { family: string; change_pct: number | null }) => [f.family, f.change_pct]),
    [['Mesa', 20], ['Ridgeline', -100]], 'change_pct per family')
  assertEquals(mix.skus[0].part_id, 'MPR-308', 'leading SKUs')
  assert(!('top_skus' in built.context), 'no unequal-window lists when the mix is there')
})

Deno.test('scope says company for an admin, territory for everyone else', async () => {
  const rep = await buildTerritoryContext(territory(), '', OCT13)
  const admin = await buildTerritoryContext(territory(GOAL_ROLLUP, { admin: true }), '', OCT13)
  assertEquals([rep.context.scope, admin.context.scope], ['territory', 'company'], 'scope')
})

Deno.test('on a database without 20261013160000 the brief falls back, and stays stable', async () => {
  const old = (day: Date) =>
    buildTerritoryContext(territory(GOAL_ROLLUP, { facts: null, mix: null }), '', day)
  const oct13 = await old(OCT13)
  const oct14 = await old(new Date('2026-10-14T13:00:00Z'))
  assertEquals(await hashOf(oct13.context), await hashOf(oct14.context), 'hash stable across days')
  assertEquals(oct13.context.figures_as_of, null, 'no rebuild date to give')
  assertEquals(oct13.context.figures_behind_newer_invoices, false, 'never claims staleness it cannot see')
  assertEquals(oct13.context.recent_orders.count, 17, 'count from the slice\'s exact count')
  assertEquals(oct13.context.recent_orders.total, null, 'no total from an excerpt')
  assert(!('bookings_ytd' in oct13.context.totals), 'no bookings without the facts')
  assertEquals(oct13.context.top_skus[0].part_id, 'OLD-1', 'the old product lists come back')
  assert('top_skus_full_last_year' in oct13.context, 'with last year labelled as the full year')
  assert(!('product_mix' in oct13.context), 'and no mix')
})
