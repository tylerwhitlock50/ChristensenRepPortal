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
  Ranking, filtering and whole-book totals happen in Postgres (ORDER BY …
  LIMIT and report_territory_summary() — see 20260817120000); the rollups,
  rebuilt with every full and hourly load, make that milliseconds. The only
  reads that still page a relation are the SKU pivots, under a unique ORDER
  BY and a hard cap. Those report two distinct facts a model should not
  have to disentangle: `has_more` (more SKUs than `limit` — raise it) and
  `capped_at` (the source-row ceiling was hit, so even the totals may
  undercount — narrow the filters).
  Every list tool caps `limit` and says so in its description.
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import type { McpCaller } from '../_shared/mcpAuth.ts'
import { bestContact, rankContacts, type RankableContact } from '../_shared/contacts.ts'

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
 * Reads a whole relation in pages, under a hard cap. Callers must give the
 * page query a UNIQUE ORDER BY — unordered LIMIT/OFFSET pages can skip and
 * duplicate rows between requests. Used only by the SKU pivots, which
 * genuinely need the rows client-side.
 */
async function fetchCapped(
  page: (from: number, to: number) => PromiseLike<PgResult>,
  cap: number,
  what: string,
): Promise<{ rows: Row[]; capped: boolean }> {
  const SIZE = 1000
  const rows: Row[] = []
  for (let from = 0; from < cap; from += SIZE) {
    const to = Math.min(from + SIZE, cap) - 1
    const batch = rowsOf(await page(from, to), what)
    rows.push(...batch)
    // A short page is the end of the relation; a full one that lands on the
    // cap means the ceiling was hit and rows beyond it were never read.
    if (batch.length < to - from + 1) return { rows, capped: false }
  }
  return { rows, capped: true }
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
    'date in the warehouse — "this month" means through that date, not today. ' +
    '`etl_loaded_at` is the last order/shipment/invoice load (hourly on ' +
    'weekdays); `ats_loaded_at` the last stock load (every 15 minutes on weekdays).',
  inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  async handler(_args, { db, caller }) {
    const freshnessRead = (columns: string) =>
      db.from('v_data_freshness').select(columns).maybeSingle()
    const [all, active, firstFresh] = await Promise.all([
      db.from('v_account_list').select('customer_key', { count: 'exact', head: true }),
      db
        .from('v_account_list')
        .select('customer_key', { count: 'exact', head: true })
        .eq('active_flag', 'Y')
        .is('deactivated_at', null),
      freshnessRead('data_loaded_at, data_through, ats_loaded_at'),
    ])

    if (all.error) fail(all.error, 'your account book')

    // ats_loaded_at arrived with 20261027090100; a database without it
    // still answers with the other two.
    let fresh: PgResult = firstFresh
    if (fresh.error && isMissingColumn(fresh.error)) {
      fresh = await freshnessRead('data_loaded_at, data_through')
    }
    const freshRow = (fresh.data ?? null) as Row | null

    // Freshness is the one field the instructions tell every session to read
    // first — if it cannot be read (typically: a load is mid-swap and
    // holding locks), say so instead of returning an empty object.
    const freshness = fresh.error
      ? {
          unavailable: true,
          note:
            'Data freshness could not be read — a load may be running right ' +
            'now. Figures may shift; retry in a few minutes.',
        }
      : compact({
          etl_loaded_at: freshRow?.data_loaded_at ?? null,
          data_through: freshRow?.data_through ?? null,
          ats_loaded_at: freshRow?.ats_loaded_at ?? null,
        })

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
      data_freshness: freshness,
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
    'value is booked but not yet shipped. The goal\'s `goal_source` says ' +
    'where the target comes from: "crm" = entered in the portal (overrides), ' +
    '"erp" = the ERP customer master\'s yearly sales goal (the default).',
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
          // Aliased: this yoy is TRAILING-12M vs the prior 12 months (the
          // scoring window, 019), not the calendar-YTD figure in `revenue` —
          // the two legitimately disagree in sign and read as a contradiction
          // when both are called yoy_change.
          'score, priority, days_since_order, cadence_days, cadence_confident, ' +
            'days_since_touch, last_touch_date, yoy_change_trailing_12m:yoy_change, ' +
            'families_dropped, open_backlog_amount, revenue_percentile, computed_at',
        )
        .eq('customer_key', key)
        .maybeSingle(),
      db
        .from('v_account_goal_progress')
        .select(
          'period_year, target_amount, revenue_to_date, attainment_pct, expected_pct, ' +
            'gap_to_pace, gap_to_goal, projected_amount, on_track, pace_basis, ' +
            'erp_yearly_sales_goal, days_remaining, goal_source',
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
        trend: 'get_account_revenue_trend for the month-by-month line',
        opportunities: 'get_account_sku_gaps for in-stock SKUs they do not carry',
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

    const CAP = 3000
    const { rows, capped } = await fetchCapped(
      (from, to) =>
        db
          .from('v_sku_sales_by_account')
          .select(
            'part_key, part_id, part_description, product_family, chambering, ' +
              'sales_year, revenue, qty, last_invoice_date',
          )
          .eq('customer_key', key)
          // Unique-key ordering: unordered LIMIT/OFFSET pages can skip and
          // duplicate rows between requests.
          .order('part_key')
          .order('sales_year')
          .range(from, to),
      CAP,
      'SKU sales for this account',
    )

    return pivotSkuRows(rows, capped ? CAP : null, String(args.sort ?? 'revenue'), limit)
  },
}

