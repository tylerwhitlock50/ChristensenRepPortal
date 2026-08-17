/*============================================================================
  mcp/tools.ts — the tools an MCP client can call.

  Every tool is READ-ONLY and every read goes through `ctx.db`, which is the
  rep's own client (see _shared/mcpAuth.ts). There is no service_role in this
  file and there must never be one: the moment a tool filters by "the rep's
  accounts" in TypeScript instead of letting RLS do it, the access rules have
  a second implementation and the 010 header's argument applies.

  What that buys: not one tool below carries a customer-scoping predicate.
  `search_accounts` selects from v_account_list unfiltered and gets exactly
  the caller's book, because every one of these views is security_invoker.

  Shape of a result
  -----------------
  JSON, as one text block. No outputSchema/structuredContent: a client that
  supports them gains little over well-named JSON keys here, and clients that
  half-support them reject the response. Nulls are stripped and money is
  rounded to cents, because both are pure context cost for a model.

  Sizing
  ------
  Views that are safe to scan unfiltered (the territory rollups) are read in
  pages behind a hard row cap and aggregated HERE, so a 41k-account admin gets
  a summary rather than a context overflow. Every list tool caps `limit` and
  says so in its description; a truncated read always reports `truncated: true`
  rather than quietly returning a prefix.
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import type { McpCaller } from '../_shared/mcpAuth.ts'

export interface ToolContext {
  db: SupabaseClient
  caller: McpCaller
}

export interface ToolDef {
  name: string
  title: string
  description: string
  inputSchema: Record<string, unknown>
  handler: (args: Record<string, unknown>, ctx: ToolContext) => Promise<unknown>
}

/** A failure the model should read and retry differently, not a protocol bug. */
export class ToolError extends Error {}

/*----------------------------------------------------------------------------
  Small helpers
----------------------------------------------------------------------------*/

const READ_ONLY = {
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
} as const

function num(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function money(value: unknown): number | null {
  const n = num(value)
  return n === null ? null : Math.round(n * 100) / 100
}

function pct(part: number, whole: number): number | null {
  if (!whole) return null
  return Math.round((part / whole) * 1000) / 10
}

/** Drops null/undefined/'' so a 40-column row does not cost 40 keys. */
function compact<T extends Record<string, unknown>>(row: T): Partial<T> {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(row)) {
    if (v === null || v === undefined || v === '') continue
    out[k] = v
  }
  return out as Partial<T>
}

function clampInt(value: unknown, fallback: number, min: number, max: number): number {
  const n = num(value)
  if (n === null) return fallback
  return Math.min(max, Math.max(min, Math.trunc(n)))
}

function str(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed === '' ? null : trimmed
}

function requireKey(args: Record<string, unknown>, field = 'customer_key'): string {
  const value = str(args[field])
  if (!value) {
    throw new ToolError(
      `\`${field}\` is required. Use search_accounts to find one — it is the ` +
        `ERP customer key, not the account name.`,
    )
  }
  return value
}

/**
 * PostgREST's `or=` filter is a comma-separated list, so an unescaped comma
 * or paren in a search term does not fail — it silently becomes a different
 * query. Strip the separators and use `*` as the wildcard.
 */
