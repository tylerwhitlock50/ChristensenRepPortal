/**
 * Unit tests for buildAccountReach() in composables/useBestContacts.ts — the
 * pure assembly step behind useBestContacts / useAccountReach.
 *
 * Run with:  npm run test:unit
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. The module imports lib/supabase.ts, so this needs the placeholder
 * env tests/unit/run.mjs sets. Nothing here makes a request.
 */
import { buildAccountReach, bestContactsKeys } from '../../src/composables/useBestContacts'

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

const customer = {
  customer_key: 'C1',
  invoice_email: 'payables@dealer.com',
  statement_email: null,
  sold_to_address1: '12 Range Rd',
  sold_to_address2: null,
  sold_to_city: 'Gunnison',
  sold_to_state: 'UT',
  sold_to_zip_code: '84634',
}

const contacts = [
  {
    contact_key: 'erp-1',
    source: 'erp' as const,
    customer_key: 'C1',
    name: 'C0001',
    display_name: null,
    title: null,
    phone: null,
    email: 'payables@dealer.com',
    is_primary: true,
    do_not_call: false,
    updated_at: null,
  },
  {
    contact_key: 'erp-2',
    source: 'erp' as const,
    customer_key: 'C1',
    name: '0027284',
    display_name: 'Dana Fox',
    title: 'Owner',
    phone: '435-555-0100',
    email: 'dana@dealer.com',
    is_primary: false,
    do_not_call: false,
    updated_at: null,
  },
]

const reach = buildAccountReach('C1', contacts, customer)
t('best is the owner, not the invoice address', reach.best.contact?.contact_key, 'erp-2')
t('callable', reach.best.callable, true)
t('label uses display_name', reach.best.contact?.label, 'Dana Fox')
t('the invoice-address row ranks last', reach.ranked.map((c) => c.kind), ['buyer', 'billing'])
t('address line', reach.addressLine, '12 Range Rd, Gunnison, UT 84634')
t('directions link', reach.directionsUrl?.startsWith('https://www.google.com/maps/search/?api=1&query=12%20Range%20Rd'), true)

const bare = buildAccountReach('C2', [], null)
t('no customer row: no address', [bare.addressLine, bare.directionsUrl], [null, null])
t('no contacts: no best', bare.best, { contact: null, callable: false, reason: 'none' })

t(
  'survives JSON (a persisted query cache stores it that way)',
  JSON.parse(JSON.stringify(reach)),
  reach,
)

t('account key sits under the contacts prefix', bestContactsKeys.account('C1'), ['account', 'C1', 'contacts', 'reach'])
t('multi key', bestContactsKeys.forKeys(['A', 'B']), ['contacts', 'best', ['A', 'B']])

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
