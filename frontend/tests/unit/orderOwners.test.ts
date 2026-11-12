/**
 * Unit tests for lib/orderOwners.ts — whose order it is (order_owner_names(),
 * 20261113090000) and the Mine / Everyone switch on the orders list for an
 * admin or inside sales.
 *
 * Run with:  npm run test:unit -- orderOwners
 */
import {
  ORDER_LIST_SCOPE_KEY,
  ownerLabel,
  readListScope,
  scopeOrders,
  uniqueUserIds,
  writeListScope,
} from '../../src/lib/orderOwners'

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

// ----------------------------------------------------------------- ids
t('each id once, blanks dropped, sorted (a stable query key)', uniqueUserIds(['b', null, 'a', 'b', '', undefined, ' ']), ['a', 'b'])

// --------------------------------------------------------------- labels
const dana = { user_id: 'u2', display_name: 'Dana Reyes', role: 'inside_sales' }
t('the viewer is "you"', ownerLabel(dana, { isViewer: true }), 'you')
t('inside sales says so', ownerLabel(dana, { isViewer: false }), 'Dana Reyes (inside sales)')
t('an admin says so', ownerLabel({ ...dana, role: 'admin' }, { isViewer: false }), 'Dana Reyes (admin)')
t('a rep is just the name', ownerLabel({ ...dana, role: 'rep' }, { isViewer: false }), 'Dana Reyes')
t('not known: nothing, the screen says less', ownerLabel(undefined, { isViewer: false }), '')

// ---------------------------------------------------------------- scope
const rows = [
  { id: 1, user_id: 'me' },
  { id: 2, user_id: 'rep' },
  { id: 3, user_id: 'me' },
]
t('Mine: the viewer\'s own', scopeOrders(rows, 'mine', 'me').map((r) => r.id), [1, 3])
t('Everyone: all of them', scopeOrders(rows, 'everyone', 'me').map((r) => r.id), [1, 2, 3])
t('Mine with no signed-in user: nothing', scopeOrders(rows, 'mine', null), [])

// ------------------------------------------------- remembered per tab
const store = new Map<string, string>()
const fake = {
  getItem: (k: string) => store.get(k) ?? null,
  setItem: (k: string, v: string) => void store.set(k, v),
}
t('nothing stored: Mine', readListScope(fake), 'mine')
writeListScope('everyone', fake)
t('the choice is kept under its key', store.get(ORDER_LIST_SCOPE_KEY), 'everyone')
t('and read back', readListScope(fake), 'everyone')
store.set(ORDER_LIST_SCOPE_KEY, 'garbage')
t('anything else reads as Mine', readListScope(fake), 'mine')
const refusing = {
  getItem: () => {
    throw new Error('SecurityError')
  },
  setItem: () => {
    throw new Error('QuotaExceededError')
  },
}
t('storage that throws: Mine, and no error', readListScope(refusing), 'mine')
let threw = false
try {
  writeListScope('everyone', refusing)
} catch {
  threw = true
}
t('a refused write is swallowed', threw, false)
t('no storage at all (no window here): Mine', readListScope(), 'mine')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