function safeLike(term: string): string {
  return term.replace(/[,()*"\\%]/g, ' ').trim()
}

function fail(error: { message?: string } | null, what: string): never {
  throw new ToolError(`Could not read ${what}: ${error?.message ?? 'unknown error'}`)
}

type Row = Record<string, unknown>

/**
 * supabase-js resolves `.select('a, b')` against the client's schema types.
 * This client is deliberately untyped — the MCP server reads views that
 * database.types.ts does not know about — so the parser gives up and types
 * every row as `GenericStringError`. Same untyped-handle problem the frontend
 * composables solve with a cast; solved once here instead of at 30 call sites,
 * with the error check folded in so no caller can forget it.
 */
type PgResult = { data: unknown; error: unknown; count?: number | null }

function rowsOf(result: PgResult, what: string): Row[] {
  if (result.error) fail(result.error as { message?: string }, what)
  // PostgREST returns a bare object rather than an array whenever the request
  // asked for a single row. Coercing beats `.map is not a function`, which is
  // what a caller sees if it reaches for the wrong helper.
  const data = result.data
  if (Array.isArray(data)) return data as Row[]
  return data ? [data as Row] : []
}

function rowOf(result: PgResult, what: string): Row | null {
  if (result.error) fail(result.error as { message?: string }, what)
  return (result.data ?? null) as Row | null
}

/**
 * Reads a whole relation in pages, under a hard cap. Used only for the
 * territory rollups, which are nightly aggregate tables and are meant to be
 * scanned unfiltered (see the v_territory_account_yoy comment in 030).
 */
async function fetchCapped(
  page: (from: number, to: number) => PromiseLike<PgResult>,
  cap: number,
  what: string,
): Promise<{ rows: Row[]; truncated: boolean }> {
  const SIZE = 1000
  const rows: Row[] = []
  for (let from = 0; from < cap; from += SIZE) {
    const to = Math.min(from + SIZE, cap) - 1
    const batch = rowsOf(await page(from, to), what)
    rows.push(...batch)
    // A short page is the end of the relation; a full one that lands on the
    // cap is a genuine truncation and the loop condition reports it.
    if (batch.length < to - from + 1) return { rows, truncated: false }
  }
  return { rows, truncated: true }
}

const currentYear = () => new Date().getUTCFullYear()

/*----------------------------------------------------------------------------
  Shared schema fragments
----------------------------------------------------------------------------*/

const CUSTOMER_KEY = {
  type: 'string',
  description:
    'ERP customer key identifying one account (from search_accounts). Not the account name.',
} as const

const limitProp = (fallback: number, max: number) =>
  ({
    type: 'integer',
    minimum: 1,
    maximum: max,
    default: fallback,
    description: `Rows to return (max ${max}).`,
  }) as const

/*============================================================================
  Tools
============================================================================*/

const whoami: ToolDef = {
  name: 'whoami',
  title: 'Who am I',
  description:
    'The connected rep, the size of their account book, and how fresh the ' +
    'data is. Call this first in a session: every other tool is scoped to ' +
    'this person automatically, and `data_through` is the newest invoice ' +
    'date in the warehouse — "this month" means through that date, not today.',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  async handler(_args, { db, caller }) {
    const [all, active, fresh] = await Promise.all([
      db.from('v_account_list').select('customer_key', { count: 'exact', head: true }),
      db
        .from('v_account_list')
        .select('customer_key', { count: 'exact', head: true })
        .eq('active_flag', 'Y')
        .is('deactivated_at', null),
      db.from('v_data_freshness').select('data_loaded_at, data_through').maybeSingle(),
    ])

    if (all.error) fail(all.error, 'your account book')

    return {
      user: compact({
        name: caller.fullName,
        role: caller.role,
        sales_rep_key: caller.salesRepKey,
        rep_group_vendor_id: caller.repGroupVendorId,
      }),
      book: {
        accounts_total: all.count ?? 0,
        accounts_active: active.count ?? 0,
      },
      data_freshness: compact({
        etl_loaded_at: fresh.data?.data_loaded_at ?? null,
        data_through: fresh.data?.data_through ?? null,
      }),
      today: new Date().toISOString().slice(0, 10),
      access_note:
        caller.role === 'admin'
          ? 'Admin: every account in the ERP is visible.'
          : 'Rep: only accounts assigned to you in the ERP, plus any explicit grants.',
    }
  },
}

const searchAccounts: ToolDef = {
  name: 'search_accounts',
  title: 'Search accounts',
  description:
    'Find accounts in the book by name, key, city or state. This is how you ' +
    'turn "Smoky Mountain" into the customer_key every other account tool ' +
    'needs. Excludes inactive and rep-deactivated accounts unless asked.',
  inputSchema: {
    type: 'object',
    properties: {
      query: {
        type: 'string',
        description: 'Matches account name, customer key, or city (case-insensitive).',
      },
      state: { type: 'string', description: 'Two-letter state code, e.g. "TN".' },
      include_inactive: {
        type: 'boolean',
        default: false,
        description:
          'Include ERP-inactive accounts and ones the rep has deactivated in the portal.',
      },
      sort: {
        type: 'string',
        enum: ['name', 'last_order_date'],
        default: 'name',
        description: '"last_order_date" surfaces the most recently ordering accounts first.',
      },
      limit: limitProp(25, 200),
      offset: { type: 'integer', minimum: 0, default: 0, description: 'For paging.' },
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const limit = clampInt(args.limit, 25, 1, 200)
    const offset = clampInt(args.offset, 0, 0, 100_000)
    const query = str(args.query)
    const state = str(args.state)

    let q = db
      .from('v_account_list')
      .select(
        'customer_key, customer_name, sold_to_city, sold_to_state, territory, ' +
          'assigned_sales_rep_id, assigned_sales_rep_name, active_flag, ' +
          'last_order_date, deactivated_at, deactivation_reason',
        { count: 'exact' },
      )

    if (args.include_inactive !== true) {
      q = q.eq('active_flag', 'Y').is('deactivated_at', null)
    }
    if (state) q = q.ilike('sold_to_state', state)
    if (query) {
      const term = safeLike(query)
      if (term) {
        q = q.or(
          `customer_name.ilike.*${term}*,customer_key.ilike.*${term}*,sold_to_city.ilike.*${term}*`,
        )
      }
    }

    q =
      args.sort === 'last_order_date'
        ? q.order('last_order_date', { ascending: false, nullsFirst: false })
        : q.order('customer_name')

    const result = await q.range(offset, offset + limit - 1)
    const rows = rowsOf(result, 'the account list')

    return {
      matched: result.count ?? rows.length,
      offset,
      accounts: rows.map(compact),
    }
  },
}

const getAccount: ToolDef = {
  name: 'get_account',
  title: 'Account detail',
  description:
    'Everything on one account in a single call: identity, YTD vs prior-YTD ' +
    'vs trailing-12-month revenue, open orders and backlog, this year\'s ' +
    'goal and pace, the engagement score with its reasons, and any open ' +
    'recommendations. "Revenue" is invoiced (shipped) dollars; open order ' +
    'value is booked but not yet shipped.',
  inputSchema: {
    type: 'object',
    properties: { customer_key: CUSTOMER_KEY },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const year = currentYear()

    const [identity, summary, signals, goal, recs] = await Promise.all([
      db
        .from('v_account_list')
        .select(
          'customer_key, customer_name, sold_to_city, sold_to_state, territory, ' +
            'assigned_sales_rep_id, assigned_sales_rep_name, active_flag, ' +
            'last_order_date, deactivated_at, deactivation_reason',
        )
        .eq('customer_key', key)
        .maybeSingle(),
      db
        .from('v_account_summary')
        .select(
          'revenue_ytd, revenue_prior_ytd, revenue_trailing_12m, last_order_date, ' +
            'last_invoice_date, open_order_count, open_order_value, backlog_qty',
        )
        .eq('customer_key', key)
        .maybeSingle(),
      db
        .from('account_signals')
        .select(
          'score, priority, days_since_order, cadence_days, cadence_confident, ' +
            'days_since_touch, last_touch_date, yoy_change, families_dropped, ' +
            'open_backlog_amount, revenue_percentile, computed_at',
        )
        .eq('customer_key', key)
        .maybeSingle(),
      db
        .from('v_account_goal_progress')
        .select(
          'period_year, target_amount, revenue_to_date, attainment_pct, expected_pct, ' +
            'gap_to_pace, gap_to_goal, projected_amount, on_track, pace_basis, ' +
            'erp_yearly_sales_goal, days_remaining',
        )
        .eq('customer_key', key)
        .eq('period_year', year)
        .maybeSingle(),
      db
        .from('recommendations')
        .select('id, title, reason, priority, status, due_date, rule_key, created_at')
        .eq('customer_key', key)
        .in('status', ['open', 'acted'])
        .order('created_at', { ascending: false })
        .limit(10),
    ])

    const account = rowOf(identity, 'the account')
    if (!account) {
      throw new ToolError(
        `No account with customer_key "${key}" is visible to you. It may belong ` +
          `to another rep, or the key may be wrong — try search_accounts.`,
      )
    }

    const s = (rowOf(summary, 'the account summary') ?? {}) as Row
    const ytd = num(s.revenue_ytd) ?? 0
    const prior = num(s.revenue_prior_ytd) ?? 0

    return {
      account: compact(account),
      revenue: compact({
        revenue_ytd: money(ytd),
        revenue_prior_ytd: money(prior),
        yoy_change_amount: money(ytd - prior),
        yoy_change_pct: prior > 0 ? pct(ytd - prior, prior) : null,
        revenue_trailing_12m: money(s.revenue_trailing_12m),
        last_invoice_date: s.last_invoice_date ?? null,
        last_order_date: s.last_order_date ?? null,
      }),
      open_orders: compact({
        open_order_count: num(s.open_order_count),
        open_order_value: money(s.open_order_value),
        backlog_qty: num(s.backlog_qty),
      }),
      goal: rowOf(goal, 'the goal') ?? null,
      signals: rowOf(signals, 'the account score') ?? null,
      open_recommendations: rowsOf(recs, 'recommendations').map(compact),
      hints: {
        sku_detail: 'get_account_sku_sales for what they actually buy',
        history: 'list_orders / list_shipments for order and shipment history',
      },
    }
  },
}

const getAccountSkuSales: ToolDef = {
  name: 'get_account_sku_sales',
  title: 'Account SKU sales',
  description:
    'What one account buys, by SKU, pivoted across the current and three ' +
    'prior calendar years. Use it to spot dropped SKUs (revenue last year, ' +
    'none this year) and product-mix shifts. Invoiced revenue and units.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: CUSTOMER_KEY,
      sort: {
        type: 'string',
        enum: ['revenue', 'qty', 'recent'],
        default: 'revenue',
        description: 'Ranks by the total across all returned years, or by last invoice date.',
      },
      limit: limitProp(40, 200),
    },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const limit = clampInt(args.limit, 40, 1, 200)

    const { rows, truncated } = await fetchCapped(
      (from, to) =>
        db
          .from('v_sku_sales_by_account')
          .select(
            'part_key, part_id, part_description, product_family, chambering, ' +
              'sales_year, revenue, qty, last_invoice_date',
          )
          .eq('customer_key', key)
          .range(from, to),
      3000,
      'SKU sales for this account',
    )

    return pivotSkuRows(rows, truncated, String(args.sort ?? 'revenue'), limit)
  },
}

/** Shared by the account-level and territory-level SKU tools. */
function pivotSkuRows(rows: Row[], truncated: boolean, sort: string, limit: number) {
  interface Sku {
    part_id: string | null
    part_description: string | null
    product_family: string | null
    chambering: string | null
    by_year: Record<string, { revenue: number; qty: number }>
    total_revenue: number
    total_qty: number
    last_invoice_date: string | null
  }

  const skus = new Map<string, Sku>()
  const years = new Set<number>()

  for (const row of rows) {
    const partKey = String(row.part_key ?? '')
    const year = num(row.sales_year)
    if (year !== null) years.add(year)

    let sku = skus.get(partKey)
    if (!sku) {
      sku = {
        part_id: (row.part_id as string) ?? null,
        part_description: (row.part_description as string) ?? null,
        product_family: (row.product_family as string) ?? null,
        chambering: (row.chambering as string) ?? null,
        by_year: {},
        total_revenue: 0,
        total_qty: 0,
        last_invoice_date: null,
      }
      skus.set(partKey, sku)
    }

    const revenue = num(row.revenue) ?? 0
    const qty = num(row.qty) ?? 0
    if (year !== null) {
      const bucket = (sku.by_year[String(year)] ??= { revenue: 0, qty: 0 })
      bucket.revenue += revenue
      bucket.qty += qty
    }
    sku.total_revenue += revenue
    sku.total_qty += qty

    const last = row.last_invoice_date as string | null
    if (last && (!sku.last_invoice_date || last > sku.last_invoice_date)) {
      sku.last_invoice_date = last
    }
  }

  const list = [...skus.values()]
  list.sort((a, b) => {
    if (sort === 'qty') return b.total_qty - a.total_qty
    if (sort === 'recent') {
      return (b.last_invoice_date ?? '').localeCompare(a.last_invoice_date ?? '')
    }
    return b.total_revenue - a.total_revenue
  })

  const shown = list.slice(0, limit)
  return {
    years: [...years].sort((a, b) => b - a),
    sku_count: list.length,
    returned: shown.length,
    truncated,
    skus: shown.map((sku) => ({
      ...compact({
        part_id: sku.part_id,
        part_description: sku.part_description,
        product_family: sku.product_family,
        chambering: sku.chambering,
        last_invoice_date: sku.last_invoice_date,
      }),
      total_revenue: money(sku.total_revenue),
      total_qty: sku.total_qty,
      by_year: Object.fromEntries(
        Object.entries(sku.by_year)
          .sort(([a], [b]) => Number(b) - Number(a))
          .map(([year, v]) => [year, { revenue: money(v.revenue), qty: v.qty }]),
      ),
    })),
  }
}

/*----------------------------------------------------------------------------
  Territory. Both tools read the same nightly rollup (030), so they always
  agree with each other and with the portal's Overview page.
----------------------------------------------------------------------------*/

const TERRITORY_COLUMNS =
  'customer_key, customer_name, sold_to_city, sold_to_state, yearly_sales_goal, ' +
  'revenue_ytd, revenue_prior_ytd, revenue_trailing_12m, last_invoice_date, ' +
  'open_order_value, backlog_qty, backlog_amount'

const TERRITORY_CAP = 5000

async function fetchTerritory(db: SupabaseClient) {
  const { rows, truncated } = await fetchCapped(
    (from, to) => db.from('v_territory_account_yoy').select(TERRITORY_COLUMNS).range(from, to),
    TERRITORY_CAP,
    'the territory rollup',
  )
  return {
    truncated,
    accounts: rows.map((r) => {
      const ytd = num(r.revenue_ytd) ?? 0
      const prior = num(r.revenue_prior_ytd) ?? 0
      return {
        customer_key: String(r.customer_key),
        customer_name: (r.customer_name as string) ?? null,
        sold_to_city: (r.sold_to_city as string) ?? null,
        sold_to_state: (r.sold_to_state as string) ?? null,
        revenue_ytd: ytd,
        revenue_prior_ytd: prior,
        revenue_trailing_12m: num(r.revenue_trailing_12m) ?? 0,
        yoy_change_amount: ytd - prior,
        yoy_change_pct: prior > 0 ? pct(ytd - prior, prior) : null,
        open_order_value: num(r.open_order_value) ?? 0,
        backlog_amount: num(r.backlog_amount) ?? 0,
        backlog_qty: num(r.backlog_qty) ?? 0,
        yearly_sales_goal: num(r.yearly_sales_goal),
        last_invoice_date: (r.last_invoice_date as string) ?? null,
      }
    }),
  }
}

type TerritoryAccount = Awaited<ReturnType<typeof fetchTerritory>>['accounts'][number]

function territoryRow(a: TerritoryAccount) {
  return compact({
    customer_key: a.customer_key,
    customer_name: a.customer_name,
    city: a.sold_to_city,
    state: a.sold_to_state,
    revenue_ytd: money(a.revenue_ytd),
    revenue_prior_ytd: money(a.revenue_prior_ytd),
    yoy_change_amount: money(a.yoy_change_amount),
    yoy_change_pct: a.yoy_change_pct,
    open_order_value: money(a.open_order_value),
    backlog_amount: money(a.backlog_amount),
    last_invoice_date: a.last_invoice_date,
  })
}

const getTerritorySummary: ToolDef = {
  name: 'get_territory_summary',
  title: 'Territory summary',
  description:
    'One-call health check on the whole book: total YTD vs prior-YTD revenue, ' +
    'trailing 12 months, open order value and backlog, goal attainment, plus ' +
    'the biggest growers, decliners and gone-quiet accounts. Start here for ' +
    '"how am I doing" questions, then drill in with get_account. Covers ' +
    'active external accounts only — the same definition the portal uses.',
  inputSchema: {
    type: 'object',
    properties: {
      highlight_count: {
        type: 'integer',
        minimum: 1,
        maximum: 25,
        default: 5,
        description: 'How many accounts to name in each highlight list.',
      },
      quiet_days: {
        type: 'integer',
        minimum: 30,
        maximum: 730,
        default: 120,
        description: 'An account is "gone quiet" after this many days with no invoice.',
      },
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const top = clampInt(args.highlight_count, 5, 1, 25)
    const quietDays = clampInt(args.quiet_days, 120, 30, 730)

    const [{ accounts, truncated }, goals] = await Promise.all([
      fetchTerritory(db),
      db
        .from('v_my_goal_rollup')
        .select(
          'period_year, accounts_with_goal, accounts_behind, target_total, ' +
            'revenue_total, attainment_pct, expected_pct',
        )
        .eq('period_year', currentYear())
        .maybeSingle(),
    ])

    const sum = (pick: (a: TerritoryAccount) => number) =>
      accounts.reduce((total, a) => total + pick(a), 0)

    const ytd = sum((a) => a.revenue_ytd)
    const prior = sum((a) => a.revenue_prior_ytd)

    const cutoff = new Date(Date.now() - quietDays * 86_400_000).toISOString().slice(0, 10)
    const quiet = accounts
      .filter((a) => a.revenue_trailing_12m > 0 || a.revenue_prior_ytd > 0)
      .filter((a) => !a.last_invoice_date || a.last_invoice_date < cutoff)
      .sort((a, b) => b.revenue_prior_ytd - a.revenue_prior_ytd)

    const movers = [...accounts].sort((a, b) => b.yoy_change_amount - a.yoy_change_amount)

    return {
      totals: {
        accounts: accounts.length,
        accounts_with_ytd_revenue: accounts.filter((a) => a.revenue_ytd > 0).length,
        revenue_ytd: money(ytd),
        revenue_prior_ytd: money(prior),
        yoy_change_amount: money(ytd - prior),
        yoy_change_pct: prior > 0 ? pct(ytd - prior, prior) : null,
        revenue_trailing_12m: money(sum((a) => a.revenue_trailing_12m)),
        open_order_value: money(sum((a) => a.open_order_value)),
        backlog_amount: money(sum((a) => a.backlog_amount)),
        backlog_qty: sum((a) => a.backlog_qty),
      },
      goal: rowOf(goals, 'the goal rollup') ?? null,
      top_accounts: [...accounts]
        .sort((a, b) => b.revenue_ytd - a.revenue_ytd)
        .slice(0, top)
        .map(territoryRow),
      biggest_growth: movers.filter((a) => a.yoy_change_amount > 0).slice(0, top).map(territoryRow),
      biggest_decline: movers
        .filter((a) => a.yoy_change_amount < 0)
        .reverse()
        .slice(0, top)
        .map(territoryRow),
      gone_quiet: {
        no_invoice_since_days: quietDays,
        count: quiet.length,
        accounts: quiet.slice(0, top).map(territoryRow),
      },
      truncated,
      note:
        'Revenue is invoiced (shipped) dollars. Open order value and backlog are ' +
        'booked but not yet shipped, so they are NOT included in revenue.',
    }
  },
}

const listTerritoryAccounts: ToolDef = {
  name: 'list_territory_accounts',
  title: 'Rank accounts',
  description:
    'The book as a ranked list — top accounts by YTD revenue, worst YoY ' +
    'decliners, biggest backlog, and so on. Answers "which accounts should I ' +
    'call this week" better than search_accounts, which sorts by name.',
  inputSchema: {
    type: 'object',
    properties: {
      sort: {
        type: 'string',
        enum: [
          'revenue_ytd',
          'revenue_prior_ytd',
          'revenue_trailing_12m',
          'yoy_change_amount',
          'yoy_change_pct',
          'open_order_value',
          'backlog_amount',
        ],
        default: 'revenue_ytd',
        description: 'Sort key. Pair with direction "asc" to get the bottom of the list.',
      },
      direction: { type: 'string', enum: ['desc', 'asc'], default: 'desc' },
      state: { type: 'string', description: 'Restrict to one state, e.g. "TN".' },
      min_prior_ytd: {
        type: 'number',
        description:
          'Only accounts that did at least this much revenue in the same period last ' +
          'year. Use it to keep tiny accounts out of percentage rankings.',
      },
      limit: limitProp(20, 200),
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const limit = clampInt(args.limit, 20, 1, 200)
    const sort = String(args.sort ?? 'revenue_ytd') as keyof TerritoryAccount
    const ascending = args.direction === 'asc'
    const state = str(args.state)
    const minPrior = num(args.min_prior_ytd)

    const { accounts, truncated } = await fetchTerritory(db)

    let list = accounts
    if (state) list = list.filter((a) => (a.sold_to_state ?? '').toUpperCase() === state.toUpperCase())
    if (minPrior !== null) list = list.filter((a) => a.revenue_prior_ytd >= minPrior)

    // Nulls (a percentage with no prior year) always sort last, in either
    // direction — otherwise "worst decliners, ascending" leads with accounts
    // that simply have no comparison.
    const sorted = [...list].sort((a, b) => {
      const av = num(a[sort])
      const bv = num(b[sort])
      if (av === null && bv === null) return 0
      if (av === null) return 1
      if (bv === null) return -1
      return ascending ? av - bv : bv - av
    })

    return {
      matched: list.length,
      sorted_by: `${String(sort)} ${ascending ? 'asc' : 'desc'}`,
      truncated,
      accounts: sorted.slice(0, limit).map(territoryRow),
    }
  },
}

const getSkuSales: ToolDef = {
  name: 'get_sku_sales',
  title: 'Territory SKU sales',
  description:
    'SKU sales across the whole book, pivoted by calendar year (current plus ' +
    'three prior). Answers "what sells in my territory" and "which products ' +
    'are we losing". Invoiced revenue and units; active external accounts only.',
  inputSchema: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'Matches part ID or description.' },
      product_family: { type: 'string', description: 'Exact product family.' },
      chambering: { type: 'string', description: 'Exact chambering, e.g. "9MM".' },
      sort: { type: 'string', enum: ['revenue', 'qty', 'recent'], default: 'revenue' },
      limit: limitProp(30, 200),
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const limit = clampInt(args.limit, 30, 1, 200)
    const query = str(args.query)
    const family = str(args.product_family)
    const chambering = str(args.chambering)

    const { rows, truncated } = await fetchCapped(
      (from, to) => {
        let q = db
          .from('v_territory_sku_sales')
          .select(
            'part_key, part_id, part_description, product_family, chambering, ' +
              'sales_year, revenue, qty, last_invoice_date',
          )
        if (family) q = q.eq('product_family', family)
        if (chambering) q = q.eq('chambering', chambering)
        if (query) {
          const term = safeLike(query)
          if (term) q = q.or(`part_id.ilike.*${term}*,part_description.ilike.*${term}*`)
        }
        return q.range(from, to)
      },
      5000,
      'territory SKU sales',
    )

    return pivotSkuRows(rows, truncated, String(args.sort ?? 'revenue'), limit)
  },
}

const listBacklog: ToolDef = {
  name: 'list_backlog',
  title: 'Open backlog',
  description:
    'Open order lines still owed to customers, rolled up to account × SKU, ' +
    'with the earliest promise date and the estimated production date ' +
    '(earliest desired ship date). Omit customer_key for the whole territory. ' +
    'Backlog is booked-but-unshipped, so it is not revenue yet.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: { ...CUSTOMER_KEY, description: 'Optional — one account instead of the book.' },
      product_family: { type: 'string', description: 'Exact product family, e.g. "RIFLES".' },
      query: { type: 'string', description: 'Matches part ID or description.' },
      sort: {
        type: 'string',
        enum: ['amount', 'qty', 'promise_date', 'ship_date'],
        default: 'amount',
        description: 'Date sorts put the earliest (most overdue) first.',
      },
      limit: limitProp(30, 200),
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const limit = clampInt(args.limit, 30, 1, 200)
    const key = str(args.customer_key)
    const family = str(args.product_family)
    const query = str(args.query)

    const column =
      { amount: 'backlog_amount', qty: 'backlog_qty', promise_date: 'earliest_promise_date', ship_date: 'earliest_desired_ship_date' }[
        String(args.sort ?? 'amount')
      ] ?? 'backlog_amount'
    const ascending = column.endsWith('_date')

    let q = db
      .from('v_backlog_by_sku')
      .select(
        'customer_key, customer_id, customer_name, part_id, part_description, ' +
          'product_family, chambering, backlog_qty, backlog_amount, open_line_count, ' +
          'earliest_promise_date, earliest_desired_ship_date, latest_order_date',
        { count: 'exact' },
      )

    if (key) q = q.eq('customer_key', key)
    if (family) q = q.eq('product_family', family)
    if (query) {
      const term = safeLike(query)
      if (term) q = q.or(`part_id.ilike.*${term}*,part_description.ilike.*${term}*`)
    }

    const result = await q.order(column, { ascending, nullsFirst: false }).limit(limit)
    const rows = rowsOf(result, 'the backlog')
    return {
      matched: result.count ?? rows.length,
      returned: rows.length,
      returned_totals: {
        backlog_amount: money(rows.reduce((t, r) => t + (num(r.backlog_amount) ?? 0), 0)),
        backlog_qty: rows.reduce((t, r) => t + (num(r.backlog_qty) ?? 0), 0),
      },
      lines: rows.map(compact),
      note: 'Totals cover the returned rows only. Raise `limit` for a full picture.',
    }
  },
}

