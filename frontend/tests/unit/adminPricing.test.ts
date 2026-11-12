/**
 * Unit tests for lib/adminPricing.ts — flags and submit rules for
 * admin-priced and unmatched order lines (20261111170000).
 *
 * Run with:  npm run test:unit -- adminPricing
 */
import {
  blocksWriterEdit,
  lineFlags,
  needsPricingReview,
  parsePriceInput,
  pricingSubmitBlock,
  pricingSummary,
  type PricedLine,
} from '../../src/lib/adminPricing'

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

const base = (over: Partial<PricedLine>): PricedLine => ({
  id: 1,
  part_id: '801-15025-01',
  description: 'EVOKE HUNTER',
  qty: 2,
  unit_price: 2000,
  price_source: 'list',
  list_unit_price: 2000,
  ...over,
})

const list = base({})
const lower = base({ id: 2, price_source: 'admin', unit_price: 1700, list_unit_price: 2000 })
const offList = base({ id: 3, price_source: 'admin', unit_price: 798.7, list_unit_price: null, last_paid_price: 798.7 })
const unmatched = base({ id: 4, part_id: '801151300', price_source: 'admin', unit_price: 1050, list_unit_price: null, part_unresolved: true })
const typo = base({ id: 5, price_source: 'admin', unit_price: 1700, list_unit_price: null, description_mismatch: true, last_paid_price: 1650 })

// ------------------------------------------------------------- flags
t('a list line has no flags', lineFlags(list), [])
t('a lower price', lineFlags(lower), ['not_list_price'])
t('off list, at the last paid price', lineFlags(offList), ['off_list'])
t('unmatched is not also off_list', lineFlags(unmatched), ['unmatched'])
t('description and last paid', lineFlags(typo), ['off_list', 'check_description', 'vs_last_paid'])
t('a list line with a description mismatch is flagged too',
  lineFlags(base({ description_mismatch: true })), ['check_description'])
t('columns missing (old rows) → no flags', lineFlags({ id: 9, part_id: 'X', description: null, qty: 1, unit_price: 5 }), [])

// ------------------------------------------------------------- summary
t('summary', pricingSummary([list, lower, offList, unmatched]), {
  lines: 4,
  adminLines: 3,
  offList: 1,
  notListPrice: 1,
  unmatched: 1,
  descriptionChecks: 0,
  adminValue: 2 * 1700 + 2 * 798.7 + 2 * 1050,
  belowList: 600,
})
t('review needed', needsPricingReview([list, lower]), true)
t('no review for list lines', needsPricingReview([list]), false)
t('writer blocked by an admin line', blocksWriterEdit([list, lower]), true)
t('writer fine with list lines (even a description check)', blocksWriterEdit([list, base({ description_mismatch: true })]), false)

// ------------------------------------------------------------- submit
t('unmatched blocks everyone', pricingSubmitBlock([lower, unmatched], true).startsWith('1 line match no part'), true)
t('admin lines block a rep', pricingSubmitBlock([lower], false), 'This order has admin-priced lines, so only an admin can submit it.')
t('admin lines fine for an admin', pricingSubmitBlock([lower], true), '')
t('list lines fine for a rep', pricingSubmitBlock([list], false), '')

// ------------------------------------------------------------- price input
t('plain', parsePriceInput('1700'), 1700)
t('cents', parsePriceInput('798.70'), 798.7)
t('dollar sign and commas', parsePriceInput(' $1,655.99 '), 1655.99)
t('three decimals refused', parsePriceInput('10.005'), null)
t('negative refused', parsePriceInput('-5'), null)
t('words refused', parsePriceInput('abc'), null)
t('empty refused', parsePriceInput(''), null)
t('over a million refused', parsePriceInput('1000000.01'), null)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exit(1)
