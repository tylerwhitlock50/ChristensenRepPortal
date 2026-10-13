/*============================================================================
  accountContext.test.ts — the account brief's cache key holds still.

      deno test --allow-env supabase/functions/

  (--allow-env: the shared modules read their settings at import. No
  network, no database: the queries run against a recording stub.)

  What this pins down: the same account data, built on different days of
  the same month, produces the SAME hashed context — byte for byte — and
  the same queries. Before prompt v4 the hashed context carried a day
  count, so every account looked "changed" every morning and both the
  nightly batch and a rep's Summarize paid for a regeneration that said
  nothing new. Day counts now live in `asOf`, outside the hash.

  Not a test framework: Deno's built-in runner, and three local asserts so
  the file needs nothing from the network.
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import {
  assembleContext,
  canonical,
  type ContextInputs,
  fetchContextInputs,
  monthStart,
  promptPayload,
  sha256Hex,
  summariseMix,
} from './accountContext.ts'

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}
function assertEquals(got: unknown, want: unknown, what: string): void {
  const g = JSON.stringify(got)
  const w = JSON.stringify(want)
  if (g !== w) throw new Error(`FAILED: ${what}\n  got:  ${g}\n  want: ${w}`)
}
function assertNotEquals(got: unknown, other: unknown, what: string): void {
  if (JSON.stringify(got) === JSON.stringify(other)) throw new Error(`FAILED: ${what}`)
}

const hashOf = async (context: unknown) => await sha256Hex(JSON.stringify(canonical(context)))

/** One account's raw reads, as fetchContextInputs would return them. */
function inputs(): ContextInputs {
  return {
    customer: {
      customer_key: 'C1001',
      customer_name: 'Fixture Outfitters',
      sold_to_city: 'Bozeman',
      sold_to_state: 'MT',
      assigned_sales_rep_name: 'Riley Rep',
      customer_type: 'DEALER',
      territory: 'MTN',
      active_flag: 'Y',
      account_open_date: '2019-04-02',
      last_order_date: null,
      yearly_sales_goal: 100_000,
    },
    invoiceLineCount: 412,
    revenue: {
      series: [
        { month: '2025-11', revenue: 12_000 },
        { month: '2026-03', revenue: 8_000 },
        { month: '2026-09', revenue: 15_500 },
      ],
      source: 'view',
    },
    orders: [
      { order_id: 'O3', order_date: '2026-09-20', bookings: 9_000 },
      { order_id: 'O2', order_date: '2026-06-01', bookings: 4_000 },
      { order_id: 'O1', order_date: '2026-03-02', bookings: 6_000 },
    ],
    ordersSince: '2025-10-01',
    rollup: {
      revenue_ytd: 84_250,
      revenue_prior_ytd: 71_400,
      last_invoice_date: '2026-10-01',
      open_order_value: 18_900,
      backlog_amount: 12_400,
      open_order_count: 2,
      last_order_date: '2026-09-20',
    },
    goal: {
      period_year: 2026,
      target_amount: 120_000,
      goal_source: 'crm',
      revenue_to_date: 84_250,
      attainment_pct: 70.2,
      expected_pct: 76.4,
      on_track: false,
      gap_to_pace: -7_430,
      pace_basis: 'seasonal',
    },
    backlog: [
      {
        part_key: 'PK-MPR', part_id: 'MPR-308-16', part_description: 'MPR .308',
        product_family: 'MPR', backlog_qty: 3, backlog_amount: 5_697,
        earliest_promise_date: '2026-10-09', earliest_desired_ship_date: '2026-11-01',
      },
    ],
    reorders: [
      {
        part_key: 'PK-MESA', part_id: 'MESA-65CM-22', part_description: 'Mesa 6.5 CM',
        product_family: 'Mesa', chambering: '6.5 Creedmoor', ats_qty: 40,
        last_bought_month: '2026-06-01', last_qty: 6, total_qty: 20,
        months_with_buys: 5, median_months_between_buys: 3,
        expected_next_month: '2026-09-01', is_due: true,
      },
    ],
    mix: [
      {
        product_family: 'Mesa', revenue: 30_000, qty: 22, prior_revenue: 25_000, prior_qty: 19,
        period_start: '2026-01-01', period_end: '2026-09-01',
        prior_start: '2025-01-01', prior_end: '2025-09-01',
      },
      {
        product_family: 'Ridgeline', revenue: 0, qty: 0, prior_revenue: 4_800, prior_qty: 2,
        period_start: '2026-01-01', period_end: '2026-09-01',
        prior_start: '2025-01-01', prior_end: '2025-09-01',
      },
      {
        product_family: 'Traverse', revenue: 2_000, qty: 1, prior_revenue: 6_000, prior_qty: 3,
        period_start: '2026-01-01', period_end: '2026-09-01',
        prior_start: '2025-01-01', prior_end: '2025-09-01',
      },
    ],
    openRecs: [],
    resolvedRecs: [
      { title: 'No order in 120 days', status: 'closed', outcome: 'order_received',
        outcome_note: 'Ordered after the March call', closed_at: '2026-04-11T16:02:00Z' },
    ],
    notes: [{ body: 'Wants the new Mesa colours.', created_at: '2026-09-02T15:00:00Z' }],
    visit: null,
    actions: [
      { action_type: 'call', action_date: '2026-09-28' },
      { action_type: 'visit', action_date: '2026-05-02' },
    ],
    lastShipDate: '2026-09-30',
  }
}

