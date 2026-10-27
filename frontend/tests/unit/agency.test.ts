/**
 * Unit tests for the Agency page's pure derivations (useAgency.ts).
 *
 * Run with:  npm run test:unit -- agency
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. The behaviours that must never regress:
 *   - totals are sums of the (rep, channel) rows, exactly — never averages;
 *   - every rep with accounts gets a row, joined to the login on their code;
 *   - a portal user with no book of their own (the principal, a new rep)
 *     still gets a row, so "who signs in" never drops anyone;
 *   - the month series sums reps, or isolates one, including the no-rep bucket.
 */
import {
  activeWithin,
  agencyTotals,
  buildRepLines,
  goalProgress,
  monthlySeriesRows,
  NO_REP_LABEL,
  portalState,
  rollUpAgencyChannels,
  type AgencyActivityRow,
  type AgencyMonthRow,
  type AgencyRepChannelRow,
} from '../../src/composables/useAgency'

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

function perf(
  sales_rep_key: string | null,
  channel: string,
  over: Partial<AgencyRepChannelRow> = {},
): AgencyRepChannelRow {
  return {
    sales_rep_key,
    sales_rep_name: sales_rep_key ? `Name ${sales_rep_key}` : null,
    vendor_id: 'ACME',
    channel,
    accounts: 1,
    buying_accounts: 1,
    lapsed_accounts: 0,
    new_accounts: 0,
    accounts_with_goal: 0,
    contacted_30d: 0,
    revenue_ytd: 100,
    revenue_prior_ytd: 80,
    revenue_trailing_12m: 120,
    revenue_prior_full: 150,
    bookings_ytd: 90,
    bookings_prior_ytd: 70,
    open_order_value: 10,
    backlog_amount: 5,
    goal_total: 0,
    last_invoice_date: '2026-10-01',
    goal_revenue_ytd: 0,
    goal_expected: 0,
    workable_accounts: 1,
    ...over,
  }
}

function login(
  user_id: string,
  sales_rep_key: string | null,
  over: Partial<AgencyActivityRow> = {},
): AgencyActivityRow {
  return {
    user_id,
    full_name: `User ${user_id}`,
    sales_rep_key,
    vendor_id: 'ACME',
    is_principal: false,
    active: true,
    last_login_at: '2026-10-25T15:00:00Z',
    logins_7d: 2,
    logins_30d: 6,
    active_days_30d: 5,
    actions_30d: 3,
    visits_30d: 1,
    last_action_date: '2026-10-24',
    ...over,
  }
}

const rows: AgencyRepChannelRow[] = [
  perf('A', 'Dealer', { revenue_ytd: 500, goal_total: 1000, accounts_with_goal: 1 }),
  perf('A', 'Buy Group', { revenue_ytd: 300, last_invoice_date: '2026-10-20' }),
  perf('B', 'Dealer', { revenue_ytd: 50, revenue_prior_ytd: 400, lapsed_accounts: 1 }),
  perf(null, 'Dealer', { revenue_ytd: 20 }),
]

/* --- totals ------------------------------------------------------------- */
const total = agencyTotals(rows)
t('totals: revenue is the sum of every row', total.revenue_ytd, 870)
t('totals: accounts summed', total.accounts, 4)
t('totals: prior year summed', total.revenue_prior_ytd, 80 + 80 + 400 + 80)
t('totals: newest last invoice wins', total.last_invoice_date, '2026-10-20')
t('totals: empty is zeros, not NaN', agencyTotals([]).revenue_ytd, 0)

/* --- the reps table ----------------------------------------------------- */
const activity: AgencyActivityRow[] = [
  login('u-a', 'A'),
  // The principal: no rep code of their own — no book, still a row.
  login('u-p', null, { is_principal: true, full_name: 'Pat Principal' }),
  // A rep whose code has no active accounts yet.
  login('u-new', 'NEW', { full_name: 'New Rep', last_login_at: null }),
]
const lines = buildRepLines(rows, activity)

t(
  'reps: one line per rep code, biggest first, then logins with no book (by name)',
  lines.map((l) => l.id),
  ['rep:A', 'rep:B', 'rep:(none)', 'user:u-new', 'user:u-p'],
)
const a = lines.find((l) => l.id === 'rep:A')!
t('rep A: channels summed into one line', a.revenue_ytd, 800)
t('rep A: goal carried', a.goal_total, 1000)
t('rep A: joined to the login on their code', a.portal?.user_id, 'u-a')
t('rep A: named from the ERP', a.name, 'Name A')

const b = lines.find((l) => l.id === 'rep:B')!
t('rep B: no login → portal null', b.portal, null)
t('rep B: lapsed carried', b.lapsed_accounts, 1)

t('no-rep bucket is labelled', lines.find((l) => l.id === 'rep:(none)')?.name, NO_REP_LABEL)

const p = lines.find((l) => l.id === 'user:u-p')!
t('principal: a row of their own', [p.name, p.is_principal, p.revenue_ytd], ['Pat Principal', true, 0])