const checkAvailability: ToolDef = {
  name: 'check_availability',
  title: 'Check stock (ATS)',
  description:
    'Company-wide available-to-sell by SKU: on hand, committed to open ' +
    'orders, total open demand, and the certified ATS figure. Negative ATS ' +
    'means oversold. This is inventory, not the customer\'s backlog — use ' +
    'list_backlog for what a specific account is owed.',
  inputSchema: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'Matches part ID, description, or UPC.' },
      product_family: { type: 'string', description: 'Exact product family, e.g. "RIFLES".' },
      chambering: { type: 'string', description: 'Exact chambering, e.g. "6.5 CREEDMOOR".' },
      available_only: {
        type: 'boolean',
        default: false,
        description: 'Only SKUs with a positive available-to-sell quantity.',
      },
      limit: limitProp(30, 200),
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const limit = clampInt(args.limit, 30, 1, 200)
    const query = str(args.query)
    const family = str(args.product_family)
    const chambering = str(args.chambering)

    let q = db
      .from('v_ats_list')
      .select(
        'part_id, part_description, product_family, chambering, barrel_length, upc, ' +
          'on_hand_qty, committed_qty, backlog_qty, ats_qty, availability_status, ' +
          'is_oversold, loaded_at',
        { count: 'exact' },
      )

    if (family) q = q.eq('product_family', family)
    if (chambering) q = q.eq('chambering', chambering)
    if (args.available_only === true) q = q.gt('ats_qty', 0)
    if (query) {
      const term = safeLike(query)
      if (term) {
        q = q.or(`part_id.ilike.*${term}*,part_description.ilike.*${term}*,upc.ilike.*${term}*`)
      }
    }

    const result = await q.order('ats_qty', { ascending: false, nullsFirst: false }).limit(limit)
    const rows = rowsOf(result, 'availability')

    return {
      matched: result.count ?? rows.length,
      items: rows.map(compact),
      note: 'inbound_qty and next_avail_date are not certified upstream and are always empty.',
    }
  },
}

