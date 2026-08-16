/**
 * Unit tests for lib/orderPricing.ts — the buy-X-get-Y prorate preview.
 *
 * Run with:  npm run test:unit
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. The one behaviour that must never regress is agreement with the
 * SQL twin in submit_order() (20260817000200_orders.sql) — the fixture
 * numbers below (18 units on buy 10 get 2 → 11.1111% → 44.44) are asserted
 * verbatim in supabase/tests/20260817_orders.sql, so a drift in either
 * implementation shows up as a failure on one side or the other.
 */
import {
  orderTotal,
  priceOrder,
  type PricingLineInput,
  type PromoConfig,
} from '../../src/lib/orderPricing'

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

const promo = (buyQty: number, getQty: number): PromoConfig => ({ buyQty, getQty })
const line = (
  key: string,
  priceListId: number,
  qty: number,
  listUnitPrice: number,
): PricingLineInput => ({ key, priceListId, partId: key, qty, listUnitPrice })

const buy10get2 = new Map([[2, promo(10, 2)]])

// ---------------------------------------------------------------------------
// Baseline: no promos anywhere.
// ---------------------------------------------------------------------------
{
  const out = priceOrder([line('a', 1, 3, 100)], new Map())
  t('general list passes through at list price', out[0].effectiveUnitPrice, 100)
  t('general list has zero discount', out[0].discountPct, 0)
  t('line total is qty × price', out[0].lineTotal, 300)
}

t('empty input yields empty output', priceOrder([], buy10get2), [])

// ---------------------------------------------------------------------------
// The threshold: below one block nothing happens, at the block it kicks in.
// ---------------------------------------------------------------------------
{
  const out = priceOrder([line('a', 2, 11, 50)], buy10get2)
  t('11 units on buy 10 get 2 is below the block — 0%', out[0].discountPct, 0)
}
{
  const out = priceOrder([line('a', 2, 12, 50)], buy10get2)
  t('12 units = one block — exact 2/12 = 16.6667%', out[0].discountPct, 16.6667)
  t('50.00 at 16.6667% → 41.67', out[0].effectiveUnitPrice, 41.67)
}

// ---------------------------------------------------------------------------
// Remainder dilution — the fixture shared with the SQL tests.
// ---------------------------------------------------------------------------
{
  const out = priceOrder([line('a', 2, 18, 50)], buy10get2)
  t('18 units → 1 multiple → 2/18 = 11.1111%', out[0].discountPct, 11.1111)
  t('50.00 at 11.1111% → 44.44', out[0].effectiveUnitPrice, 44.44)
  t('18 × 44.44 = 799.92', out[0].lineTotal, 799.92)
}
{
  const out = priceOrder([line('a', 2, 24, 50)], buy10get2)
  t('24 units → 2 multiples → 4/24 = 16.6667%', out[0].discountPct, 16.6667)
}

// ---------------------------------------------------------------------------
// The promo pools across lines of the SAME list…
// ---------------------------------------------------------------------------
{
  const out = priceOrder([line('a', 2, 8, 50), line('b', 2, 10, 80)], buy10get2)
  t('8 + 10 units pool to 18 → both lines at 11.1111%', out.map((l) => l.discountPct), [
    11.1111, 11.1111,
  ])
  t('each line discounts its own price (80 → 71.11)', out[1].effectiveUnitPrice, 71.11)
}

// ---------------------------------------------------------------------------
// …but never across lists: general lines and other specials are untouched.
// ---------------------------------------------------------------------------
{
  const promos = new Map([
    [2, promo(10, 2)],
    [3, promo(5, 1)],
  ])
  const out = priceOrder(
    [
      line('gen', 1, 100, 10), // general — no promo entry
      line('sp2', 2, 12, 50), // one block of buy 10 get 2
      line('sp3', 3, 5, 20), // below the buy-5-get-1 block of 6
    ],
    promos,
  )
  t('general line ignores every promo', out[0].discountPct, 0)
  t('each special prorates independently', out[1].discountPct, 16.6667)
  t('a special below its own block stays at 0%', out[2].discountPct, 0)
}

// ---------------------------------------------------------------------------
// Same part on a general AND a special list = two lines, one discount.
// ---------------------------------------------------------------------------
{
  const out = priceOrder(
    [line('PART-1', 1, 2, 100), { ...line('PART-1', 2, 12, 90), partId: 'PART-1' }],
    buy10get2,
  )
  t('the general copy of the part keeps list price', out[0].effectiveUnitPrice, 100)
  t('the special copy of the part discounts', out[1].discountPct, 16.6667)
}

// ---------------------------------------------------------------------------
// Never free, never negative — buy 1 get 1 is the extreme allowed config.
// ---------------------------------------------------------------------------
{
  const out = priceOrder([line('a', 2, 100, 1)], new Map([[2, promo(1, 1)]]))
  t('buy 1 get 1 caps at 50%, never 100%', out[0].discountPct, 50)
  t('a 1.00 part at 50% is 0.50, not free', out[0].effectiveUnitPrice, 0.5)
}

// ---------------------------------------------------------------------------
// Cent rounding at awkward prices.
// ---------------------------------------------------------------------------
{
  const out = priceOrder([line('a', 2, 12, 0.01)], buy10get2)
  t('a 1-cent part rounds to a cent, not below', out[0].effectiveUnitPrice, 0.01)
}
{
  const out = priceOrder([line('a', 2, 12, 19.99)], buy10get2)
  t('19.99 at 16.6667% → 16.66', out[0].effectiveUnitPrice, 16.66)
}

// ---------------------------------------------------------------------------
// orderTotal sums cents-exactly.
// ---------------------------------------------------------------------------
{
  const out = priceOrder(
    [line('a', 1, 2, 100), line('b', 2, 18, 50)],
    buy10get2,
  )
  t('order total matches the SQL fixture (999.92)', orderTotal(out), 999.92)
}

// ---------------------------------------------------------------------------
console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
