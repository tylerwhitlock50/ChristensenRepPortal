/**
 * Unit tests for gapPitch() / isLapsedGap() in composables/useAccountGaps.ts
 * — the sentence under each "Ready to ship" suggestion.
 *
 * Run with:  npm run test:unit -- gapPitch
 *
 * Same harness as ffl.test.ts: no framework, a t() helper, non-zero exit on
 * failure.
 *
 * Why: report_account_sku_gaps' bought_before means "any purchase in four
 * years", and the card used to say "they used to carry it" for a gun the
 * dealer reordered last month. "Lapsed" now needs about a year of silence.
 */
import { gapPitch, isLapsedGap, type SkuGapRow } from '../../src/composables/useAccountGaps'

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

const today = new Date('2026-10-13T12:00:00Z')

function row(over: Partial<SkuGapRow>): SkuGapRow {
  return {
    part_key: 'PK', part_id: 'MESA-65', part_description: 'Mesa', product_code: 'RIFLE',
    product_family: 'Mesa', chambering: '6.5 CM', barrel_length: '22"', upc: null,
    ats_qty: 12, dealer_count: 61, units_sold: 400, bought_before: false, last_bought_date: null,
    ...over,
  }
}

/* --- never bought ------------------------------------------------------- */
t('never bought', gapPitch(row({}), today), 'Stocked by 61 dealers · never carried here')
t('one dealer, singular',
  gapPitch(row({ dealer_count: 1 }), today), 'Stocked by 1 dealer · never carried here')
t('never bought is not lapsed', isLapsedGap(row({}), today), false)

/* --- bought recently: not "used to carry it" ---------------------------- */
t('bought last month',
  gapPitch(row({ bought_before: true, last_bought_date: '2026-09-02' }), today),
  'Stocked by 61 dealers · bought here in the last year')
t('bought last month is not lapsed',
  isLapsedGap(row({ bought_before: true, last_bought_date: '2026-09-02' }), today), false)
t('eleven months ago is not lapsed',
  isLapsedGap(row({ bought_before: true, last_bought_date: '2025-11-20' }), today), false)

/* --- bought long ago: lapsed -------------------------------------------- */
t('fourteen months ago',
  gapPitch(row({ bought_before: true, last_bought_date: '2025-08-01' }), today),
  'Stocked by 61 dealers · they used to carry it')
t('fourteen months ago is lapsed',
  isLapsedGap(row({ bought_before: true, last_bought_date: '2025-08-01' }), today), true)
t('a year and a day is lapsed',
  isLapsedGap(row({ bought_before: true, last_bought_date: '2025-10-12' }), today), true)
t('bought before with no date reads as lapsed',
  gapPitch(row({ bought_before: true, last_bought_date: null }), today),
  'Stocked by 61 dealers · they used to carry it')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
