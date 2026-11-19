/**
 * Unit tests for "Sales by family": the roll-up behind the account page's
 * card, the mix bars' segments and colour slots, and the rows of the
 * Accounts table's by-family / by-SKU download.
 *
 * Run with:  npm run test:unit -- familySales
 *
 * What these pin: a family's line is the sum of the SKUs under it; shares
 * are of positive revenue and add up to 1; a family keeps its colour slot
 * and its place in both years' bars; and a detail download carries exactly
 * the accounts it was given, in their order.
 */
import { createSSRApp, h } from 'vue'
import { renderToString } from 'vue/server-renderer'
import {
  MIX_OTHER_SLOT,
  NO_PRODUCT_LINE,
  accountFamilyDetail,
  accountSkuDetail,
  mixBar,
  mixSlots,
  pivotSkuYears,
  rollupFamilySales,
  salesGroupOf,
  type SkuYearRow,
} from '../../src/composables/useIntel'
import { MIX_COLORS, MIX_OTHER_COLOR, mixColor } from '../../src/lib/mixColors'
import FamilyMixBars from '../../src/components/FamilyMixBars.vue'

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

const YEAR = 2026

/** A part's catalog facts: [family, product line, chambering]. */
const PARTS: Record<string, [string | null, string | null, string | null]> = {
  'R-1': ['RIDGELINE FLASH FORGED TECHNOLOGY', 'RIDGELINE FFT', '6.5 PRC'],
  'R-2': ['Ridgeline Flash Forged Technology', 'RIDGELINE FFT', '7mm PRC'],
  'E-1': ['EVOKE', 'EVOKE', '.308 Win'],
  'M-1': ['MPR', 'MPR', '6.5 Creedmoor'],
  'T-1': ['TRAVERSE', 'TRAVERSE', '.300 Win Mag'],
  'S-1': ['SUMMIT', 'SUMMIT', '.300 PRC'],
  'C-1': ['MCR', 'MCR', '6.5 PRC'],
  'B-1': ['RIDGELINE', 'FG-BARACT', '6.5 PRC'],
  'K-1': [null, 'FG-COMP', null],
  'K-2': ['N/A', 'COMPONENT', 'N/A'],
  'X-1': [null, null, null],
}

function sale(
  customer: string,
  part: string,
  year: number,
  revenue: number,
  qty = 1,
  lastInvoice: string | null = `${year}-06-15`,
): SkuYearRow {
  const [product_family, product_code, chambering] = PARTS[part]!
  return {
    customer_key: customer,
    part_key: part,
    part_id: part,
    part_description: `${part} description`,
    product_family,
    product_code,
    chambering,
    upc: null,
    sales_year: year,
    revenue,
    qty,
    invoice_count: 1,
    last_invoice_date: lastInvoice,
  }
}

/* ---- which group a SKU belongs to --------------------------------------- */
const part = (id: string) => {
  const [product_family, product_code, chambering] = PARTS[id]!
  return { product_family, product_code, chambering }
}
t('family: a gun sits under its family, uppercased', salesGroupOf(part('R-2'), 'family'), 'RIDGELINE FLASH FORGED TECHNOLOGY')
t('family: a barreled action is its own row, whatever its family', salesGroupOf(part('B-1'), 'family'), 'Barreled actions')
t('family: a part with no spec is a component', salesGroupOf(part('K-1'), 'family'), 'Components & accessories')
t('family: N/A is no spec either', salesGroupOf(part('K-2'), 'family'), 'Components & accessories')
t('line: the product code', salesGroupOf(part('R-1'), 'line'), 'RIDGELINE FFT')
t('line: components keep their own codes', [salesGroupOf(part('K-1'), 'line'), salesGroupOf(part('K-2'), 'line')], ['FG-COMP', 'COMPONENT'])
t('line: no code has a named row', salesGroupOf(part('X-1'), 'line'), NO_PRODUCT_LINE)

/* ---- the roll-up --------------------------------------------------------- */
const ONE = [
  sale('A', 'R-1', 2026, 600, 3, '2026-10-02'),
  sale('A', 'R-2', 2026, 200, 1, '2026-03-01'),
  sale('A', 'R-1', 2025, 500, 2),
  sale('A', 'E-1', 2026, 200, 2),
  sale('A', 'E-1', 2025, 1500, 9),
  sale('A', 'K-1', 2026, -50, -1), // a credit: nets negative
  sale('A', 'M-1', 2023, 900, 4), // last bought three years ago
]
const families = rollupFamilySales(pivotSkuYears(ONE, YEAR), 'family')

t('biggest this year first', families.map((f) => f.key), [
  'RIDGELINE FLASH FORGED TECHNOLOGY',
  'EVOKE',
  'Components & accessories',
])
t('a family last bought three years ago is not in the mix', families.some((f) => f.key === 'MPR'), false)

