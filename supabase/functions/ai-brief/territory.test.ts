/*============================================================================
  territory.test.ts — the territory brief's cache key, and the check on the
  model's tagged headlines.

      deno test --allow-env supabase/functions/

  No network, no database: the queries run against a stub client that
  answers each one from fixtures.
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { canonical, sha256Hex } from '../_shared/ai.ts'
import {
  buildTerritoryContext,
  changePct,
  parseBriefOutput,
  productWindowEnd,
  territoryPromptPayload,
} from './territory.ts'

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
    schema: (schema: string) => ({ from: (name: string) => builder(`${schema}.${name}`, []) }),
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
                      revenue_total: 900_000, attainment_pct: 75, expected_pct: 78.2 }

const NOT_DEPLOYED = { data: null, error: { code: 'PGRST202', message: 'Could not find the function' } }

/** The rollups were rebuilt at 5:10 PM Mountain on Oct 12 (23:10Z). */
const FACTS = {
  figures_refreshed_at: '2026-10-12T23:10:00+00:00', bookings_ytd: 1_000_000,
  bookings_prior_ytd: 800_000, accounts_with_revenue_prior_ytd: 28,
  new_accounts_ytd: 3, new_accounts_revenue_ytd: 45_000, orders_14d_count: 41,
  orders_14d_amount: 260_000, orders_14d_since: '2026-09-29',
  largest_orders: [{ customer_key: 'C7', customer_name: 'Teton Range', order_id: 'O9',
                     order_date: '2026-10-08', amount: 4_200, has_open_lines: true }],
}

/** The facts the rollups are built from last loaded 5:02 PM Mountain, Oct 12. */
const LOADED_WITH_FIGURES = '2026-10-12T23:02:00+00:00'

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
  /** v_data_freshness.facts_loaded_at; null = an older view without it. */
  factsLoadedAt?: string | null
  /** Keys with an invoice in erp.fact_invoice_line after the figures. */
  invoicedSince?: string[]
  /** Override the movers-down row. */
  down?: Record<string, unknown>
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
          return { data: [account('C3', 'Ridgeline Guns', { yoy_change_amount: -21_000, ...(opts.down ?? {}) })],
                   error: null, count: 7 }
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
        // data_through moves every business day, whatever this book did.
        return {
          data: {
            data_through: opts.dataThrough ?? '2026-10-09',
            ...(opts.factsLoadedAt === null ? {} : { facts_loaded_at: opts.factsLoadedAt ?? LOADED_WITH_FIGURES }),
          },
          error: null,
        }
      case 'erp.fact_invoice_line':
        return { data: (opts.invoicedSince ?? []).map((k) => ({ customer_key: k })), error: null }
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
                revenue_total: 900_000, attainment_pct: 75, expected_pct: expected })
  const oct13 = await buildTerritoryContext(paced(78.2, 4), '', new Date('2026-10-13T13:00:00Z'))
  const oct14 = await buildTerritoryContext(paced(78.5, 5), '', new Date('2026-10-14T13:00:00Z'))
  assertEquals(await hashOf(oct13.context), await hashOf(oct14.context), 'pace moved, data did not')
  assertEquals(oct13.context.goal, { target: 1_200_000, attainment_pct: 75, accounts_with_goal: 10,
                                     revenue_toward_goal: 900_000 }, 'hashed goal is data only')
  const payload = territoryPromptPayload(oct14, new Date('2026-10-14T13:00:00Z'))
  assertEquals(payload.goal, {
    target: 1_200_000, attainment_pct: 75, accounts_with_goal: 10, revenue_toward_goal: 900_000,
    expected_pct: 78.5, accounts_behind_pace: 5,
  }, 'the model reads today\'s pace on `goal`, where the prompt describes it')
})