const listOrders: ToolDef = {
  name: 'list_orders',
  title: 'Orders',
  description:
    'The 20 most recent orders for one account at header level (value, line ' +
    'count, open lines, next promise date). Pass order_id to get that ' +
    'order\'s lines instead. "Bookings" is the order value when placed.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: CUSTOMER_KEY,
      order_id: {
        type: 'string',
        description: 'Drill into one order\'s lines instead of listing headers.',
      },
      limit: limitProp(20, 100),
    },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const limit = clampInt(args.limit, 20, 1, 100)
    const orderId = str(args.order_id)

    if (orderId) {
      const lines = await db
        .from('v_account_order_lines')
        .select(
          'order_id, line_num, order_date, promise_date, line_status_desc, part_id, ' +
            'part_description, order_qty, bookings, backlog_qty, is_backlog_line',
        )
        .eq('customer_key', key)
        .eq('order_id', orderId)
        .order('line_num')
      return { order_id: orderId, lines: rowsOf(lines, 'the order lines').map(compact) }
    }

    const headers = await db
      .from('v_account_recent_order_headers')
      .select(
        'order_id, order_date, order_state, order_status_desc, line_count, order_qty, ' +
          'bookings, open_line_count, backlog_qty, backlog_amount, next_promise_date',
      )
      .eq('customer_key', key)
      .order('order_date', { ascending: false, nullsFirst: false })
      .limit(limit)

    return {
      customer_key: key,
      orders: rowsOf(headers, 'the order history').map(compact),
      note: 'The view keeps the 20 most recent orders per account.',
    }
  },
}

