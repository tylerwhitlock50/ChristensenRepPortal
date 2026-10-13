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
    rpc: (name: string) => builder(`rpc:${name}`, []),
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
  backlog_amount: 1_000,
  yoy_change_amount: 10_000,
  ...extra,
})

function territory(): SupabaseClient {
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
        return {
          data: { accounts_with_goal: 10, accounts_behind: 4, target_total: 1_200_000,
                  attainment_pct: 75, expected_pct: 78.2 },
          error: null,
        }
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
        }
      case 'v_territory_sku_sales':
        return { data: [], error: null }
      case 'v_data_freshness':
        // Moves every business day, whatever this book did.
        return { data: { data_through: '2026-10-09' }, error: null }
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
  assertEquals(built.context.recent_orders[0].customer_key, 'C7', 'recent orders keyed')
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
