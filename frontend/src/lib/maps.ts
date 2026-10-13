/**
 * Directions links from the addresses the ERP already lands.
 *
 * Google Maps "universal" URLs (https://developers.google.com/maps/documentation/urls):
 * one https link that opens the Maps app on iOS and Android when installed
 * and the website otherwise, so there is no platform sniffing and no Apple
 * Maps branch to keep in step.
 *
 * Caveat worth knowing when showing these: for chains the ERP sold-to is
 * head office (SCHEELS → Fargo), so Directions goes to HQ, not the store.
 */

/** A postal address. Every field optional — ERP rows are patchy. */
export interface StreetAddress {
  address1?: string | null
  address2?: string | null
  city?: string | null
  state?: string | null
  zip?: string | null
}

/** dim_customer's sold-to columns (002_erp_read_tables.sql). */
export interface SoldToColumns {
  sold_to_address1?: string | null
  sold_to_address2?: string | null
  sold_to_city?: string | null
  sold_to_state?: string | null
  sold_to_zip_code?: string | null
}

export function soldToAddress(c: SoldToColumns): StreetAddress {
  return {
    address1: c.sold_to_address1,
    address2: c.sold_to_address2,
    city: c.sold_to_city,
    state: c.sold_to_state,
    zip: c.sold_to_zip_code,
  }
}

const clean = (s: string | null | undefined) => (s ?? '').replace(/\s+/g, ' ').trim()

// A PO box is where the mail goes, not where the shop is.
const PO_BOX = /^p\.?\s*o\.?\s*box\b|^post\s+office\s+box\b/i
// "Suite 4", "Unit B", "#12" on their own: kept beside a street, but not a
// street — a PO box plus a suite line has nowhere to drive to.
const UNIT_ONLY = /^((suite|ste|unit|apt|bldg|building|floor|fl|room|rm)\b\.?|#)\s*[\w-]*$/i

/**
 * One line, "123 Main St, Suite 4, Boise, ID 83702", or null when there is
 * no street to drive to. Needs a street line that is not a PO box or a bare
 * suite / unit, plus either city and state or a zip — a bare city would drop
 * a pin in the middle of town.
 */
export function formatAddress(a: StreetAddress | null | undefined): string | null {
  if (!a) return null
  const street = [clean(a.address1), clean(a.address2)].filter((s) => s && !PO_BOX.test(s))
  const city = clean(a.city)
  const state = clean(a.state)
  const zip = clean(a.zip)
  if (!street.some((s) => !UNIT_ONLY.test(s))) return null
  if (!(city && state) && !zip) return null
  const stateZip = [state, zip].filter(Boolean).join(' ')
  return [...street, city, stateZip].filter(Boolean).join(', ')
}

/** Search link for one address, or null when formatAddress() gives up. */
export function directionsUrl(a: StreetAddress | null | undefined): string | null {
  const q = formatAddress(a)
  if (!q) return null
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(q)}`
}

/**
 * The most stops one route link carries: Google allows 9 waypoints plus the
 * destination. Mobile BROWSERS honour only 3 waypoints (the Maps app takes
 * all 9), so a day of more than 4 stops is best opened with the app
 * installed — or split by the caller.
 */
export const MAX_ROUTE_STOPS = 10

/**
 * A driving route from wherever the phone is now through each address in
 * order. Addresses formatAddress() rejects are skipped; anything past
 * MAX_ROUTE_STOPS is dropped (the caller splits longer days). Null when no
 * stop is usable.
 */
export function multiStopRouteUrl(
  addresses: readonly (StreetAddress | null | undefined)[],
): string | null {
  const stops = addresses
    .map(formatAddress)
    .filter((s): s is string => !!s)
    .slice(0, MAX_ROUTE_STOPS)
  if (stops.length === 0) return null
  const destination = stops[stops.length - 1]!
  const waypoints = stops.slice(0, -1)
  // No origin: Google starts from the device's current location.
  const params = [
    'api=1',
    `destination=${encodeURIComponent(destination)}`,
    'travelmode=driving',
  ]
  if (waypoints.length > 0) {
    params.push(`waypoints=${encodeURIComponent(waypoints.join('|'))}`)
  }
  return `https://www.google.com/maps/dir/?${params.join('&')}`
}
