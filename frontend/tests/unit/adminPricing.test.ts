/**
 * Unit tests for lib/adminPricing.ts — flags and submit rules for
 * hand-priced ("admin-priced") and unmatched order lines (20261111170000).
 * Since 20261113090000 an admin OR inside sales may price by hand, and a
 * hand-priced order may carry the same part on two lines.
 *
 * Run with:  npm run test:unit -- adminPricing
 */
import {
  blocksWriterEdit,
  handPricingStopsSubmit,
  lineFlags,
  mayPriceOrder,
  needsPricingReview,
  parsePriceInput,
  pricingSubmitBlock,
  pricingSummary,
  reviewLines,
  writerSaveRefusal,
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

// ------------------------------------------------------- who may price
// 20261113090000: an admin on any order, inside sales on their own only.
const viewer = (isAdmin: boolean, isOwner: boolean, canPriceOrders: boolean) =>
  mayPriceOrder({ isAdmin, isOwner, canPriceOrders })
t('an admin prices any order', [viewer(true, false, true), viewer(true, true, true)], [true, true])
t('inside sales prices their own order', viewer(false, true, true), true)
t('inside sales does not price a rep\'s order (not_owner)', viewer(false, false, true), false)
t('a rep never prices, not even their own', [viewer(false, true, false), viewer(false, false, false)], [false, false])

// ------------------------------------------------------------- submit
// The second argument is mayPriceOrder() for the viewer.
t('unmatched blocks everyone', pricingSubmitBlock([lower, unmatched], true).startsWith('1 line match no part'), true)
t('hand-priced lines: an admin must submit a rep\'s draft', pricingSubmitBlock([lower], false), 'This order has hand-priced lines, so an admin must submit it.')
t('hand-priced lines fine for whoever may price the order', pricingSubmitBlock([lower], true), '')
t('list lines fine for a rep', pricingSubmitBlock([list], false), '')
t('hand prices stop a rep for good (the box and Submit are hidden)', [handPricingStopsSubmit([lower], false), handPricingStopsSubmit([lower], true), handPricingStopsSubmit([list], false)], [true, false, false])
t('unmatched and hand-priced, for a rep: both are said',
  pricingSubmitBlock([lower, unmatched], false).endsWith('before submitting. This order has hand-priced lines, so an admin must submit it.'), true)
t('an unmatched line alone does not hide Submit (it can be removed)', handPricingStopsSubmit([list, base({ id: 6, part_unresolved: true })], false), false)

// --------------------------------------------------------- review block lines
const ids = (rows: { line: PricedLine }[]) => rows.map((r) => r.line.id)
t('flagged lines only, for someone who cannot price', ids(reviewLines([list, lower, offList], false)), [2, 3])
t('every line, for someone who may price (a price can be set on a list line)', ids(reviewLines([list, lower, offList], true)), [1, 2, 3])
t('a line reset to list stays in the editor', ids(reviewLines([list, base({ id: 7 })], true)), [1, 7])
t('each row carries its flags', reviewLines([lower], true)[0].flags, ['not_list_price'])

// -------------------------------------------------- the writer's save guard
const row = (id: number, over: Partial<PricedLine> = {}) => ({ id, price_source: 'list' as const, part_unresolved: false, ...over })
t('same lines as opened: save', writerSaveRefusal([row(1), row(2)], [2, 1]), '')
t('a hand price since: refused', writerSaveRefusal([row(1), row(2, { price_source: 'admin' })], [1, 2]).startsWith('Nothing was saved: this draft now has hand-priced'), true)
t('an unmatched line since: refused', writerSaveRefusal([row(1, { part_unresolved: true })], [1]) !== '', true)
t('Claude replaced the lines (new ids): refused', writerSaveRefusal([row(3), row(4)], [1, 2]).startsWith('Nothing was saved: this draft was changed'), true)
t('a line added elsewhere: refused', writerSaveRefusal([row(1), row(2)], [1]) !== '', true)
t('a new draft with no lines yet: save', writerSaveRefusal([], []), '')

// ------------------------------------------- the same part on two lines
// 10 paid and 1 free: two lines, one part_id, told apart only by id.
const paid = base({ id: 11, qty: 10, price_source: 'admin', unit_price: 1700, list_unit_price: 2000 })
const free = base({ id: 12, qty: 1, price_source: 'admin', unit_price: 0, list_unit_price: 2000 })
t('same part twice: each line is flagged on its own', [paid, free].map((l) => lineFlags(l)), [['not_list_price'], ['not_list_price']])
t('same part twice: both count, neither is merged', pricingSummary([paid, free]), {
  lines: 2,
  adminLines: 2,
  offList: 0,
  notListPrice: 2,
  unmatched: 0,
  descriptionChecks: 0,
  adminValue: 10 * 1700,
  belowList: 10 * 300 + 2000,
})
t('a free line is still a hand price to review', needsPricingReview([free]), true)
t('same part twice blocks a rep, not inside sales on their own', [pricingSubmitBlock([paid, free], false) !== '', pricingSubmitBlock([paid, free], true)], [true, ''])

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
