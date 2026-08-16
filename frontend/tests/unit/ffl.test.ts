/**
 * Unit tests for lib/ffl.ts — the FFL expiry parser.
 *
 * Run with:  npm run test:unit
 *
 * No test framework: the repo has none, and adding vitest to assert thirty
 * pure-function cases would be a bigger change than the thing under test.
 * This runs under vite-node (already transitively available through vite) and
 * exits non-zero on failure, which is all CI needs. Playwright is configured
 * to ignore this directory.
 *
 * Why these tests exist at all: ffl_expiration_raw comes from CUSTOMER.USER_5,
 * a free-form user-defined ERP field nobody has ever validated. The parser's
 * most important behaviour is REFUSING — a licence number, a phone number or
 * a bare "12/31" must not become a confident expiry date on a compliance
 * badge. Most of what is asserted below is that it declines to guess.
 */
import {
  fflSentence,
  fflStatus,
  isCreditBlocked,
  parseFflExpiry,
} from '../../src/lib/ffl'

const today = new Date('2026-08-16T12:00:00Z')
const iso = (d: Date | null) => (d ? d.toISOString().slice(0, 10) : null)

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

/* --- formats a free-form field really contains -------------------------- */
t('US slash, 4-digit year', iso(parseFflExpiry('12/31/2026', today)), '2026-12-31')
t('US slash, 2-digit year', iso(parseFflExpiry('12/31/26', today)), '2026-12-31')
t('single-digit month/day', iso(parseFflExpiry('1/5/2027', today)), '2027-01-05')
t('ISO', iso(parseFflExpiry('2027-03-01', today)), '2027-03-01')
t('dash separated', iso(parseFflExpiry('12-31-2026', today)), '2026-12-31')
t('EXP prefix', iso(parseFflExpiry('EXP 12/31/2026', today)), '2026-12-31')
t('Expires: prefix', iso(parseFflExpiry('Expires: 12/31/2026', today)), '2026-12-31')
t('month name', iso(parseFflExpiry('Dec 31, 2026', today)), '2026-12-31')
t('trailing punctuation', iso(parseFflExpiry('12/31/2026.', today)), '2026-12-31')

/* --- refuses rather than guesses (the point of the file) ---------------- */
t('empty string', parseFflExpiry('', today), null)
t('null', parseFflExpiry(null, today), null)
t('free text', parseFflExpiry('on file', today), null)
t('no year — must NOT assume one', parseFflExpiry('12/31', today), null)
t('an FFL number, not a date', parseFflExpiry('1-57-XXX-01-2A-12345', today), null)
t('implausibly far future', parseFflExpiry('12/31/2199', today), null)
t('a phone number', parseFflExpiry('801-555-0100', today), null)

/* --- status transitions ------------------------------------------------- */
t('expired', fflStatus('1-57', '12/31/2025', today).state, 'expired')
t('expiring within 60 days', fflStatus('1-57', '09/30/2026', today).state, 'expiring')
t('valid', fflStatus('1-57', '12/31/2027', today).state, 'valid')
t('unparseable => unknown', fflStatus('1-57', 'on file', today).state, 'unknown')
t('nothing on file => missing', fflStatus(null, null, today).state, 'missing')

/* --- the strip stays silent unless something needs attention ------------ */
t('a valid licence says nothing', fflSentence(fflStatus('1-57', '12/31/2027', today)), null)
t('no licence on file says nothing', fflSentence(fflStatus(null, null, today)), null)
t(
  'unknown shows the raw string, claims no date',
  fflSentence(fflStatus('1-57', 'on file', today)),
  'FFL expiry on file: “on file”',
)
t(
  'expiring counts the days',
  fflSentence(fflStatus('1-57', '09/30/2026', today)),
  'FFL expires in 45 days',
)

/* --- credit ------------------------------------------------------------- */
t('HOLD is blocking', isCreditBlocked('HOLD'), true)
t('Credit Hold is blocking', isCreditBlocked('Credit Hold'), true)
t('suspended is blocking', isCreditBlocked('suspended'), true)
t('Approved is not', isCreditBlocked('Approved'), false)
t('null is not', isCreditBlocked(null), false)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