Deno.test('the model gets day counts and today on the business calendar', async () => {
  const today = new Date('2026-10-13T13:00:00Z')
  const built = await buildTerritoryContext(territory(), '', today)
  const payload = territoryPromptPayload(built, today)
  assertEquals(payload.dormant[0].days_since_invoice, 130, 'Jun 5 → Oct 13')
  assertEquals(payload.today, '2026-10-13', 'today')
  assert(!('data_through' in payload), 'the warehouse watermark is no longer the model\'s business')
  assertEquals(built.asOf.data_through, '2026-10-09', 'kept in asOf')

  // 8 PM Mountain on Oct 13 is already Oct 14 in UTC — not on our calendar.
  const evening = new Date('2026-10-14T02:00:00Z')
  const late = territoryPromptPayload(await buildTerritoryContext(territory(), '', evening), evening)
  assertEquals(late.today, '2026-10-13', 'Mountain date, not the UTC date')
  assertEquals(late.dormant[0].days_since_invoice, 130, 'and day counts on it')
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
  3.1.0 — what the brief was missing
----------------------------------------------------------------------------*/

const OCT13 = new Date('2026-10-13T13:00:00Z')

/** The 2026-10-13 incident: rebuilt Oct 3, facts loaded nightly since. */
const STALE = {
  facts: { ...FACTS, figures_refreshed_at: '2026-10-03T23:10:00+00:00' },
  factsLoadedAt: '2026-10-12T23:02:00+00:00',
}

Deno.test('figures are behind only when the facts loaded after the rebuild, per the ledger', async () => {
  const current = await buildTerritoryContext(territory(), '', OCT13)
  assertEquals(current.context.figures_behind_newer_invoices, false, 'loaded before the rebuild: current')
  assertEquals(current.context.figures_as_of, null, 'no date in the hash when current')
  assertEquals(current.asOf.figures_as_of, '2026-10-12', 'the real date rides in asOf')

  const stale = await buildTerritoryContext(territory(GOAL_ROLLUP, STALE), '', OCT13)
  assertEquals(stale.context.figures_behind_newer_invoices, true, 'facts loaded since Oct 3')
  assertEquals(stale.context.figures_as_of, '2026-10-03', 'Mountain date of the rebuild, in the hash')

  // Tonight's run in flight: facts swapped at 5:02 PM, rebuild not done yet.
  const inFlight = await buildTerritoryContext(
    territory(GOAL_ROLLUP, { facts: { ...FACTS, figures_refreshed_at: '2026-10-11T23:10:00+00:00' },
                            factsLoadedAt: '2026-10-12T23:02:00+00:00' }),
    '',
    new Date('2026-10-12T23:20:00Z'),
  )
  assertEquals(inFlight.context.figures_behind_newer_invoices, false, 'inside the grace window')

  // A future-dated invoice in the warehouse no longer decides anything.
  const future = await buildTerritoryContext(territory(GOAL_ROLLUP, { dataThrough: '2026-10-20' }), '', OCT13)
  assertEquals(future.context.figures_behind_newer_invoices, false, 'invoice dates are not the test')

  // An older v_data_freshness without facts_loaded_at: never claims staleness.
  const oldView = await buildTerritoryContext(territory(GOAL_ROLLUP, { ...STALE, factsLoadedAt: null }), '', OCT13)
  assertEquals(oldView.context.figures_behind_newer_invoices, false, 'unknown is not behind')

  // A rebuild just after midnight UTC is still the evening before in Mountain.
  const lateEvening = await buildTerritoryContext(
    territory(GOAL_ROLLUP, { facts: { ...FACTS, figures_refreshed_at: '2026-10-13T03:30:00+00:00' } }),
    '',
    OCT13,
  )
  assertEquals(lateEvening.asOf.figures_as_of, '2026-10-12', '03:30Z is 9:30 PM Mountain')
})

Deno.test('a healthy nightly rebuild does not by itself change the hash', async () => {
  const night = (refreshed: string, loaded: string, day: Date) =>
    buildTerritoryContext(
      territory(GOAL_ROLLUP, { facts: { ...FACTS, figures_refreshed_at: refreshed }, factsLoadedAt: loaded }),
      '',
      day,
    )
  const oct13 = await night('2026-10-12T23:10:00+00:00', '2026-10-12T23:02:00+00:00', OCT13)
  const oct14 = await night('2026-10-13T23:10:00+00:00', '2026-10-13T23:02:00+00:00',
                            new Date('2026-10-14T13:00:00Z'))
  assertEquals(await hashOf(oct13.context), await hashOf(oct14.context), 'same book, next night')
})

Deno.test('windows are anchored on the rebuild date, not the wall clock', async () => {
  let dormantCutoff: unknown
  let mixParams: unknown
  const base = territory(GOAL_ROLLUP, STALE)
  // deno-lint-ignore no-explicit-any
  const wrapLt = (q: any): any =>
    new Proxy(q, {
      get(t, prop) {
        const f = t[prop]
        if (typeof f !== 'function' || prop === 'then') return f
        return (...args: unknown[]) => {
          if (prop === 'lt' && args[0] === 'last_invoice_date') dormantCutoff = args[1]
          return wrapLt(f(...args))
        }
      },
    })
  const spy = {
    from: (name: string) => (name === 'v_territory_account_yoy' ? wrapLt(base.from(name)) : base.from(name)),
    rpc: (name: string, params?: unknown) => {
      if (name === 'report_territory_product_mix') mixParams = params
      return base.rpc(name, params as never)
    },
    schema: (name: string) => base.schema(name as never),
  } as unknown as SupabaseClient
  await buildTerritoryContext(spy, '', OCT13)
  assertEquals(dormantCutoff, '2026-07-05', 'quiet = 90 days before Oct 3, not before today')
  assertEquals(mixParams, { p_through_month: '2026-09-01', p_sku_limit: 8 },
    'product mix through the last whole month before the rebuild')
})

Deno.test('the product window never compares one month with one month', () => {
  assertEquals(productWindowEnd('2026-10-03'), '2026-09-01', 'October → through September')
  assertEquals(productWindowEnd('2026-03-01'), '2026-02-01', 'March → Jan–Feb')
  assertEquals(productWindowEnd('2027-02-10'), '2026-12-01', 'February → last full year')
  assertEquals(productWindowEnd('2027-01-15'), '2026-12-01', 'January → last full year')
})

Deno.test('on a behind night, a "quiet" account that invoiced since is not called quiet', async () => {
  const built = await buildTerritoryContext(
    territory(GOAL_ROLLUP, { ...STALE, invoicedSince: ['C9'] }), '', OCT13)
  assertEquals(built.context.dormant, [], 'Canyon Creek invoiced after Oct 3 — dropped')
  const healthy = await buildTerritoryContext(territory(GOAL_ROLLUP, { invoicedSince: ['C9'] }), '', OCT13)
  assertEquals(healthy.context.dormant.length, 1, 'no re-check on a current night')
})

Deno.test('accounts: open orders, past promise, worked-out change, and no stale dates', async () => {
  const built = await buildTerritoryContext(territory(), '', OCT13)
  const a = built.context.top_accounts[0]
  assertEquals([a.open_order_value, a.past_promise_amount], [8_000, 1_000], 'both on every account')
  assert(!('backlog_amount' in a), 'the misleading name is gone')
  assert(!('last_invoice_date' in a), 'last-invoice dates only on quiet accounts')
  assertEquals(a.change_pct, 25, '$40k → $50k')
  assertEquals(built.context.dormant[0].last_invoice_date, '2026-06-05', 'quiet accounts keep theirs')

  const drop = await buildTerritoryContext(
    territory(GOAL_ROLLUP, { down: { revenue_ytd: 30_000, revenue_prior_ytd: 51_000, open_order_value: 8_000 } }),
    '', OCT13)
  assertEquals(drop.context.movers_down[0].open_orders_cover_drop, false, '$21k drop, $8k on order: a drop')
  const ducks = await buildTerritoryContext(
    territory(GOAL_ROLLUP, { down: { revenue_ytd: 10_149, revenue_prior_ytd: 719_250, open_order_value: 1_498_500 } }),
    '', OCT13)
  assertEquals(ducks.context.movers_down[0].open_orders_cover_drop, true,
    'down $709k with $1.5M on order: placed, not shipped yet')
  assertEquals(ducks.context.movers_down[0].change_pct, -99, 'its change, worked out in code')
  assertEquals(changePct(843_000, 2_026, 25_000), null, 'no percentage from a $2,026 base')
  assertEquals(changePct(110, 100), 10, 'plain change')

  assertEquals(built.context.totals.revenue_change_pct, 6, '$850k → $900k')
  assertEquals([built.context.totals.bookings_ytd, built.context.totals.bookings_prior_ytd,
                built.context.totals.bookings_change_pct], [1_000_000, 800_000, 25], 'bookings')
  assert(!('goal' in built.context.totals), 'the goal lives on `goal`, not beside revenue')
  assertEquals(built.context.goal.revenue_toward_goal, 900_000, 'attainment\'s own revenue')
  assertEquals([built.context.accounts_with_revenue_prior_ytd, built.context.new_accounts_this_year,
                built.context.new_accounts_revenue_ytd], [28, 3, 45_000], 'account counts')
})

Deno.test('recent orders: every order counted and totalled, the list is only the largest', async () => {
  const built = await buildTerritoryContext(territory(), '', OCT13)
  assertEquals(built.context.recent_orders.count, 41, 'all 41 orders, not the excerpt')
  assertEquals(built.context.recent_orders.total, 260_000, 'their total')
  assertEquals(built.context.recent_orders.largest[0].account, 'Teton Range', 'the largest, from the facts')
  assert(!JSON.stringify(built.context).includes('2026-09-29'), 'the window start is not hashed')
  const payload = territoryPromptPayload(built, OCT13)
  assertEquals(payload.recent_orders.since, '2026-09-29', 'the model is told where the window starts')
  assertEquals(payload.recent_orders.count, 41, 'and keeps the count')
})

Deno.test('product mix over the same months, named, with the change worked out', async () => {
  const built = await buildTerritoryContext(territory(), '', OCT13)
  const mix = built.context.product_mix
  assertEquals([mix.this_period, mix.prior_period],
    ['January–September 2026', 'January–September 2025'], 'periods by name')
  assertEquals(mix.families.map((f: { family: string; change_pct: number | null }) => [f.family, f.change_pct]),
    [['Mesa', 20], ['Ridgeline', -100]], 'change_pct per family')
  assertEquals(mix.products[0].part_id, 'MPR-308', 'leading products')
  assert(!('top_skus' in built.context), 'no unequal-window lists when the mix is there')
})

Deno.test('scope says company for an admin, territory for everyone else', async () => {
  const rep = await buildTerritoryContext(territory(), '', OCT13)
  const admin = await buildTerritoryContext(territory(GOAL_ROLLUP, { admin: true }), '', OCT13)
  assertEquals([rep.context.scope, admin.context.scope], ['territory', 'company'], 'scope')
})

Deno.test('on a database without 20261013160000 the brief falls back, and stays stable', async () => {
  const old = (day: Date) =>
    buildTerritoryContext(territory(GOAL_ROLLUP, { facts: null, mix: null, factsLoadedAt: null }), '', day)
  const oct13 = await old(OCT13)
  const oct14 = await old(new Date('2026-10-14T13:00:00Z'))
  assertEquals(await hashOf(oct13.context), await hashOf(oct14.context), 'hash stable across days')
  assertEquals(oct13.context.figures_behind_newer_invoices, false, 'never claims staleness it cannot see')
  assertEquals(oct13.context.recent_orders.count, 17, 'count from the slice\'s exact count')
  assertEquals(oct13.context.recent_orders.total, null, 'no total from an excerpt')
  assert(!('bookings_ytd' in oct13.context.totals), 'no bookings without the facts')
  assertEquals(oct13.context.top_skus[0].part_id, 'OLD-1', 'the old product lists come back')
  assert('top_skus_full_last_year' in oct13.context, 'with last year labelled as the full year')
  assert(!('product_mix' in oct13.context), 'and no mix')
})