const listShipments: ToolDef = {
  name: 'list_shipments',
  title: 'Shipments',
  description:
    'The 20 most recent shipments (packlists) for one account, with tracking ' +
    'numbers and delivery dates. Pass packlist_id for that shipment\'s lines. ' +
    'Answers "did their order ship" and "where is it".',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: CUSTOMER_KEY,
      packlist_id: { type: 'string', description: 'Drill into one packlist\'s lines.' },
      limit: limitProp(20, 100),
    },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const limit = clampInt(args.limit, 20, 1, 100)
    const packlist = str(args.packlist_id)

    if (packlist) {
      const lines = await db
        .from('v_account_shipment_lines')
        .select(
          'packlist_id, line_num, order_id, invoice_id, ship_date, actual_delivery_date, ' +
            'part_id, part_description, shipped_qty, shipped_revenue',
        )
        .eq('customer_key', key)
        .eq('packlist_id', packlist)
        .order('line_num')
      return { packlist_id: packlist, lines: rowsOf(lines, 'the shipment lines').map(compact) }
    }

    const headers = await db
      .from('v_account_recent_shipment_headers')
      .select(
        'packlist_id, ship_date, actual_delivery_date, shipment_state, ' +
          'shipper_status_desc, tracking_number, ship_via, order_ids, line_count, ' +
          'shipped_qty, shipped_revenue',
      )
      .eq('customer_key', key)
      .order('ship_date', { ascending: false, nullsFirst: false })
      .limit(limit)

    return {
      customer_key: key,
      shipments: rowsOf(headers, 'the shipment history').map(compact),
      note: 'The view keeps the 20 most recent packlists per account.',
    }
  },
}

