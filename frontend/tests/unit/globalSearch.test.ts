/**
 * Unit tests for the header search: dealer ranking and the in-stock
 * product filter (composables/useGlobalSearch.ts), and the recent-accounts
 * list (composables/useRecentAccounts.ts).
 *
 * Run with:  npm run test:unit -- globalSearch
 */
import {
  MAX_PRODUCTS,
  filterProducts,
  rankDealers,
  sanitizeTerm,
} from '../../src/composables/useGlobalSearch'
import {
  MAX_RECENT_ACCOUNTS,
  parseRecentAccounts,
  withRecentAccount,
  type RecentAccount,
} from '../../src/composables/useRecentAccounts'
import type { AtsRow } from '../../src/composables/useIntel'

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

/* ---- dealers ------------------------------------------------------------ */

const rows = [
  { customer_key: 'C100', customer_name: "Abigail's Guns" },
  { customer_key: 'C200', customer_name: 'Big Sky Sporting' },
  { customer_key: 'BIG', customer_name: 'Mountain Outfitters' },
  { customer_key: 'C300', customer_name: 'The Big Horn Shop' },
  { customer_key: 'C400', customer_name: 'Bigfork Arms' },
]

t('exact customer number, then name prefix (server order kept), then a word, then the rest',
  rankDealers(rows, 'big').map((r) => r.customer_key),
  ['BIG', 'C200', 'C400', 'C300', 'C100'])
t('case-insensitive', rankDealers(rows, 'BIG')[0]!.customer_key, 'BIG')
t('empty term keeps the server order', rankDealers(rows, '  ').map((r) => r.customer_key),
  ['C100', 'C200', 'BIG', 'C300', 'C400'])
t('a null name ranks by key alone',
  rankDealers([{ customer_key: 'X1', customer_name: null }, { customer_key: 'x1x', customer_name: 'X1 Supply' }], 'x1').map((r) => r.customer_key),
  ['X1', 'x1x'])

t('sanitizeTerm strips PostgREST syntax', sanitizeTerm(' a,b(c)"d\'e*f%g\\ '), 'abcdefg')

/* ---- products ----------------------------------------------------------- */

const ats = (part_id: string, ats_qty: number, over: Partial<AtsRow> = {}): AtsRow => ({
  part_key: `PK-${part_id}`,
  part_id,
  part_description: null,
  product_family: null,
  chambering: null,
  barrel_length: null,
  upc: null,
  on_hand_qty: 0,
  committed_qty: 0,
  backlog_qty: 0,
  inbound_qty: 0,
  ats_qty,
  next_avail_date: null,
  loaded_at: null,
  ...over,
})

const catalog = [
  ats('MPR-308-16', 4, { part_description: 'MPR 308 Win 16in', chambering: '308 Win' }),
  ats('MPR-65-24', 0, { part_description: 'MPR 6.5 PRC', chambering: '6.5 PRC' }),
  ats('MESA-308-22', 12, { part_description: 'Mesa 308 Win 22in', chambering: '308 Win' }),
  ats('RIDGE-7', 3, { upc: '810034630103', product_family: 'Ridgeline' }),
  ats('EVOKE-308', 2, { chambering: '308 Win' }),
  ats('TRAV-308', 1, { chambering: '308 Win' }),
  ats('SUMMIT-308', 9, { chambering: '308 Win' }),
  ats('CA5-308', 5, { chambering: '308 Win' }),
]

t('in stock only, most available first, capped',
  filterProducts(catalog, '308').map((p) => p.part_id),
  ['MESA-308-22', 'SUMMIT-308', 'CA5-308', 'MPR-308-16', 'EVOKE-308'])
t(`at most ${MAX_PRODUCTS}`, filterProducts(catalog, '308').length, MAX_PRODUCTS)
t('out of stock never shows', filterProducts(catalog, '6.5 prc'), [])
t('UPC and family match too',
  [filterProducts(catalog, '630103')[0]?.part_id, filterProducts(catalog, 'ridgeline')[0]?.part_id],
  ['RIDGE-7', 'RIDGE-7'])
t('blank term: nothing', filterProducts(catalog, ' '), [])

/* ---- recent accounts ---------------------------------------------------- */

const r = (k: string, name: string | null = null): RecentAccount => ({ customer_key: k, customer_name: name, at: '2026-10-13T08:00:00Z' })

t('newest first', withRecentAccount([r('A'), r('B')], r('C')).map((x) => x.customer_key), ['C', 'A', 'B'])
t('a revisit moves to the front, once', withRecentAccount([r('A'), r('B'), r('C')], r('B')).map((x) => x.customer_key), ['B', 'A', 'C'])
t('a revisit before the name loaded keeps the old name',
  withRecentAccount([r('A', 'Alpha'), r('B')], r('A'))[0]!.customer_name, 'Alpha')
t(`capped at ${MAX_RECENT_ACCOUNTS}`,
  withRecentAccount(Array.from({ length: 8 }, (_, i) => r(`K${i}`)), r('NEW')).map((x) => x.customer_key),
  ['NEW', 'K0', 'K1', 'K2', 'K3', 'K4', 'K5', 'K6'])

t('parse: garbage is empty', parseRecentAccounts('{not json'), [])
t('parse: not an array is empty', parseRecentAccounts('{"a":1}'), [])
t('parse: bad rows dropped, names normalised',
  parseRecentAccounts(JSON.stringify([{ customer_key: 'A', customer_name: 7, at: 1 }, { nope: true }, { customer_key: '' }, null])),
  [{ customer_key: 'A', customer_name: null, at: '' }])
t('parse: null is empty', parseRecentAccounts(null), [])

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
