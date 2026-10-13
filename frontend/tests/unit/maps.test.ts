/**
 * Unit tests for lib/maps.ts — Directions links from ERP addresses.
 *
 * Run with:  npm run test:unit
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. The behaviour that matters most is refusing: a PO box or a bare
 * city must produce NO link rather than a pin somewhere the shop is not.
 */
import {
  directionsUrl,
  formatAddress,
  MAX_ROUTE_STOPS,
  multiStopRouteUrl,
  soldToAddress,
} from '../../src/lib/maps'

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

const shop = { address1: '123 Main St', city: 'Boise', state: 'ID', zip: '83702' }

/* --- formatAddress -------------------------------------------------------- */
t('full address', formatAddress(shop), '123 Main St, Boise, ID 83702')
t(
  'suite line kept',
  formatAddress({ ...shop, address2: 'Suite 4' }),
  '123 Main St, Suite 4, Boise, ID 83702',
)
t('whitespace collapsed', formatAddress({ ...shop, address1: '  123   Main St ' }), '123 Main St, Boise, ID 83702')
t('zip without city/state is enough', formatAddress({ address1: '1 A St', zip: '84601' }), '1 A St, 84601')
t('city + state without zip is enough', formatAddress({ address1: '1 A St', city: 'Provo', state: 'UT' }), '1 A St, Provo, UT')
t('no street → null', formatAddress({ city: 'Boise', state: 'ID', zip: '83702' }), null)
t('street with city but no state or zip → null', formatAddress({ address1: '1 A St', city: 'Provo' }), null)
t('PO box only → null', formatAddress({ ...shop, address1: 'PO Box 55' }), null)
t('P.O. BOX spelled out → null', formatAddress({ ...shop, address1: 'P.O. BOX 55' }), null)
t(
  'PO box on line 1, street on line 2 → street',
  formatAddress({ ...shop, address1: 'PO Box 55', address2: '9 Elm Ave' }),
  '9 Elm Ave, Boise, ID 83702',
)
t('null', formatAddress(null), null)

/* --- directionsUrl -------------------------------------------------------- */
t(
  'search URL, encoded',
  directionsUrl(shop),
  'https://www.google.com/maps/search/?api=1&query=123%20Main%20St%2C%20Boise%2C%20ID%2083702',
)
t('ampersand is encoded', directionsUrl({ ...shop, address1: 'R&R Plaza 5' })?.includes('R%26R'), true)
t('not enough address → null', directionsUrl({ city: 'Boise', state: 'ID' }), null)
t(
  'from dim_customer sold-to columns',
  formatAddress(
    soldToAddress({
      sold_to_address1: '4 Oak Rd',
      sold_to_address2: null,
      sold_to_city: 'Fargo',
      sold_to_state: 'ND',
      sold_to_zip_code: '58103',
    }),
  ),
  '4 Oak Rd, Fargo, ND 58103',
)

/* --- multiStopRouteUrl ---------------------------------------------------- */
const a = { address1: '1 A St', city: 'Provo', state: 'UT' }
const b = { address1: '2 B St', city: 'Orem', state: 'UT' }
const c = { address1: '3 C St', city: 'Lehi', state: 'UT' }

t(
  'one stop is a destination with no waypoints',
  multiStopRouteUrl([a]),
  'https://www.google.com/maps/dir/?api=1&destination=1%20A%20St%2C%20Provo%2C%20UT&travelmode=driving',
)
t(
  'last stop is the destination, the rest are waypoints in order',
  multiStopRouteUrl([a, b, c]),
  'https://www.google.com/maps/dir/?api=1&destination=3%20C%20St%2C%20Lehi%2C%20UT&travelmode=driving' +
    '&waypoints=1%20A%20St%2C%20Provo%2C%20UT%7C2%20B%20St%2C%20Orem%2C%20UT',
)
t('unusable stops are skipped', multiStopRouteUrl([null, { city: 'X' }, a]), multiStopRouteUrl([a]))
t('nothing usable → null', multiStopRouteUrl([{ city: 'X' }]), null)
t('empty → null', multiStopRouteUrl([]), null)

const many = Array.from({ length: 14 }, (_, i) => ({
  address1: `${i + 1} Main St`,
  city: 'Provo',
  state: 'UT',
}))
const url = new URL(multiStopRouteUrl(many)!)
t('cap is 10 stops', MAX_ROUTE_STOPS, 10)
t('stops past the cap are dropped (9 waypoints)', url.searchParams.get('waypoints')?.split('|').length, 9)
t('the 10th stop is the destination', url.searchParams.get('destination'), '10 Main St, Provo, UT')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