const getGoalProgress: ToolDef = {
  name: 'get_goal_progress',
  title: 'Goal progress',
  description:
    'Annual sales goals and pace. Without customer_key: the book-wide rollup ' +
    'plus the accounts furthest behind. With one: that account only. Pace is ' +
    'SEASONAL where prior-year history exists (`pace_basis`), so a dealer ' +
    'that books its year in the spring is not flagged behind every June. ' +
    'Negative `gap_to_pace` means behind.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: { ...CUSTOMER_KEY, description: 'Optional — one account instead of the book.' },
      period_year: { type: 'integer', description: 'Defaults to the current year.' },
      limit: limitProp(20, 200),
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const year = clampInt(args.period_year, currentYear(), 2000, 2100)
    const limit = clampInt(args.limit, 20, 1, 200)
    const key = str(args.customer_key)

    const columns =
      'customer_key, customer_name, period_year, target_amount, revenue_to_date, ' +
      'attainment_pct, expected_pct, expected_amount, gap_to_pace, gap_to_goal, ' +
      'projected_amount, on_track, pace_basis, days_remaining, erp_yearly_sales_goal'

    if (key) {
      const single = await db
        .from('v_account_goal_progress')
        .select(columns)
        .eq('customer_key', key)
        .eq('period_year', year)
        .maybeSingle()
      const goal = rowOf(single, 'the goal')
      if (!goal) {
        throw new ToolError(
          `No ${year} goal is set for "${key}". Goals are entered per account in ` +
            `the portal; erp_yearly_sales_goal on get_account carries the ERP's own ` +
            `number when there is one.`,
        )
      }
      return { goal: compact(goal) }
    }

    const [rollup, behind] = await Promise.all([
      db
        .from('v_my_goal_rollup')
        .select(
          'period_year, accounts_with_goal, accounts_behind, target_total, ' +
            'revenue_total, expected_total, attainment_pct, expected_pct',
        )
        .eq('period_year', year)
        .maybeSingle(),
      db
        .from('v_account_goal_progress')
        .select(columns)
        .eq('period_year', year)
        .order('gap_to_pace', { ascending: true, nullsFirst: false })
        .limit(limit),
    ])

    return {
      period_year: year,
      rollup: rowOf(rollup, 'the goal rollup') ?? null,
      accounts_furthest_behind: rowsOf(behind, 'goal progress').map(compact),
    }
  },
}

