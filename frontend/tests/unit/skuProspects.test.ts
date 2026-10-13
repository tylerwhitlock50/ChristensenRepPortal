/**
 * Unit tests for rankProspects() in composables/useSkuProspects.ts — the
 * order of the ATS page's "Who should I call?" list.
 *
 * Run with:  npm run test:unit -- skuProspects
 *
 * Same harness as ffl.test.ts.
 */
import { rankProspects } from '../../src/composables/useSkuProspects'

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

const rows = [
  { customer_key: 'A', sales_year: 2024, qty: 10, last_invoice_date: '2024-11-02' },
  { customer_key: 'A', sales_year: 2026, qty: 2, last_invoice_date: '2026-03-15' },
  { customer_key: 'A', sales_year: 2026, qty: 1, last_invoice_date: '2026-01-04' },
  { customer_key: 'B', sales_year: 2026, qty: 6, last_invoice_date: '2026-09-20' },
  { customer_key: 'C', sales_year: 2025, qty: 4, last_invoice_date: '2025-06-01' },
  // A net return is not a purchase.
  { customer_key: 'D', sales_year: 2026, qty: -1, last_invoice_date: '2026-10-01' },
  // Same last date as C, more units: ranks first of the two.
  { customer_key: 'E', sales_year: 2025, qty: 9, last_invoice_date: '2025-06-01' },
]

const ranked = rankProspects(rows)

t('most recent buyer first; returns are not buyers',
  ranked.map((r) => r.customer_key), ['B', 'A', 'E', 'C'])
t('latest year and its units, plus the four-year total',
  ranked.find((r) => r.customer_key === 'A'),
  { customer_key: 'A', lastYear: 2026, unitsLastYear: 3, totalUnits: 13, lastInvoiceDate: '2026-03-15' })
t('rows in any order give the same answer',
  rankProspects([...rows].reverse()).map((r) => r.customer_key), ['B', 'A', 'E', 'C'])
t('nothing bought → nobody', rankProspects([]), [])

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
