/**
 * Unit tests for buildCalendarYearSeries() — the Jan–Dec chart alignment.
 *
 * Run with:  npm run test:unit
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. The behaviours that must never regress:
 *   - future months are null, NOT 0 (a zero bar reads as a collapse);
 *   - the delta compares YTD against the SAME months last year, not the
 *     full prior year (which would flatter or damn every mid-year read).
 */
import { buildCalendarYearSeries } from '../../src/composables/useAccountMetrics'

type Row = {
  customer_key: string
  month: string
  revenue: number
  invoice_count: number
}

function row(month: string, revenue: number): Row {
  return { customer_key: 'C1', month, revenue, invoice_count: 1 }
}

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(
      `FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`,
    )
  }
}

/* --- mid-year (September 2026) ------------------------------------------ */
const sep = new Date(2026, 8, 15) // Sep 15 2026
const midYear = buildCalendarYearSeries(
  [
    row('2025-01-01', 100),
    row('2025-06-01', 200),
    row('2025-12-01', 300),
    row('2026-02-01', 400),
    row('2026-09-01', 50),
  ],
  sep,
)

t('years', [midYear.currentYear, midYear.priorYear], [2026, 2025])
t('labels are Jan–Dec', midYear.labels[0] + '…' + midYear.labels[11], 'Jan…Dec')
t(
  'current: silent past months 0, future months null',
  midYear.current,
  [0, 400, 0, 0, 0, 0, 0, 0, 50, null, null, null],
)
t(
  'prior: all 12 months, silent = 0',
  midYear.prior,
  [100, 0, 0, 0, 0, 200, 0, 0, 0, 0, 0, 300],
)
t('currentTotal is YTD incl. partial month', midYear.currentTotal, 450)
t('currentCompleted excludes the partial September', midYear.currentCompleted, 400)
t('priorCompleted stops at August too', midYear.priorCompleted, 300)
t('completed-through label', midYear.completedThroughLabel, 'Aug')
t('priorTotalFull is the whole year', midYear.priorTotalFull, 600)
t(
  'delta compares complete months only',
  midYear.deltaPct,
  ((400 - 300) / 300) * 100,
)
t('hasData', midYear.hasData, true)

/* --- January edge: only one current month exists ------------------------ */
const jan = buildCalendarYearSeries(
  [row('2025-01-01', 120), row('2025-07-01', 80), row('2026-01-01', 60)],
  new Date(2026, 0, 10),
)
t('January: 11 future nulls', jan.current.filter((v) => v === null).length, 11)
t('January current[0]', jan.current[0], 60)
t('January: no complete months → delta null', jan.deltaPct, null)
t('January: no completed-through label', jan.completedThroughLabel, null)
t('January priorTotalFull', jan.priorTotalFull, 200)

/* --- silence ------------------------------------------------------------- */
const silent = buildCalendarYearSeries([], sep)
t('no rows → hasData false', silent.hasData, false)
t('no rows → delta null', silent.deltaPct, null)

/* --- zero prior year ------------------------------------------------------ */
const newAccount = buildCalendarYearSeries([row('2026-03-01', 500)], sep)
t('new account → delta null (no prior base)', newAccount.deltaPct, null)
t('new account still has data', newAccount.hasData, true)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