const listRecommendations: ToolDef = {
  name: 'list_recommendations',
  title: 'Recommendations',
  description:
    'The portal\'s generated work list: which accounts need attention and ' +
    'why. `reason` is the plain-English why-now. Defaults to open items ' +
    'across the book, highest priority first.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: { ...CUSTOMER_KEY, description: 'Optional — one account only.' },
      status: {
        type: 'string',
        enum: ['open', 'acted', 'closed', 'dismissed', 'any'],
        default: 'open',
      },
      priority: { type: 'string', enum: ['high', 'normal', 'low'] },
      limit: limitProp(25, 200),
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const limit = clampInt(args.limit, 25, 1, 200)
    const key = str(args.customer_key)
    const status = String(args.status ?? 'open')
    const priority = str(args.priority)

    let q = db
      .from('recommendations')
      .select(
        'id, customer_key, title, reason, priority, status, due_date, rule_key, ' +
          'source, outcome, created_at',
        { count: 'exact' },
      )
    if (key) q = q.eq('customer_key', key)
    if (status !== 'any') q = q.eq('status', status)
    if (priority) q = q.eq('priority', priority)

    const result = await q.order('created_at', { ascending: false }).limit(limit)
    const rows = rowsOf(result, 'recommendations')
    const names = await accountNames(db, rows.map((r) => String(r.customer_key)))

    const rank: Record<string, number> = { high: 0, normal: 1, low: 2 }
    return {
      matched: result.count ?? rows.length,
      recommendations: rows
        .map((r): Row => compact({ ...r, customer_name: names.get(String(r.customer_key)) ?? null }))
        .sort((a, b) => (rank[String(a.priority)] ?? 3) - (rank[String(b.priority)] ?? 3)),
    }
  },
}

/** Account names for a set of keys, in one round trip. Empty set → no query. */
async function accountNames(db: SupabaseClient, keys: string[]): Promise<Map<string, string>> {
  const unique = [...new Set(keys.filter(Boolean))]
  if (unique.length === 0) return new Map()
  const result = await db
    .from('v_account_list')
    .select('customer_key, customer_name')
    .in('customer_key', unique.slice(0, 200))
  return new Map(
    rowsOf(result, 'account names').map((r) => [
      String(r.customer_key),
      String(r.customer_name ?? ''),
    ]),
  )
}

