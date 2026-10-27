/**
 * Unit tests for the In stock "Guns only" filter (G07), the Product line
 * gate (G13) and the "Shipped value" rule (G05).
 *
 * Run with:  npm run test:unit -- inStock
 *
 * Guns only is isGunRow (the Global page's test) minus barreled actions
 * (product_code FG-BARACT). Before v_ats_list carries product_code every
 * row's code is null, and the filter must then behave exactly like isGunRow
 * — no row may vanish just because the column is missing.
 *
 * Shipped value: shipment dollars are the packlist value when the database
 * has it and the older shipped_revenue figure when it does not — and the
 * activity feed's shipment items follow the same rule.
 */
import { hasProductLine, isGunRow, isGunStockRow } from '../../src/composables/useIntel'
import { shippedValue } from '../../src/lib/shippedValue'
import { groupActivity, mapActivityRow } from '../../src/composables/useActivityFeed'

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

const row = (product_code: string | null, product_family: string | null, chambering: string | null) => ({
  product_code,
  product_family,
  chambering,
})

/* ---- guns only ---------------------------------------------------------- */
t('a rifle is a gun', isGunStockRow(row('FG-RIFLE', 'MPR', '6.5 Creedmoor')), true)
t('a barreled action is not, though it has a chambering', isGunStockRow(row('FG-BARACT', 'RIDGELINE', '.308 Win')), false)
t('…in any case, with stray spaces', isGunStockRow(row(' fg-baract ', 'MESA', '7mm PRC')), false)
t('a component code is not (isGunRow)', isGunStockRow(row('COMPONENTS', 'MPR', '6.5 PRC')), false)
t('a part with no spec is not', isGunStockRow(row('ACCESSORY', 'N/A', '')), false)
t(
  'before the migration (no product_code) it is exactly isGunRow',
  [row(null, 'MPR', '6.5 Creedmoor'), row(null, 'N/A', null), row(null, null, '.300 Win Mag')].map(
    (r) => isGunStockRow(r) === isGunRow(r),
  ),
  [true, true, true],
)
t('…and keeps a speced row', isGunStockRow(row(null, 'MPR', '6.5 Creedmoor')), true)

/* ---- the Product line gate ---------------------------------------------- */
t('no product_code anywhere: no filter', hasProductLine([{ product_code: null }, { product_code: '  ' }, {}]), false)
t('one row with a code: filter shown', hasProductLine([{ product_code: null }, { product_code: 'FG-RIFLE' }]), true)
t('no rows: no filter', hasProductLine([]), false)

/* ---- shipped value ------------------------------------------------------- */
t('packlist value when present', shippedValue({ shipped_value: 4429.5, shipped_revenue: 4000 }), 4429.5)
t('a zero packlist value is a value', shippedValue({ shipped_value: 0, shipped_revenue: 12 }), 0)
t('falls back to the older figure without the column', shippedValue({ shipped_value: null, shipped_revenue: 4000 }), 4000)
t('…or when the key is absent altogether', shippedValue({ shipped_revenue: 99 }), 99)
t('nothing at all', shippedValue({}), null)

const shippedEvent = mapActivityRow({
  customer_key: 'FIX-1',
  kind: 'shipped',
  order_id: 'SO-1',
  packlist_id: 'PL-1',
  occurred_on: '2026-10-20',
  amount: '4000',
  shipped_value: '4429.50',
})
t('the feed reads shipped_value', shippedEvent?.shipped_value, 4429.5)
const orderEvent = mapActivityRow({ customer_key: 'FIX-1', kind: 'order_new', order_id: 'SO-2', amount: 900 })
t('…null on other kinds', orderEvent?.shipped_value, null)
t(
  'a shipment item shows the packlist value',
  groupActivity([shippedEvent!]).shipped[0]?.amount,
  4429.5,
)
const oldDatabase = mapActivityRow({
  customer_key: 'FIX-1',
  kind: 'shipped',
  order_id: 'SO-1',
  packlist_id: 'PL-1',
  occurred_on: '2026-10-20',
  amount: 4000,
})
t('…and the view\'s amount on a database without the column', groupActivity([oldDatabase!]).shipped[0]?.amount, 4000)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