const OCT_13 = new Date('2026-10-13T15:00:00Z')
const OCT_14 = new Date('2026-10-14T09:30:00Z')
const OCT_31 = new Date('2026-10-31T23:00:00Z')
const NOV_02 = new Date('2026-11-02T12:00:00Z')

Deno.test('the hashed context is identical on different days of the same month', async () => {
  const a = assembleContext(inputs(), OCT_13)
  const b = assembleContext(inputs(), OCT_14)
  const c = assembleContext(inputs(), OCT_31)
  assertEquals(await hashOf(a.context), await hashOf(b.context), 'Oct 13 vs Oct 14')
  assertEquals(await hashOf(a.context), await hashOf(c.context), 'Oct 13 vs Oct 31')
})

Deno.test('day counts are computed, but only outside the hash', async () => {
  const a = assembleContext(inputs(), OCT_13)
  const b = assembleContext(inputs(), OCT_14)
  assertEquals(a.asOf.days_since_last_order, 23, 'Sep 20 → Oct 13')
  assertEquals(b.asOf.days_since_last_order, 24, 'Sep 20 → Oct 14')
  assertNotEquals(a.asOf, b.asOf, 'asOf moves with the day')
  const hashed = JSON.stringify(a.context)
  assert(!/days_since/.test(hashed), 'no day count anywhere in the hashed context')
  assert(!/"date":"2026-10-13"/.test(hashed), 'today is not in the hashed context')
  // The model still gets them.
  const payload = promptPayload(a.context, a.asOf)
  assertEquals(payload.as_of_today.days_since_last_order, 23, 'payload carries asOf')
  assertEquals(payload.as_of_today.backlog_lines_past_promise, 1, 'Oct 9 promise is past on Oct 13')
  assertEquals(await hashOf(payload), await hashOf(payload), 'payload is deterministic')
})

Deno.test('goal pace and same-window revenue (they move daily) stay out of the hash', () => {
  const a = assembleContext(inputs(), OCT_13)
  const moved = inputs()
  moved.goal = { ...moved.goal!, expected_pct: 77.1, gap_to_pace: -8_100, on_track: false }
  moved.rollup = { ...moved.rollup!, revenue_prior_ytd: 71_900 }
  const b = assembleContext(moved, OCT_14)
  assertEquals(a.context, b.context, 'expected_pct / revenue_prior_ytd changes do not touch the hash')
  assertEquals(b.asOf.goal_pace?.expected_pct_by_today, 77.1, 'but the model sees today\'s pace')
})

Deno.test('a real change in the data does change the hash', async () => {
  const a = assembleContext(inputs(), OCT_13)
  const changed = inputs()
  changed.orders = [{ order_id: 'O4', order_date: '2026-10-12', bookings: 2_500 }, ...changed.orders]
  const b = assembleContext(changed, OCT_14)
  assertNotEquals(await hashOf(a.context), await hashOf(b.context), 'a new order is news')
})

Deno.test('a new month moves the month-anchored windows (once a month, not daily)', async () => {
  const oct = assembleContext(inputs(), OCT_31)
  const nov = assembleContext(inputs(), NOV_02)
  assertNotEquals(await hashOf(oct.context), await hashOf(nov.context), 'trailing-12 windows roll')
})