const ridgeline = families[0]!
t('a family is the sum of its SKUs: revenue', [ridgeline.revenueThisYear, ridgeline.revenueLastYear], [800, 500])
t('…units', [ridgeline.qtyThisYear, ridgeline.qtyLastYear], [4, 2])
t('…and it lists them, top seller first', ridgeline.skus.map((s) => s.part_key), ['R-1', 'R-2'])
t('SKU count', ridgeline.skuCount, 2)
t('last invoice is its newest SKU invoice', ridgeline.lastInvoiceDate, '2026-10-02')
t(
  'drilling in never disagrees: SKU revenue adds up to the family line',
  families.map((f) => f.skus.reduce((sum, s) => sum + s.revenueThisYear, 0) === f.revenueThisYear),
  [true, true, true],
)

t('share is of positive revenue (800 of 1,000)', ridgeline.shareThisYear, 0.8)
t('a family that nets a credit has a 0 share, not a negative one', families[2]!.shareThisYear, 0)
t(
  'shares add up to 1',
  Math.round(families.reduce((sum, f) => sum + (f.shareThisYear ?? 0), 0) * 1e9) / 1e9,
  1,
)
t('last year has its own shares (500 of 2,000)', ridgeline.shareLastYear, 0.25)

const lastYearOnly = rollupFamilySales(pivotSkuYears([sale('A', 'E-1', 2025, 400)], YEAR), 'family')
t('nothing sold this year: no share to state', lastYearOnly[0]!.shareThisYear, null)
t('…but last year is whole', lastYearOnly[0]!.shareLastYear, 1)
t('no rows, no families', rollupFamilySales([], 'family'), [])

const byLine = rollupFamilySales(pivotSkuYears(ONE, YEAR), 'line')
t('by product line: same dollars, the ERP code as the name', byLine.map((f) => [f.key, f.revenueThisYear]), [
  ['RIDGELINE FFT', 800],
  ['EVOKE', 200],
  ['FG-COMP', -50],
])

/* ---- colour slots -------------------------------------------------------- */
const SEVEN = [
  sale('A', 'R-1', 2026, 700),
  sale('A', 'E-1', 2026, 600),
  sale('A', 'M-1', 2026, 500),
  sale('A', 'T-1', 2026, 400),
  sale('A', 'S-1', 2026, 300),
  sale('A', 'C-1', 2026, 200),
  sale('A', 'B-1', 2026, 100),
  sale('A', 'K-1', 2026, -20), // never sold net: no slot
  sale('A', 'C-1', 2025, 900),
  sale('A', 'R-1', 2025, 100),
]
const seven = rollupFamilySales(pivotSkuYears(SEVEN, YEAR), 'family')
const slots = mixSlots(seven)
t('the five biggest get slots 0–4, in order', seven.slice(0, 5).map((f) => slots.get(f.key)), [0, 1, 2, 3, 4])
t('the rest are Other', seven.slice(5).map((f) => slots.get(f.key)), [MIX_OTHER_SLOT, MIX_OTHER_SLOT, MIX_OTHER_SLOT])

const credits = rollupFamilySales(
  pivotSkuYears([sale('A', 'K-1', 2026, -20), sale('A', 'E-1', 2025, 50)], YEAR),
  'family',
)
t('a family that never netted a sale does not take a colour', mixSlots(credits).get('Components & accessories'), MIX_OTHER_SLOT)
t('…the one that sold does, even from second place', mixSlots(credits).get('EVOKE'), 0)

t('five colours, and they are all different', new Set(MIX_COLORS).size, 5)
t('Other, and anything past the fifth, is the gray', [mixColor(MIX_OTHER_SLOT), mixColor(5)], [MIX_OTHER_COLOR, MIX_OTHER_COLOR])

/* ---- the bars ------------------------------------------------------------ */
const thisYear = mixBar(seven, slots, 'this')
t('this year: five families then Other', thisYear.segments.map((s) => s.label), [
  'RIDGELINE FLASH FORGED TECHNOLOGY',
  'EVOKE',
  'MPR',
  'TRAVERSE',
  'SUMMIT',
  'Other',
])
t('Other folds the two that sold; the credit draws nothing', thisYear.segments.at(-1)!.families, 2)
t('Other has no single family to open', thisYear.segments.at(-1)!.key, '')
t('the total is net revenue, credit included', thisYear.total, 2780)
t(
  'segments fill the bar',
  Math.round(thisYear.segments.reduce((sum, s) => sum + s.share, 0) * 1e9) / 1e9,
  1,
)

const lastYear = mixBar(seven, slots, 'last')
t(
  'last year keeps this year\'s slot order, not its own ranking',
  lastYear.segments.map((s) => [s.label, s.slot]),
  [
    ['RIDGELINE FLASH FORGED TECHNOLOGY', 0],
    ['MCR', MIX_OTHER_SLOT],
  ],
)
t('Other standing for one family is named for it', [lastYear.segments[1]!.key, lastYear.segments[1]!.families], ['MCR', 1])
t('a year with nothing sold has no segments', mixBar(lastYearOnly, mixSlots(lastYearOnly), 'this').segments, [])

