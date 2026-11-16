/**
 * Unit tests for lib/usage.ts (what Admin › Usage counts) and
 * lib/gridGroup.ts + stockCategory (the In stock page's sections).
 *
 * Run with:  npm run test:unit -- usage
 */
import { deviceFor, pageLabel, pageViewFor, trackUsage, viewKey } from '../../src/lib/usage'
import { drawItems, groupRows } from '../../src/lib/gridGroup'
import {
  compareStockCategories,
  isGunStockRow,
  STOCK_CATEGORY_BARRELED,
  STOCK_CATEGORY_COMPONENTS,
  stockCategory,
} from '../../src/composables/useIntel'

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

/* ---- page views ---------------------------------------------------------- */
t('phone / tablet / desktop', [deviceFor(390), deviceFor(639), deviceFor(640), deviceFor(1024)], [
  'phone',
  'phone',
  'tablet',
  'desktop',
])
t('a tab is a page view', pageViewFor({ name: 'intel-ats', params: {} }), {
  event: 'page_view',
  page: 'intel-ats',
  customer_key: null,
  detail: null,
})
t(
  'an account page carries its account',
  pageViewFor({ name: 'account', params: { customerKey: 'VECA|1005' } })?.customer_key,
  'VECA|1005',
)
t('an order page carries its order', pageViewFor({ name: 'order-detail', params: { id: '42' } })?.detail, {
  order_id: '42',
})
t('the sign-in page is not use', pageViewFor({ name: 'login', meta: { public: true } }), null)
t('an unnamed route is not a view', pageViewFor({ params: {} }), null)
t(
  'the query string is not part of a screen',
  viewKey({ name: 'intel-ats', params: {} }) === viewKey({ name: 'intel-ats', params: {} }),
  true,
)
t(
  'another account is another screen',
  viewKey({ name: 'account', params: { customerKey: 'A' } }) ===
    viewKey({ name: 'account', params: { customerKey: 'B' } }),
  false,
)

const titles = { 'intel-ats': 'In stock', 'admin-price-lists': 'Price Lists', overview: 'Overview', orders: 'My Orders' }
t('intel pages name their section', pageLabel('intel-ats', titles), 'Intel › In stock')
t('admin pages name theirs', pageLabel('admin-price-lists', titles), 'Admin › Price Lists')
t('orders', pageLabel('orders', titles), 'Orders › My Orders')
t('top-level pages stand alone', pageLabel('overview', titles), 'Overview')
t('a page that no longer exists keeps its name', pageLabel('old-page', titles), 'old-page')
t('no page', pageLabel(null, titles), 'Unknown')

// Unconfigured (tests, signed out): tracking is a no-op, never a throw.
let threw = false
try {
  trackUsage({ event: 'page_view', page: 'overview' })
} catch {
  threw = true
}
t('tracking before sign-in does nothing', threw, false)

/* ---- stock categories ---------------------------------------------------- */
const evoke = { product_code: 'FG-EVOKE', product_family: 'Evoke', chambering: '7MM PRC' }
const ridge = { product_code: 'FG-RL', product_family: 'RIDGELINE FLASH FORGED TECHNOLOGY', chambering: '6.5 PRC' }
const action = { product_code: 'FG-BARACT', product_family: 'BARRELED ACTION', chambering: '300 PRC' }
const part = { product_code: 'ACC', product_family: 'N/A', chambering: null }
const oem = { product_code: 'OEM COMPONENT', product_family: 'RIDGELINE', chambering: '6.5 PRC' }
const bare = { product_code: null, product_family: null, chambering: '308 WIN' }

t('a gun sits under its family', stockCategory(evoke), 'EVOKE')
t('the full family name is kept', stockCategory(ridge), 'RIDGELINE FLASH FORGED TECHNOLOGY')
t('barreled actions are their own section', stockCategory(action), STOCK_CATEGORY_BARRELED)
t('a part is a component', stockCategory(part), STOCK_CATEGORY_COMPONENTS)
t('a component product code is a component', stockCategory(oem), STOCK_CATEGORY_COMPONENTS)
t('a gun with no family', stockCategory(bare), 'Other guns')
t(
  'sections agree with "Guns only"',
  [evoke, ridge, action, part, oem, bare].map(
    (r) =>
      isGunStockRow(r) ===
      ![STOCK_CATEGORY_BARRELED, STOCK_CATEGORY_COMPONENTS].includes(stockCategory(r)),
  ),
  [true, true, true, true, true, true],
)
t(
  'guns by name, then barreled actions, then components',
  [STOCK_CATEGORY_COMPONENTS, 'RIDGELINE', STOCK_CATEGORY_BARRELED, 'EVOKE'].sort(compareStockCategories),
  ['EVOKE', 'RIDGELINE', STOCK_CATEGORY_BARRELED, STOCK_CATEGORY_COMPONENTS],
)

/* ---- grid sections ------------------------------------------------------- */
const rows = [
  { id: 1, fam: 'B' },
  { id: 2, fam: 'A' },
  { id: 3, fam: 'B' },
  { id: 4, fam: 'A' },
  { id: 5, fam: 'C' },
]
const groups = groupRows(rows, (r) => r.fam)
t('groups by name, rows keep their order', groups.map((g) => [g.key, g.rows.map((r) => r.id)]), [
  ['A', [2, 4]],
  ['B', [1, 3]],
  ['C', [5]],
])
const shape = (d: ReturnType<typeof drawItems<(typeof rows)[number]>>) =>
  d.items.map((i) => (i.kind === 'group' ? `${i.group.key}${i.collapsed ? '-' : '+'}` : i.row.id))
t('every section open', shape(drawItems(groups, new Set(), 100)), ['A+', 2, 4, 'B+', 1, 3, 'C+', 5])
const closed = drawItems(groups, new Set(['B']), 100)
t('a closed section keeps its header, hides its rows', shape(closed), ['A+', 2, 4, 'B-', 'C+', 5])
t('closed rows are not waiting behind "Show more"', [closed.drawn, closed.drawable], [3, 3])
const capped = drawItems(groups, new Set(), 3)
t('the row cap still lists every section', shape(capped), ['A+', 2, 4, 'B+', 1, 'C+'])
t('and counts what is left', [capped.drawn, capped.drawable], [3, 5])

console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exit(1)
