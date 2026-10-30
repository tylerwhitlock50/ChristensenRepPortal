/**
 * Unit tests for lib/orderShipTo.ts — the order writer's ship-to and FFL rules.
 *
 * Run with:  npm run test:unit -- orderShipTo
 *
 * Same harness as ffl.test.ts. The errors here must agree with submit_order()
 * (supabase/tests/20261030_order_ship_to_ffl.sql asserts the server side), and
 * fflNumbersMatch with sql-toolbox's audit (ffl.py numbers_match), which the
 * order loader also copies — the three must call the same pair a match.
 */
import {
  checkShipToAndFfl,
  fflNumbersMatch,
  fflPrefill,
  normalizeFfl,
  orderableShipTos,
  shipToLabel,
  type ShipToRow,
} from '../../src/lib/orderShipTo'

const today = new Date('2026-10-30T12:00:00')

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

function row(over: Partial<ShipToRow>): ShipToRow {
  return {
    ship_to_key: 'C|1',
    ship_to_id: 'STORE',
    ship_to_name: 'Dealer Store',
    address1: '1 Main St',
    address2: null,
    city: 'Boise',
    state: 'ID',
    zip_code: '83702',
    active_flag: 'Y',
    ffl_license_number: '1-23-456-78-9A-12345',
    ffl_expiration_raw: '1/31/2027',
    address_source: 'ShipTo',
    is_unknown_ship_to: false,
    ...over,
  }
}

// ---- which addresses can be picked
const rows = [
  row({ ship_to_key: 'C|3', ship_to_id: 'ZED' }),
  row({ ship_to_key: 'C|2', ship_to_id: 'OLD', active_flag: 'N' }),
  row({ ship_to_key: 'C|CUST', ship_to_id: null, address_source: 'CustomerMaster' }),
  row({ ship_to_key: 'C|1', ship_to_id: 'ALPHA' }),
  row({ ship_to_key: 'C|9', ship_to_id: '  ' }),
]
t(
  'sold-to fallback and blank IDs are not ship-tos; active first, then by ID',
  orderableShipTos(rows).map((r) => r.ship_to_id),
  ['ALPHA', 'ZED', 'OLD'],
)
t('label', shipToLabel(row({})), 'STORE — Dealer Store, Boise ID')

// ---- FFL number matching (sql-toolbox numbers_match semantics)
t('normalize strips separators', normalizeFfl(' 1-23-456-78-9a-12345 '), '123456789A12345')
t('same number, different separators', fflNumbersMatch('1-23-456-78-9A-12345', '1 23 456 78 9a 12345'), true)
t('EZ Check mask matches the real number', fflNumbersMatch('1-XX-XXX-XX-XX-12345', '1-23-456-78-9A-12345'), true)
t('mask does not rescue a different sequence', fflNumbersMatch('1-XX-XXX-XX-XX-99999', '1-23-456-78-9A-12345'), false)
t('one side without separators', fflNumbersMatch('123456789A12345', '1-23-456-78-9A-12345'), true)
t('different licence', fflNumbersMatch('1-23-456-78-9B-12345', '1-23-456-78-9A-12345'), false)
t('blank never matches', fflNumbersMatch('', '1-23-456-78-9A-12345'), false)

// ---- prefill from the address on file
t('prefill parses the free-form expiry', fflPrefill(row({}), today), {
  number: '1-23-456-78-9A-12345',
  expiresOn: '2027-01-31',
})
t('unparseable expiry is left for the rep', fflPrefill(row({ ffl_expiration_raw: 'see file' }), today), {
  number: '1-23-456-78-9A-12345',
  expiresOn: '',
})
t('no ship-to, nothing to prefill', fflPrefill(null, today), { number: '', expiresOn: '' })

// ---- what blocks submit (mirrors submit_order) and what warns
const ok = { fflNumber: '1-23-456-78-9A-12345', fflExpiresOn: '2027-01-31', today }
t('complete order passes', checkShipToAndFfl({ shipTo: row({}), ...ok }), { errors: [], warnings: [] })
t('no ship-to blocks', checkShipToAndFfl({ shipTo: null, ...ok }).errors, [
  'Pick the ship-to address for this order.',
])
t('inactive ship-to blocks', checkShipToAndFfl({ shipTo: row({ active_flag: 'N' }), ...ok }).errors.length, 1)
t('short FFL blocks', checkShipToAndFfl({ shipTo: row({}), ...ok, fflNumber: '1-23-456' }).errors.length, 1)
t('missing expiry blocks', checkShipToAndFfl({ shipTo: row({}), ...ok, fflExpiresOn: '' }).errors, [
  'Enter the FFL expiration date.',
])
t(
  'expired yesterday blocks, today is fine',
  [
    checkShipToAndFfl({ shipTo: row({}), ...ok, fflExpiresOn: '2026-10-29' }).errors.length,
    checkShipToAndFfl({ shipTo: row({}), ...ok, fflExpiresOn: '2026-10-30' }).errors.length,
  ],
  [1, 0],
)
const renewed = checkShipToAndFfl({ shipTo: row({}), ...ok, fflNumber: '1-23-456-78-1C-12345' })
t('a different licence warns but does not block', [renewed.errors.length, renewed.warnings.length], [0, 1])
const noneOnFile = checkShipToAndFfl({ shipTo: row({ ffl_license_number: null }), ...ok })
t('no licence on file warns but does not block', [noneOnFile.errors.length, noneOnFile.warnings.length], [0, 1])

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