/* ---- the bars on screen -------------------------------------------------- */
const html = await renderToString(
  createSSRApp({
    render: () =>
      h(FamilyMixBars as never, {
        bars: [
          { label: '2026 to date', bar: thisYear },
          { label: 'All of 2025', bar: mixBar(lastYearOnly, mixSlots(lastYearOnly), 'this') },
        ],
      }),
  }),
)
t('one button per segment', (html.match(/<button/g) ?? []).length, 6)
t('a segment says its family, dollars and share', html.includes('aria-label="EVOKE: $600, 21.4%"'), true)
t('Other says how many families it stands for', html.includes('aria-label="Other (2 families): $300, 10.7%"'), true)
t('the bar\'s own name carries the year and its total', html.includes('aria-label="2026 to date: $2,780. '), true)
t('an empty year says so instead of drawing nothing', html.includes('Nothing invoiced'), true)

/* ---- the Accounts table's detail download -------------------------------- */
const account = (key: string, name: string, rep: string) => ({
  customer_key: key,
  customer_name: name,
  sold_to_city: 'Gunnison',
  sold_to_state: 'UT',
  assigned_sales_rep_name: rep,
  // The table's rows carry more than the identity; none of it may leak into a detail row.
  revenue_ytd: 999,
})
const BOOK = [
  ...ONE, // account A
  sale('B', 'E-1', 2026, 300, 2),
  sale('B', 'E-1', 2025, 100, 1),
  sale('B', 'T-1', 2025, 50, 1),
  sale('Z', 'M-1', 2026, 5000, 3), // in the book, not on screen
]
const onScreen = [account('B', 'Bravo Guns', 'Kim'), account('A', 'Alpha Arms', 'Lee'), account('N', 'No Sales Co', 'Lee')]

function byFamilyTotals(rows: { family: string; revenueThisYear: number }[]) {
  const out: Record<string, number> = {}
  for (const r of rows) out[r.family] = (out[r.family] ?? 0) + r.revenueThisYear
  return out
}

const bySku = accountSkuDetail(onScreen, BOOK, YEAR)
// R-2 ($200) sits with R-1 under Ridgeline, ahead of Evoke's E-1 (also $200,
// and bigger last year): a family's SKUs stay together.
t('by SKU: the accounts given, in their order, family by family', bySku.map((r) => `${r.customer_key}/${r.part_key}`), [
  'B/E-1',
  'B/T-1',
  'A/R-1',
  'A/R-2',
  'A/E-1',
  'A/K-1',
])
t('…each row named for the family it is filed under', bySku.map((r) => r.family), [
  'EVOKE',
  'TRAVERSE',
  'RIDGELINE FLASH FORGED TECHNOLOGY',
  'RIDGELINE FLASH FORGED TECHNOLOGY',
  'EVOKE',
  'Components & accessories',
])
t('an account off screen contributes nothing', bySku.some((r) => r.customer_key === 'Z'), false)
t('an account with no sales has no rows', bySku.some((r) => r.customer_key === 'N'), false)
t('a SKU last bought three years ago is left out', bySku.some((r) => r.part_key === 'M-1'), false)
t('each row carries its account and rep', [bySku[0]!.customer_name, bySku[0]!.assigned_sales_rep_name, bySku[0]!.sold_to_state], ['Bravo Guns', 'Kim', 'UT'])
t('…both years of the SKU', [bySku[0]!.revenueThisYear, bySku[0]!.revenueLastYear, bySku[0]!.qtyThisYear], [300, 100, 2])
t('…its family and product line, to pivot on', [bySku[2]!.family, bySku[2]!.product_code], ['RIDGELINE FLASH FORGED TECHNOLOGY', 'RIDGELINE FFT'])
t(
  'summing the SKU file by family gives the family file',
  byFamilyTotals(bySku.filter((r) => r.customer_key === 'A')),
  { 'RIDGELINE FLASH FORGED TECHNOLOGY': 800, EVOKE: 200, 'Components & accessories': -50 },
)
t('…and nothing else from the table row', 'revenue_ytd' in bySku[0]!, false)

const byFamily = accountFamilyDetail(onScreen, BOOK, 'family', YEAR)
t('by family: one row per account and family', byFamily.map((r) => `${r.customer_key}/${r.key}`), [
  'B/EVOKE',
  'B/TRAVERSE',
  'A/RIDGELINE FLASH FORGED TECHNOLOGY',
  'A/EVOKE',
  'A/Components & accessories',
])
t('the SKU list stays out of the file', 'skus' in byFamily[0]!, false)
t('shares are of the account, not the book', [byFamily[0]!.shareThisYear, byFamily[2]!.shareThisYear], [1, 0.8])
t(
  'by family and by SKU agree, account by account',
  ['A', 'B'].map((k) => {
    const sum = (rows: { customer_key: string; revenueThisYear: number }[]) =>
      rows.filter((r) => r.customer_key === k).reduce((s, r) => s + r.revenueThisYear, 0)
    return sum(bySku) === sum(byFamily)
  }),
  [true, true],
)
t('by product line: the ERP codes', accountFamilyDetail(onScreen, BOOK, 'line', YEAR).filter((r) => r.customer_key === 'A').map((r) => r.key), [
  'RIDGELINE FFT',
  'EVOKE',
  'FG-COMP',
])
t('no accounts, no rows', accountSkuDetail([], BOOK, YEAR), [])

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
