/**
 * Unit tests for lib/productLinks.ts — SKU cell → website product page.
 *
 * Run with:  npm run test:unit
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. The behaviour that matters most is refusing to guess: a blank or
 * 'N/A' family must produce NO link, never a 404 in front of a dealer.
 */
import { productFamilyUrl } from '../../src/lib/productLinks'

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

/* --- the slugs the site actually uses ----------------------------------- */
t(
  'two words',
  productFamilyUrl('Ridgeline FFT'),
  'https://christensenarms.com/product/ridgeline-fft/',
)
t(
  'single word',
  productFamilyUrl('Traverse'),
  'https://christensenarms.com/product/traverse/',
)
t(
  'already lowercase',
  productFamilyUrl('evoke'),
  'https://christensenarms.com/product/evoke/',
)
t(
  'punctuation collapses to one dash',
  productFamilyUrl('Modern Precision Rifle (MPR)'),
  'https://christensenarms.com/product/modern-precision-rifle-mpr-/'.replace(
    '-mpr-/',
    '-mpr/',
  ),
)
t(
  'surrounding whitespace',
  productFamilyUrl('  Mesa  '),
  'https://christensenarms.com/product/mesa/',
)

/* --- refuses rather than guesses ---------------------------------------- */
t('null', productFamilyUrl(null), null)
t('undefined', productFamilyUrl(undefined), null)
t('empty string', productFamilyUrl(''), null)
t('whitespace only', productFamilyUrl('   '), null)
t("dim_part's 'N/A' sentinel", productFamilyUrl('N/A'), null)
t("lowercase 'n/a'", productFamilyUrl('n/a'), null)
t('slugifies to nothing', productFamilyUrl('!!!'), null)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