t(
  'two logins on one rep code: the one active more recently is shown',
  buildRepLines(
    [perf('A', 'Dealer')],
    [
      login('old', 'A', { last_login_at: '2026-01-01T00:00:00Z' }),
      login('live', 'A', { last_login_at: '2026-10-25T00:00:00Z' }),
    ],
  ).map((l) => [l.id, l.portal?.user_id]),
  [['rep:A', 'live']],
)

t(
  '…and a deactivated login never beats an active one',
  buildRepLines(
    [perf('A', 'Dealer')],
    [
      login('live', 'A', { last_login_at: '2026-01-01T00:00:00Z' }),
      login('gone', 'A', { active: false, last_login_at: '2026-10-25T00:00:00Z' }),
    ],
  ).map((l) => l.portal?.user_id),
  ['live'],
)

t(
  'a code with no accounts and two logins (an old deactivated, a new live one) is one row',
  buildRepLines(
    [],
    [
      login('gone', 'Z', { active: false, last_login_at: '2026-10-25T00:00:00Z' }),
      login('live', 'Z', { last_login_at: '2026-01-01T00:00:00Z' }),
    ],
  ).map((l) => [l.id, l.portal?.user_id]),
  [['user:live', 'live']],
)

t('no rows, no logins → no lines', buildRepLines([], []), [])

/* --- goal pace ---------------------------------------------------------- */
// Revenue on goal accounts only; pace from what should be in by today.
const g = goalProgress({ goal_total: 100_000, goal_revenue_ytd: 40_000, goal_expected: 50_000 })
t('goal: attainment from goal-account revenue', g?.attainmentPct, 40)
t('goal: seasonal expected', g?.expectedPct, 50)
t('goal: behind pace', g?.onTrack, false)
t(
  'goal: ahead of pace',
  goalProgress({ goal_total: 100_000, goal_revenue_ytd: 45_000, goal_expected: 30_000 })?.onTrack,
  true,
)
t('goal: none set → null, not 0%', goalProgress({ goal_total: 0, goal_revenue_ytd: 9, goal_expected: 0 }), null)
t(
  'goal: totals carry the goal measures through the sums',
  goalProgress(agencyTotals(rows.map((r, i) => ({ ...r, goal_total: 100, goal_revenue_ytd: 10 * (i + 1), goal_expected: 25 })))),
  { attainmentPct: 25, expectedPct: 25, onTrack: true },
)

/* --- portal state ------------------------------------------------------- */
t('portal: activity not loaded → unknown, never "no login"', portalState({ portal: null }, false), 'unknown')
t('portal: no login', portalState({ portal: null }, true), 'none')
t('portal: deactivated', portalState({ portal: login('x', 'A', { active: false }) }, true), 'deactivated')
t('portal: never signed in', portalState({ portal: login('x', 'A', { last_login_at: null }) }, true), 'never')
t('portal: active', portalState({ portal: login('x', 'A') }, true), 'active')

/* --- channels ----------------------------------------------------------- */
t(
  'channels: whole agency, biggest first',
  rollUpAgencyChannels(rows).map((c) => [c.channel, c.revenue_ytd]),
  [
    ['Dealer', 570],
    ['Buy Group', 300],
  ],
)
t(
  'channels: one rep',
  rollUpAgencyChannels(rows, 'B').map((c) => [c.channel, c.revenue_ytd]),
  [['Dealer', 50]],
)
t(
  'channels: the no-rep bucket is its own filter (null), not "everyone"',
  rollUpAgencyChannels(rows, null).map((c) => [c.channel, c.revenue_ytd]),
  [['Dealer', 20]],
)

/* --- monthly series ----------------------------------------------------- */
const months: AgencyMonthRow[] = [
  { sales_month: '2026-02-01', sales_rep_key: 'A', revenue: 10, qty: 1, invoice_count: 1, account_count: 1 },
  { sales_month: '2026-01-01', sales_rep_key: 'A', revenue: 5, qty: 1, invoice_count: 1, account_count: 1 },
  { sales_month: '2026-01-01', sales_rep_key: 'B', revenue: 7, qty: 1, invoice_count: 1, account_count: 1 },
  { sales_month: '2026-01-01', sales_rep_key: null, revenue: 1, qty: 1, invoice_count: 1, account_count: 1 },
]
t(
  'months: agency = reps summed, in month order',
  monthlySeriesRows(months),
  [
    { month: '2026-01-01', revenue: 13 },
    { month: '2026-02-01', revenue: 10 },
  ],
)
t('months: one rep', monthlySeriesRows(months, 'B'), [{ month: '2026-01-01', revenue: 7 }])
t('months: the no-rep bucket', monthlySeriesRows(months, null), [{ month: '2026-01-01', revenue: 1 }])

/* --- activity window ---------------------------------------------------- */
const now = new Date('2026-10-26T12:00:00Z')
t('active within 7 days', activeWithin({ last_login_at: '2026-10-22T12:00:00Z' }, 7, now), true)
t('not within 7 days', activeWithin({ last_login_at: '2026-10-18T12:00:00Z' }, 7, now), false)
t('never signed in is never active', activeWithin({ last_login_at: null }, 7, now), false)
t('no login row at all', activeWithin(null, 7, now), false)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