const listAccountActivity: ToolDef = {
  name: 'list_account_activity',
  title: 'Account activity',
  description:
    'What the rep team has actually done at one account: notes, logged calls ' +
    'and visits, and visit survey findings (inventory level, store condition, ' +
    'competitor presence), newest first. This is the CRM side — pair it with ' +
    'get_account for the numbers.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: CUSTOMER_KEY,
      limit: limitProp(15, 100),
    },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const limit = clampInt(args.limit, 15, 1, 100)

    const [notes, actions, visits] = await Promise.all([
      db
        .from('notes')
        .select('id, body, created_at')
        .eq('customer_key', key)
        .order('created_at', { ascending: false })
        .limit(limit),
      db
        .from('actions')
        .select('id, action_type, action_date, note, created_at')
        .eq('customer_key', key)
        .order('action_date', { ascending: false })
        .limit(limit),
      db
        .from('visits')
        .select(
          'id, visit_type, visit_date, inventory_level, store_condition, ' +
            'display_quality, staff_knowledge, store_traffic, competitor_promos, ' +
            'competition_seen, comments',
        )
        .eq('customer_key', key)
        .order('visit_date', { ascending: false })
        .limit(limit),
    ])

    const noteRows = rowsOf(notes, 'account notes')
    const actionRows = rowsOf(actions, 'logged actions')
    const visitRows = rowsOf(visits, 'visits')

    interface Entry extends Row {
      kind: string
      date: string
    }
    const timeline: Entry[] = []

    for (const n of noteRows) {
      timeline.push({ kind: 'note', date: String(n.created_at).slice(0, 10), body: n.body })
    }
    for (const a of actionRows) {
      timeline.push({
        kind: 'action',
        date: String(a.action_date),
        action_type: a.action_type,
        note: a.note,
      })
    }
    for (const v of visitRows) {
      const seen = Array.isArray(v.competition_seen) ? v.competition_seen : []
      timeline.push({
        kind: 'visit',
        date: String(v.visit_date),
        visit_type: v.visit_type,
        inventory_level: v.inventory_level,
        store_condition: v.store_condition,
        display_quality: v.display_quality,
        staff_knowledge: v.staff_knowledge,
        store_traffic: v.store_traffic,
        competitor_promos: v.competitor_promos,
        competition_seen: seen.length ? seen : null,
        comments: v.comments,
      })
    }

    timeline.sort((a, b) => b.date.localeCompare(a.date))

    return {
      customer_key: key,
      activity: timeline.slice(0, limit).map((e) => compact(e)),
      counts: {
        notes: noteRows.length,
        actions: actionRows.length,
        visits: visitRows.length,
      },
      note:
        'Author identity is deliberately not returned. Counts are of the rows read ' +
        `under the same limit (${limit}), not lifetime totals.`,
    }
  },
}

const listContacts: ToolDef = {
  name: 'list_contacts',
  title: 'Account contacts',
  description:
    'People at one account: ERP system-of-record contacts plus anything the ' +
    'reps have captured in the portal (`source` says which). Answers "who do ' +
    'I call".',
  inputSchema: {
    type: 'object',
    properties: { customer_key: CUSTOMER_KEY },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const result = await db
      .from('v_account_contacts')
      .select('source, name, title, phone, email, is_primary, notes')
      .eq('customer_key', key)
      .order('is_primary', { ascending: false })

    return {
      customer_key: key,
      contacts: rowsOf(result, 'contacts').map(compact),
    }
  },
}

const getGlobalProductSales: ToolDef = {
  name: 'get_global_product_sales',
  title: 'Company-wide product sales',
  description:
    'How a SKU sells COMPANY-WIDE, in units — the benchmark for "is my ' +
    'territory under-indexed on this product". Units, invoice counts and ' +
    'account counts only: company-level revenue and per-account detail are ' +
    'deliberately not available to anyone through this endpoint.',
  inputSchema: {
    type: 'object',
    properties: {
      months: {
        type: 'integer',
        minimum: 1,
        maximum: 36,
        default: 12,
        description: 'Whole months back, plus the current partial month.',
      },
      query: { type: 'string', description: 'Matches part ID or description.' },
      product_family: { type: 'string', description: 'Exact product family, e.g. "RIFLES".' },
      limit: limitProp(30, 200),
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const months = clampInt(args.months, 12, 1, 36)
    const limit = clampInt(args.limit, 30, 1, 200)
    const query = str(args.query)?.toLowerCase() ?? null
    const family = str(args.product_family)?.toLowerCase() ?? null

    // The RPC ranks by units and clamps its own limit; filtering happens here
    // because it takes no filter arguments (033) and its result is small.
    const result = await db.rpc('report_global_product_sales', {
      p_months: months,
      p_limit: 2000,
    })

    let rows = rowsOf(result, 'company-wide product sales')
    if (family) {
      rows = rows.filter((r) => String(r.product_family ?? '').toLowerCase() === family)
    }
    if (query) {
      rows = rows.filter(
        (r) =>
          String(r.part_id ?? '').toLowerCase().includes(query) ||
          String(r.part_description ?? '').toLowerCase().includes(query),
      )
    }

    return {
      months,
      matched: rows.length,
      products: rows.slice(0, limit).map(compact),
      note: 'Units only, ranked by units. There is no revenue figure at company level.',
    }
  },
}

/*============================================================================
  Registry
============================================================================*/

const ALL_TOOLS: ToolDef[] = [
  whoami,
  searchAccounts,
  getAccount,
  getAccountSkuSales,
  getTerritorySummary,
  listTerritoryAccounts,
  getSkuSales,
  listBacklog,
  checkAvailability,
  listOrders,
  listShipments,
  getGoalProgress,
  listRecommendations,
  listAccountActivity,
  listContacts,
  getGlobalProductSales,
]

/**
 * MCP_DISABLED_TOOLS turns tools off without a deploy — a comma-separated
 * list of names. It exists mainly for `list_contacts`: the AI summary path
 * deliberately keeps contact PII out of a model's context (functions/README
 * §PII), and while a rep asking "who do I call" is a different question from
 * bulk-feeding a prompt, that judgement should be reversible from the
 * dashboard rather than from a pull request.
 */
const disabled = new Set(
  (Deno.env.get('MCP_DISABLED_TOOLS') ?? '')
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean),
)

export const TOOLS: ToolDef[] = ALL_TOOLS.filter((tool) => !disabled.has(tool.name))

export const TOOLS_BY_NAME = new Map(TOOLS.map((tool) => [tool.name, tool]))

/** The wire form of a tool, as `tools/list` returns it. */
export function describeTool(tool: ToolDef) {
  return {
    name: tool.name,
    title: tool.title,
    description: tool.description,
    inputSchema: tool.inputSchema,
    annotations: { title: tool.title, ...READ_ONLY },
  }
}