/** Shared by the account-level and territory-level SKU tools. */
function pivotSkuRows(rows: Row[], cappedAt: number | null, sort: string, limit: number) {
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
    // Two different shortfalls, reported separately: has_more means the pivot
    // holds more SKUs than `limit` (raise it); capped_at means the source-row
    // read hit its ceiling, so sku_count and every total may UNDERCOUNT —
    // narrow with a query/family filter instead of raising `limit`.
    has_more: list.length > shown.length,
    ...(cappedAt === null
      ? {}
      : {
          capped_at: cappedAt,
          note:
            `The read stopped at ${cappedAt} source rows, so totals and rankings ` +
            'may be incomplete. Narrow the search (query, product_family, chambering) ' +
            'rather than raising `limit`.',
        }),
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
  Territory. Both tools read the same rollup (030, rebuilt with every full
  and hourly load), so they always agree with each other and with the
  portal's Overview page.

  Ranking and totals happen IN POSTGRES (view columns + ORDER BY … LIMIT,
  and report_territory_summary() for the aggregates — 20260817120000). The
  previous shape — page 5,000 rows with no ORDER BY, then sort in TypeScript
  — silently ranked an arbitrary physical-order prefix of a big book: an
  admin's reported top account was actually #4 and totals were 82% short.
  The rollup is one indexed row per account, so the full ORDER BY is
  milliseconds; there is nothing left to cap.
----------------------------------------------------------------------------*/

const TERRITORY_COLUMNS =
  'customer_key, customer_name, sold_to_city, sold_to_state, yearly_sales_goal, ' +
  'revenue_ytd, revenue_prior_ytd, revenue_trailing_12m, last_invoice_date, ' +
  'open_order_value, backlog_qty, backlog_amount, yoy_change_amount, yoy_change_pct, ' +
  'first_invoice_date'

// The sort keys list_territory_accounts accepts. Named once so the schema the
// model reads and the check the handler runs cannot drift apart. Every entry
// must be a real column of v_territory_account_yoy — the ORDER BY is SQL now.
const TERRITORY_SORTS = [
  'revenue_ytd',
  'revenue_prior_ytd',
  'revenue_trailing_12m',
  'yoy_change_amount',
  'yoy_change_pct',
  'open_order_value',
  'backlog_amount',
  // desc = newest accounts first (the "who is new" question); accounts that
  // have never invoiced sort last in either direction (nulls last).
  'first_invoice_date',
] as const
type TerritorySort = (typeof TERRITORY_SORTS)[number]

function territoryRow(r: Row) {
  return compact({
    customer_key: r.customer_key,
    customer_name: r.customer_name,
    city: r.sold_to_city,
    state: r.sold_to_state,
    revenue_ytd: money(r.revenue_ytd),
    revenue_prior_ytd: money(r.revenue_prior_ytd),
    yoy_change_amount: money(r.yoy_change_amount),
    yoy_change_pct: num(r.yoy_change_pct),
    open_order_value: money(r.open_order_value),
    backlog_amount: money(r.backlog_amount),
    last_invoice_date: r.last_invoice_date,
    first_invoice_date: r.first_invoice_date,
  })
}

/**
 * A ranked slice of the book. `customer_key` as the final ORDER BY term so
 * ties (whole pages of $0 accounts) rank deterministically; nulls last in
 * both directions so "worst decliners, ascending" never leads with accounts
 * that simply have no comparison.
 */
function territoryQuery(db: SupabaseClient, sort: string, ascending: boolean) {
  return db
    .from('v_territory_account_yoy')
    .select(TERRITORY_COLUMNS, { count: 'exact' })
    .order(sort, { ascending, nullsFirst: false })
    .order('customer_key')
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

    const cutoff = new Date(Date.now() - quietDays * 86_400_000).toISOString().slice(0, 10)

    // Totals come from report_territory_summary() — a true whole-book
    // aggregate — and each highlight list is its own ORDER BY … LIMIT.
    // Six small indexed reads instead of hauling the book into TypeScript.
    const [totals, goals, topAccounts, growth, decline, quiet] = await Promise.all([
      db.rpc('report_territory_summary').maybeSingle(),
      db
        .from('v_my_goal_rollup')
        .select(
          'period_year, accounts_with_goal, accounts_behind, target_total, ' +
            'revenue_total, attainment_pct, expected_pct',
        )
        .eq('period_year', currentYear())
        .maybeSingle(),
      territoryQuery(db, 'revenue_ytd', false).limit(top),
      territoryQuery(db, 'yoy_change_amount', false).gt('yoy_change_amount', 0).limit(top),
      territoryQuery(db, 'yoy_change_amount', true).lt('yoy_change_amount', 0).limit(top),
      // Gone quiet: some business on the books, but nothing invoiced since
      // the cutoff (or ever). Biggest prior-year accounts first.
      territoryQuery(db, 'revenue_prior_ytd', false)
        .or('revenue_trailing_12m.gt.0,revenue_prior_ytd.gt.0')
        .or(`last_invoice_date.is.null,last_invoice_date.lt.${cutoff}`)
        .limit(top),
    ])

    const t = (rowOf(totals as PgResult, 'the territory totals') ?? {}) as Row
    const ytd = num(t.revenue_ytd) ?? 0
    const prior = num(t.revenue_prior_ytd) ?? 0

    return {
      totals: {
        accounts: num(t.accounts) ?? 0,
        accounts_with_ytd_revenue: num(t.accounts_with_ytd_revenue) ?? 0,
        revenue_ytd: money(ytd),
        revenue_prior_ytd: money(prior),
        yoy_change_amount: money(ytd - prior),
        yoy_change_pct: prior > 0 ? pct(ytd - prior, prior) : null,
        revenue_trailing_12m: money(t.revenue_trailing_12m),
        open_order_value: money(t.open_order_value),
        backlog_amount: money(t.backlog_amount),
        backlog_qty: num(t.backlog_qty) ?? 0,
      },
      goal: rowOf(goals, 'the goal rollup') ?? null,
      top_accounts: rowsOf(topAccounts, 'the top accounts').map(territoryRow),
      biggest_growth: rowsOf(growth, 'the biggest growers').map(territoryRow),
      biggest_decline: rowsOf(decline, 'the biggest decliners').map(territoryRow),
      gone_quiet: {
        no_invoice_since_days: quietDays,
        count: (quiet as PgResult).count ?? rowsOf(quiet, 'the gone-quiet accounts').length,
        accounts: rowsOf(quiet, 'the gone-quiet accounts').map(territoryRow),
      },
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
    'call this week" better than search_accounts, which sorts by name. ' +
    'sort "first_invoice_date" desc answers "which accounts are NEW" — ' +
    'first_invoice_date is the account\'s first invoice ever, absent = ' +
    'never invoiced (a pure prospect).',
  inputSchema: {
    type: 'object',
    properties: {
      sort: {
        type: 'string',
        enum: TERRITORY_SORTS,
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
    // Validate before it reaches ORDER BY: a clear "use one of …" beats
    // PostgREST's column-does-not-exist error, and a model that guessed
    // "revenue" can then guess again.
    const requested = String(args.sort ?? 'revenue_ytd')
    if (!TERRITORY_SORTS.includes(requested as TerritorySort)) {
      throw new ToolError(
        `"${requested}" is not a sort key for this tool. Use one of: ` +
          `${TERRITORY_SORTS.join(', ')}.`,
      )
    }
    const sort = requested as TerritorySort
    const ascending = args.direction === 'asc'
    const state = str(args.state)
    const minPrior = num(args.min_prior_ytd)

    // Filters and ORDER BY run in Postgres over the whole book — `matched`
    // is the true filtered count, and the top of the list is the actual top.
    let q = territoryQuery(db, sort, ascending)
    if (state) q = q.ilike('sold_to_state', state)
    if (minPrior !== null) q = q.gte('revenue_prior_ytd', minPrior)

    const result = await q.limit(limit)
    const rows = rowsOf(result, 'the territory rollup')

    return {
      matched: result.count ?? rows.length,
      sorted_by: `${sort} ${ascending ? 'asc' : 'desc'}`,
      accounts: rows.map(territoryRow),
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

    const CAP = 5000
    const { rows, capped } = await fetchCapped(
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
        // Unique-key ordering: see get_account_sku_sales.
        return q.order('part_key').order('sales_year').range(from, to)
      },
      CAP,
      'territory SKU sales',
    )

    return pivotSkuRows(rows, capped ? CAP : null, String(args.sort ?? 'revenue'), limit)
  },
}

/**
 * 'yyyy-mm' for month `m` (0-based) of year `y`. `m` may run negative or past
 * 11; Date normalises it.
 */
function monthKey(y: number, m: number): string {
  const d = new Date(Date.UTC(y, m, 1))
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`
}

/**
 * How many months get_sales_summary always reads, whatever `months` asks
 * for. The summary's furthest look-back is January of last year: 24 months
 * including this one, in December. 25 is the tool's default `months` and
 * leaves a month of slack.
 */
export const SALES_SUMMARY_MONTHS = 25

/**
 * The `summary` block of get_sales_summary, from report_sales_by_month rows
 * (any order; months with no invoices absent). Pure, so the month arithmetic
 * is testable.
 *
 * The rows must reach back SALES_SUMMARY_MONTHS. A prior-year figure summed
 * from fewer months is not null, it is wrong: with only 13 months read,
 * year_to_date_last_year was last October alone and the YTD comparison
 * read +829%.
 */
export function summariseSalesMonths(rows: Row[], now: Date = new Date()) {
  // Index by 'yyyy-mm' for the lookups below.
  const byMonth = new Map<string, Row>()
  for (const r of rows) byMonth.set(String(r.sales_month).slice(0, 7), r)
  const rev = (key: string) => num(byMonth.get(key)?.revenue)

  const year = now.getUTCFullYear()
  const month = now.getUTCMonth() // 0-based

  // Sum of the months from `fromMonth` (0-based) through `month` in `y`,
  // null when none of them had invoices.
  const span = (y: number, fromMonth: number): number | null => {
    let total = 0
    let seen = false
    for (let m = fromMonth; m <= month; m++) {
      const v = rev(monthKey(y, m))
      if (v !== null) {
        total += v
        seen = true
      }
    }
    return seen ? total : null
  }

  const thisMonth = rev(monthKey(year, month))
  const lastMonth = rev(monthKey(year, month - 1))
  const sameMonthLastYear = rev(monthKey(year - 1, month))
  const quarterStart = month - (month % 3)
  const qtd = span(year, quarterStart)
  const qtdLastYear = span(year - 1, quarterStart)
  const ytd = span(year, 0)
  const ytdLastYear = span(year - 1, 0)

  return {
    this_month: money(thisMonth),
    this_month_note: 'Partial — through the newest invoice loaded (see whoami data_through).',
    last_month: money(lastMonth),
    same_month_last_year: money(sameMonthLastYear),
    this_month_vs_last_year_pct:
      thisMonth !== null && sameMonthLastYear ? pct(thisMonth - sameMonthLastYear, sameMonthLastYear) : null,
    quarter_to_date: money(qtd),
    quarter_to_date_last_year: money(qtdLastYear),
    year_to_date: money(ytd),
    year_to_date_last_year: money(ytdLastYear),
    ytd_vs_last_year_pct:
      ytd !== null && ytdLastYear ? pct(ytd - ytdLastYear, ytdLastYear) : null,
  }
}

const getSalesSummary: ToolDef = {
  name: 'get_sales_summary',
  title: 'Sales by month',
  description:
    'Invoiced revenue by calendar month — THE tool for "what are my sales ' +
    'this month", "last month vs the month before", "this quarter", and ' +
    '"how am I trending". Whole book by default; pass customer_key for one ' +
    'account. The newest month is partial up to `data_through` (whoami). ' +
    'Monthly grain only — for finer or custom windows, say so and use the ' +
    'series to approximate.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: {
        ...CUSTOMER_KEY,
        description: 'Optional — one account instead of the whole book.',
      },
      months: {
        type: 'integer',
        minimum: 1,
        maximum: 48,
        default: 25,
        description:
          'How many months of the `months` series to return, newest month ' +
          'included. `summary` (this month, QTD, YTD and their prior-year ' +
          'figures) is complete whatever this is.',
      },
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const months = clampInt(args.months, 25, 1, 48)
    const key = str(args.customer_key)

    // Always read enough for the summary, then return only the months asked
    // for. At 25 or more (the default) that is everything read, exactly the
    // function's answer. Fewer: the newest `months`, counted back from the
    // same "this month" the summary uses.
    const fetched = Math.max(months, SALES_SUMMARY_MONTHS)
    const result = await db.rpc('report_sales_by_month', {
      p_customer_key: key,
      p_months: fetched,
    })
    const rows = rowsOf(result, 'monthly sales')

    const now = new Date()
    const since = monthKey(now.getUTCFullYear(), now.getUTCMonth() - (months - 1))
    const series =
      fetched === months ? rows : rows.filter((r) => String(r.sales_month).slice(0, 7) >= since)

    return {
      scope: key ?? 'whole book',
      months_requested: months,
      summary: summariseSalesMonths(rows, now),
      // Oldest first, so a model can read the trend left to right.
      months: series.map((r) =>
        compact({
          month: String(r.sales_month).slice(0, 7),
          revenue: money(r.revenue),
          qty: num(r.qty),
          invoices: num(r.invoice_count),
          accounts: key ? undefined : num(r.account_count),
        }),
      ),
      note:
        'Revenue is invoiced (shipped) dollars per calendar month. Months ' +
        'with no invoices are simply absent from the series. YTD/QTD ' +
        'comparisons are month-aligned, not day-aligned — for day-aligned ' +
        'prior-YTD use get_territory_summary or get_account.',
    }
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
    // Date sorts answer "what is most overdue" — a question about product
    // owed. Zero-dollar lines (RMA repair workflow rows with promise dates
    // years back) and credit lines would otherwise fill the whole first
    // page, so they are excluded HERE ONLY; amount/qty sorts still return
    // them, flagged below.
    if (ascending) q = q.gt('backlog_amount', 0)

    const result = await q.order(column, { ascending, nullsFirst: false }).limit(limit)
    const rows = rowsOf(result, 'the backlog')
    return {
      matched: result.count ?? rows.length,
      returned: rows.length,
      returned_totals: {
        backlog_amount: money(rows.reduce((t, r) => t + (num(r.backlog_amount) ?? 0), 0)),
        backlog_qty: rows.reduce((t, r) => t + (num(r.backlog_qty) ?? 0), 0),
      },
      lines: rows.map((r) => {
        const line = compact(r) as Row
        // Open discount/rebate/credit lines (mostly non-stock, negative unit
        // price) roll up to a negative amount. They are real order content
        // that nets against the dollar total, but they are not product owed —
        // flagged so a model never reads one as a SKU to be shipped.
        if ((num(r.backlog_amount) ?? 0) < 0) line.is_credit_or_discount = true
        return line
      }),
      note:
        'Totals cover the returned rows only — raise `limit` for a full picture. ' +
        'Rows flagged is_credit_or_discount are open credit/discount lines ' +
        '(negative amount): they reduce the dollar backlog but are not product owed. ' +
        'Date sorts exclude zero/negative-amount lines (RMA repair rows carry ' +
        'years-old promise dates); amount and qty sorts include everything.',
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
    'Order history for one account at header level (value, line count, open ' +
    'lines, next promise date), newest first. FULL history — page older ' +
    'orders with `offset`. Pass order_id to get that order\'s lines instead. ' +
    '"Bookings" is the order value when placed; negative bookings are ' +
    'credit/return orders.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: CUSTOMER_KEY,
      order_id: {
        type: 'string',
        description: 'Drill into one order\'s lines instead of listing headers.',
      },
      limit: limitProp(20, 100),
      offset: { type: 'integer', minimum: 0, default: 0, description: 'For paging older orders.' },
    },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const limit = clampInt(args.limit, 20, 1, 100)
    const offset = clampInt(args.offset, 0, 0, 100_000)
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
          'bookings, open_line_count, backlog_qty, backlog_amount, next_promise_date, ' +
          'customer_po_number',
        { count: 'exact' },
      )
      .eq('customer_key', key)
      // order_id as the unique tiebreak so same-day orders page stably.
      .order('order_date', { ascending: false, nullsFirst: false })
      .order('order_id', { ascending: false })
      .range(offset, offset + limit - 1)

    const rows = rowsOf(headers, 'the order history')
    return {
      customer_key: key,
      order_count: headers.count ?? rows.length,
      offset,
      orders: rows.map(compact),
    }
  },
}

/** Shipment dollars: the packlist value first, the older figure beside it. */
const SHIPPED_VALUE_COLUMNS = 'shipped_value, shipped_revenue'

const listShipments: ToolDef = {
  name: 'list_shipments',
  title: 'Shipments',
  description:
    'Shipments (packlists) for one account, newest first, with tracking ' +
    'numbers and delivery dates. FULL history — page older shipments with ' +
    '`offset`. Pass packlist_id for that shipment\'s lines. Answers "did ' +
    'their order ship" and "where is it". `shipped_value` is the packlist ' +
    'value (qty × net price) — NOT revenue: shipping runs ahead of invoicing, ' +
    'and only invoiced lines count as sales.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: CUSTOMER_KEY,
      packlist_id: { type: 'string', description: 'Drill into one packlist\'s lines.' },
      limit: limitProp(20, 100),
      offset: { type: 'integer', minimum: 0, default: 0, description: 'For paging older shipments.' },
    },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const limit = clampInt(args.limit, 20, 1, 100)
    const offset = clampInt(args.offset, 0, 0, 100_000)
    const packlist = str(args.packlist_id)

    // shipped_value arrived with 20261027090300. Asked for first; a database
    // without it answers with shipped_revenue alone (the older figure),
    // rather than failing the tool.
    if (packlist) {
      const readLines = (value: string) =>
        db
          .from('v_account_shipment_lines')
          .select(
            'packlist_id, line_num, order_id, invoice_id, ship_date, actual_delivery_date, ' +
              `part_id, part_description, shipped_qty, ${value}`,
          )
          .eq('customer_key', key)
          .eq('packlist_id', packlist)
          .order('line_num')
      let lines: PgResult = await readLines(SHIPPED_VALUE_COLUMNS)
      if (lines.error && isMissingColumn(lines.error)) lines = await readLines('shipped_revenue')
      return { packlist_id: packlist, lines: rowsOf(lines, 'the shipment lines').map(compact) }
    }

    const readHeaders = (value: string) =>
      db
        .from('v_account_recent_shipment_headers')
        .select(
          'packlist_id, ship_date, actual_delivery_date, shipment_state, ' +
            'shipper_status_desc, tracking_number, ship_via, order_ids, line_count, ' +
            `shipped_qty, ${value}`,
          { count: 'exact' },
        )
        .eq('customer_key', key)
        // packlist_id as the unique tiebreak so same-day shipments page stably.
        .order('ship_date', { ascending: false, nullsFirst: false })
        .order('packlist_id', { ascending: false })
        .range(offset, offset + limit - 1)
    let headers: PgResult = await readHeaders(SHIPPED_VALUE_COLUMNS)
    if (headers.error && isMissingColumn(headers.error)) {
      headers = await readHeaders('shipped_revenue')
    }

    const rows = rowsOf(headers, 'the shipment history')
    return {
      customer_key: key,
      shipment_count: headers.count ?? rows.length,
      offset,
      shipments: rows.map(compact),
    }
  },
}

const lookupOrder: ToolDef = {
  name: 'lookup_order',
  title: 'Find an order by number',
  description:
    'Cross-account order lookup by OUR order number, the dealer\'s PO ' +
    'number, or a tracking number — for "where is PO 44182?" when you do ' +
    'not know which account it belongs to. Substring match, newest first; ' +
    '`matched_on` says which field hit. Drill into lines with ' +
    'list_orders(customer_key, order_id).',
  inputSchema: {
    type: 'object',
    properties: {
      term: {
        type: 'string',
        description: 'Order number, dealer PO number, or tracking number (full or partial).',
      },
      limit: limitProp(25, 100),
    },
    required: ['term'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const term = str(args.term)
    if (!term) {
      throw new ToolError(
        '`term` is required — an order number, dealer PO number, or tracking number.',
      )
    }
    const limit = clampInt(args.limit, 25, 1, 100)

    // SECURITY INVOKER RPC (035): RLS on the erp facts scopes the search to
    // the caller's book, same as every view here.
    const result = await db.rpc('lookup_orders', { p_term: term, p_limit: limit })
    const rows = rowsOf(result, 'the order lookup')

    return {
      term,
      matched: rows.length,
      orders: rows.map(compact),
      ...(rows.length === 0
        ? {
            note:
              'No order in your book matches. The number may be mistyped, or the ' +
              'order may belong to an account outside your territory.',
          }
        : {}),
    }
  },
}

const getAccountRevenueTrend: ToolDef = {
  name: 'get_account_revenue_trend',
  title: 'Monthly revenue trend',
  description:
    'Invoiced revenue by month for one account, trailing 24 months — the ' +
    'trend line behind get_account\'s YTD totals: seasonality, momentum, ' +
    'and when a slowdown actually started. Months with no invoices are ' +
    'omitted (they are zeros).',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: CUSTOMER_KEY,
      months: {
        type: 'integer',
        minimum: 1,
        maximum: 24,
        default: 24,
        description: 'How many trailing months to return (max 24 — the view\'s window).',
      },
    },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const months = clampInt(args.months, 24, 1, 24)

    const result = await db
      .from('v_account_revenue_monthly')
      .select('month, revenue, invoice_count')
      .eq('customer_key', key)
      .order('month', { ascending: false })
      .limit(months)

    const rows = rowsOf(result, 'the monthly revenue trend')
    return {
      customer_key: key,
      months_returned: rows.length,
      trend: rows.map((r) =>
        compact({
          month: String(r.month ?? '').slice(0, 7),
          revenue: money(r.revenue),
          invoice_count: num(r.invoice_count),
        }),
      ),
      note:
        'Invoiced (shipped) dollars, memos excluded. A month absent from the ' +
        'list had zero invoices.',
    }
  },
}

const getAccountSkuGaps: ToolDef = {
  name: 'get_account_sku_gaps',
  title: 'Selling opportunities',
  description:
    'SKUs in stock TODAY that this account does not buy, ranked by how many ' +
    'dealers company-wide do — the "everyone else stocks this and we can ' +
    'ship it now" pitch list. `bought_before` true with an old date is the ' +
    '"they used to carry this" conversation. Units and dealer counts only; ' +
    'finished firearms only.',
  inputSchema: {
    type: 'object',
    properties: {
      customer_key: CUSTOMER_KEY,
      months: {
        type: 'integer',
        minimum: 1,
        maximum: 36,
        default: 12,
        description: 'Window for the company-wide dealer counts, in months back.',
      },
      min_dealers: {
        type: 'integer',
        minimum: 1,
        maximum: 100,
        default: 4,
        description: 'Only SKUs at least this many dealers buy — filters out one-off specials.',
      },
      limit: limitProp(25, 100),
    },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)
    const months = clampInt(args.months, 12, 1, 36)
    const minDealers = clampInt(args.min_dealers, 4, 1, 100)
    const limit = clampInt(args.limit, 25, 1, 100)

    // DEFINER RPC (036): dealer breadth is a company-wide count no rep's RLS
    // would return. It verifies the caller's access to this account FIRST and
    // returns nothing otherwise — so an empty result and a wrong key look the
    // same, which the note below explains.
    const result = await db.rpc('report_account_sku_gaps', {
      p_customer_key: key,
      p_months: months,
      p_min_dealers: minDealers,
      p_limit: limit,
    })
    const rows = rowsOf(result, 'the SKU gap report')

    return {
      customer_key: key,
      window_months: months,
      min_dealers: minDealers,
      opportunities: rows.map(compact),
      ...(rows.length === 0
        ? {
            note:
              'Empty means either no in-stock SKU clears the min_dealers bar, or ' +
              'this customer_key is not in your book — verify it with search_accounts.',
          }
        : {
            note:
              'ats_qty is shippable today. dealer_count / units_sold are company-wide ' +
              'over the window — units only, never dollars.',
          }),
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
    'Negative `gap_to_pace` means behind. Every goal carries `goal_source`: ' +
    '"crm" = a target entered in the portal (overrides), "erp" = the ERP ' +
    'customer master\'s yearly sales goal — the fallback when no portal ' +
    'target exists, current year only.',
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
      'projected_amount, on_track, pace_basis, days_remaining, erp_yearly_sales_goal, ' +
      'goal_source'

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
          `No ${year} goal exists for "${key}" — neither a portal-entered target ` +
            `nor an ERP yearly goal (the customer master's USER_3 field).`,
        )
      }
      // goal_source: 'crm' = entered in the portal (overrides), 'erp' = the
      // customer master's USER_3 yearly goal, current year only.
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

const CONTACT_COLUMNS =
  'contact_key, source, name, title, phone, email, is_primary, do_not_call, notes, updated_at'

/** "column … does not exist" — display_name on a database without 20261013100000. */
function isMissingColumn(error: unknown): boolean {
  const e = error as { code?: string; message?: string } | null
  return e?.code === '42703' || /column .* does not exist/i.test(e?.message ?? '')
}

const listContacts: ToolDef = {
  name: 'list_contacts',
  title: 'Account contacts',
  description:
    'People at one account: ERP system-of-record contacts plus anything the ' +
    'reps have captured in the portal (`source` says which). Answers "who do ' +
    'I call". Ranked the way the portal ranks them: the ERP\'s "primary" is ' +
    'often an invoice / accounts-payable mailbox with no phone, so `kind` ' +
    'says what each contact is (buyer, callable, orders line, billing, …) ' +
    'and `best_contact` is the one to ask for.',
  inputSchema: {
    type: 'object',
    properties: { customer_key: CUSTOMER_KEY },
    required: ['customer_key'],
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const key = requireKey(args)

    // display_name (20261013100000) is the printable name; a database
    // without it still answers, ranked on `name`.
    const read = (columns: string) =>
      db.from('v_account_contacts').select(columns).eq('customer_key', key)
    let result: PgResult = await read(`${CONTACT_COLUMNS}, display_name`)
    if (result.error && isMissingColumn(result.error)) result = await read(CONTACT_COLUMNS)

    // The account's own billing addresses: a contact at one of them is
    // accounts payable, not the buyer. Best-effort — ranking still works
    // on names and titles without them.
    const billing = await db
      .schema('erp')
      .from('dim_customer')
      .select('invoice_email, statement_email')
      .eq('customer_key', key)
      .maybeSingle()
    const b = (billing.error ? null : billing.data) as Row | null
    const opts = {
      invoiceEmail: (b?.invoice_email as string | null) ?? null,
      statementEmail: (b?.statement_email as string | null) ?? null,
    }

    // Same ranking as the account page (frontend/src/lib/contacts.ts, copied
    // to _shared/contacts.ts with a parity test).
    const rowsIn = rowsOf(result, 'contacts') as Array<RankableContact & { notes?: string | null }>
    const ranked = rankContacts(rowsIn, opts)
    const best = bestContact(rowsIn, opts)

    return {
      customer_key: key,
      best_contact: best.contact
        ? compact({
            name: best.contact.label,
            title: best.contact.title ?? null,
            phone: best.callable ? best.contact.phone ?? null : null,
            kind: best.reason,
            callable: best.callable,
          })
        : { note: 'No buyer number on file.' },
      contacts: ranked.map((c) =>
        compact({
          name: c.label,
          kind: c.kind,
          callable: c.callable,
          source: c.source,
          title: c.title,
          phone: c.phone,
          email: c.email,
          is_primary: c.is_primary,
          do_not_call: c.do_not_call === true ? true : null,
          notes: c.notes ?? null,
        }),
      ),
      note:
        'Best to call first. "billing" and "internal" (our own staff) are last; ' +
        'a do_not_call number must not be dialled.',
    }
  },
}

/** Rows read for find_dealers_for_sku's family fallback. */
const PROSPECT_ROW_CAP = 5000
const PROSPECT_COLUMNS = 'customer_key, part_key, sales_year, qty, last_invoice_date'

type ProspectRow = { customer_key: string; sales_year: number; qty: number; last_invoice_date: string | null }

/**
 * Sales rows → one entry per dealer, most recent buyer first. The same rule
 * as the In stock page's sheet (frontend/src/composables/useSkuProspects.ts
 * rankProspects): returns are not purchases; latest year and its units.
 */
function rankDealers(rows: ProspectRow[]) {
  const by = new Map<string, {
    customer_key: string; last_year: number; units_last_year: number
    units_4y: number; last_invoice_date: string | null
  }>()
  for (const r of rows) {
    const qty = Number(r.qty ?? 0)
    if (!(qty > 0)) continue
    const year = Number(r.sales_year)
    const d = by.get(r.customer_key) ??
      { customer_key: r.customer_key, last_year: year, units_last_year: 0, units_4y: 0, last_invoice_date: null }
    if (year > d.last_year) {
      d.last_year = year
      d.units_last_year = 0
    }
    if (year === d.last_year) d.units_last_year += qty
    d.units_4y += qty
    if (r.last_invoice_date && (!d.last_invoice_date || r.last_invoice_date > d.last_invoice_date)) {
      d.last_invoice_date = r.last_invoice_date
    }
    by.set(r.customer_key, d)
  }
  return [...by.values()].sort(
    (a, b) =>
      (b.last_invoice_date ?? '').localeCompare(a.last_invoice_date ?? '') ||
      b.units_4y - a.units_4y ||
      a.customer_key.localeCompare(b.customer_key),
  )
}

const findDealersForSku: ToolDef = {
  name: 'find_dealers_for_sku',
  title: 'Who buys this SKU',
  description:
    'The reverse of get_account_sku_gaps: given a product, the dealers in ' +
    'YOUR book who have bought it (current + 3 prior years), most recent ' +
    'buyer first, with the latest year and units. Answers "this just came ' +
    'into stock — who should I call?". When nobody bought that exact SKU it ' +
    'falls back to dealers who bought the same family and chambering, and ' +
    '`match` says so. Pair with check_availability for stock and ' +
    'list_contacts for who to ask for.',
  inputSchema: {
    type: 'object',
    properties: {
      sku: {
        type: 'string',
        description: 'Part ID (e.g. "MESA-65CM-22"), exact or a unique fragment.',
      },
      part_key: { type: 'string', description: 'ERP part key, if you already have it.' },
      limit: limitProp(25, 100),
    },
    additionalProperties: false,
  },
  async handler(args, { db }) {
    const limit = clampInt(args.limit, 25, 1, 100)
    const sku = str(args.sku)
    const partKey = str(args.part_key)
    if (!sku && !partKey) {
      throw new ToolError('Pass `sku` (a part ID) or `part_key`. check_availability lists both.')
    }

    // Resolve the part: exact part_key, else exact part ID, else a fragment
    // that matches exactly one part.
    const parts = db
      .schema('erp')
      .from('dim_part')
      .select('part_key, part_id, part_description, product_family, chambering')
    let candidates: Row[]
    if (partKey) {
      candidates = rowsOf(await parts.eq('part_key', partKey).limit(1), 'the part')
    } else {
      const term = safeLike(sku!)
      candidates = rowsOf(await parts.ilike('part_id', term).limit(5), 'the part')
      if (candidates.length === 0) {
        candidates = rowsOf(
          await db
            .schema('erp')
            .from('dim_part')
            .select('part_key, part_id, part_description, product_family, chambering')
            .ilike('part_id', `*${term}*`)
            .order('part_id')
            .limit(6),
          'the part',
        )
      }
    }
    if (candidates.length === 0) {
      throw new ToolError(`No part matches "${sku ?? partKey}". Try check_availability with a query.`)
    }
    if (candidates.length > 1) {
      throw new ToolError(
        `"${sku}" matches several parts: ${candidates.map((c) => c.part_id).join(', ')}. ` +
          'Pass the exact part ID or its part_key.',
      )
    }
    const part = candidates[0]

    const readSales = (filters: Record<string, string>) =>
      fetchCapped(
        (from, to) => {
          let q = db.from('v_sku_sales_by_account').select(PROSPECT_COLUMNS)
          for (const [column, value] of Object.entries(filters)) q = q.eq(column, value)
          // The view's grain — a unique order for paging.
          return q.order('customer_key').order('part_key').order('sales_year').range(from, to)
        },
        PROSPECT_ROW_CAP,
        'SKU buyers',
      )

    // v_sku_sales_by_account is security_invoker over RLS-scoped
    // erp.agg_sku_year: the caller's book, no customer filter here.
    let match: 'exact' | 'similar' | 'none' = 'exact'
    let { rows, capped } = await readSales({ part_key: String(part.part_key) })
    let dealers = rankDealers(rows as ProspectRow[])

    const spec = (v: unknown) => {
      const t = typeof v === 'string' ? v.trim() : ''
      return t && t.toUpperCase() !== 'N/A' ? t : null
    }
    const family = spec(part.product_family)
    const chambering = spec(part.chambering)
    if (dealers.length === 0 && (family || chambering)) {
      match = 'similar'
      ;({ rows, capped } = await readSales({
        ...(family ? { product_family: family } : {}),
        ...(chambering ? { chambering } : {}),
      }))
      dealers = rankDealers(rows as ProspectRow[])
    }
    if (dealers.length === 0) match = 'none'

    const shown = dealers.slice(0, limit)
    const accounts = shown.length
      ? rowsOf(
          await db
            .from('v_account_list')
            .select('customer_key, customer_name, sold_to_city, sold_to_state, active_flag, deactivated_at')
            .in('customer_key', shown.map((d) => d.customer_key)),
          'account names',
        )
      : []
    const byKey = new Map(accounts.map((a) => [String(a.customer_key), a]))

    return {
      part: compact(part),
      match,
      dealers_matched: dealers.length,
      dealers: shown.map((d) => {
        const a = byKey.get(d.customer_key)
        return compact({
          ...d,
          customer_name: a?.customer_name ?? null,
          city: a?.sold_to_city ?? null,
          state: a?.sold_to_state ?? null,
          inactive: a && (a.active_flag !== 'Y' || a.deactivated_at) ? true : null,
        })
      }),
      ...(capped ? { capped_at: PROSPECT_ROW_CAP } : {}),
      note:
        match === 'similar'
          ? `Nobody in your book bought this exact SKU; these bought other ${[family, chambering].filter(Boolean).join(' ')}.`
          : match === 'none'
            ? 'Nobody in your book has bought this SKU or its family in the last four years.'
            : 'Units are invoiced units. Use list_contacts(customer_key) for who to ask for.',
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
  getAccountRevenueTrend,
  getAccountSkuGaps,
  getTerritorySummary,
  listTerritoryAccounts,
  getSkuSales,
  getSalesSummary,
  listBacklog,
  checkAvailability,
  listOrders,
  listShipments,
  lookupOrder,
  getGoalProgress,
  listRecommendations,
  listAccountActivity,
  listContacts,
  findDealersForSku,
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