Deno.test('totals come from the rollup, and the late part is labelled separately', () => {
  const { context } = assembleContext(inputs(), OCT_13)
  assertEquals(context.orders.open_order_value, 18_900, 'all still owed')
  assertEquals(context.orders.past_promise_amount, 12_400, 'late subset')
  const noRollup = inputs()
  noRollup.rollup = null
  const bare = assembleContext(noRollup, OCT_13).context
  assertEquals(bare.orders.open_order_value, null, 'null, not $0, without a rollup row')
})

Deno.test('the portal goal wins; the ERP goal is the fallback', () => {
  const { context } = assembleContext(inputs(), OCT_13)
  assertEquals(context.goal, {
    year: 2026, target: 120_000, source: 'portal', revenue_to_date: 84_250, attainment_pct: 70.2,
  }, 'portal goal from v_account_goal_progress')
  const noView = inputs()
  noView.goal = null
  assertEquals(assembleContext(noView, OCT_13).context.goal, {
    year: 2026, target: 100_000, source: 'erp', revenue_to_date: 84_250, attainment_pct: 84.3,
  }, 'ERP yearly goal when the view has no row')
})

Deno.test('a family is "stopped" only when the same-window comparison says so', () => {
  const mix = summariseMix(inputs().mix)!
  assertEquals(mix.stopped_families, ['Ridgeline'], 'had $4,800 last year, nothing this year')
  assert(!mix.stopped_families.includes('Traverse'), 'lower is not stopped')
  assertEquals(mix.this_period, { from: '2026-01', through: '2026-09' }, 'months are reported')
  assertEquals(summariseMix([]), null, 'no mix rows → no mix block')
  const small = summariseMix([{ ...inputs().mix[1], prior_revenue: 600 }])!
  assertEquals(small.stopped_families, [], 'a one-off $600 last year is not a stopped family')
})

Deno.test('stock quantity never reaches the hash; "covers the last order" does', () => {
  const a = assembleContext(inputs(), OCT_13)
  const restocked = inputs()
  restocked.reorders = [{ ...restocked.reorders[0], ats_qty: 38 }]
  const b = assembleContext(restocked, OCT_13)
  assertEquals(a.context, b.context, '40 → 38 in stock is not news')
  assertEquals(a.context.in_stock_reorders[0].due_now, true, 'due flag carried')
  const short = inputs()
  short.reorders = [{ ...short.reorders[0], ats_qty: 2 }]
  assertEquals(
    assembleContext(short, OCT_13).context.in_stock_reorders[0].stock_covers_last_order,
    false,
    'stock below their last order size is',
  )
})

/*----------------------------------------------------------------------------
  The queries themselves: a stub client that records every builder call and
  answers every request with an empty result.
----------------------------------------------------------------------------*/

function recordingClient(): { client: SupabaseClient; log: unknown[] } {
  const log: unknown[] = []
  const result = { data: [], error: null, count: 0 }
  const builder = (label: string): unknown =>
    new Proxy(
      {},
      {
        get(_t, prop) {
          if (prop === 'then') {
            return (resolve: (v: unknown) => void) => resolve(result)
          }
          return (...args: unknown[]) => {
            log.push([label, String(prop), args])
            return builder(label)
          }
        },
      },
    )
  const client = {
    from: (name: string) => builder(`from:${name}`),
    rpc: (name: string, args: unknown) => {
      log.push(['rpc', name, args])
      return builder(`rpc:${name}`)
    },
    schema: (schema: string) => ({
      from: (name: string) => builder(`from:${schema}.${name}`),
    }),
  }
  return { client: client as unknown as SupabaseClient, log }
}

Deno.test('the same queries run on any day of the month (month-anchored windows)', async () => {
  const a = recordingClient()
  const b = recordingClient()
  await fetchContextInputs(a.client, 'C1001', OCT_13)
  await fetchContextInputs(b.client, 'C1001', OCT_31)
  assertEquals(a.log, b.log, 'identical query logs on Oct 13 and Oct 31')
  const flat = JSON.stringify(a.log)
  assert(flat.includes('"2025-10-01"'), 'orders window starts on a month boundary')
  assert(flat.includes('"p_through_month":"2026-09-01"'), 'mix runs through the last complete month')
})

Deno.test('monthStart crosses the year boundary', () => {
  assertEquals(monthStart(new Date('2026-01-15T00:00:00Z'), 1), '2025-12-01', 'January → December')
  assertEquals(monthStart(new Date('2026-10-13T00:00:00Z'), 23), '2024-11-01', '24-month series start')
})
