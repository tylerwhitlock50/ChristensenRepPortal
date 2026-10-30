import { format } from 'date-fns'
import { parseFflExpiry } from '@/lib/ffl'

/**
 * Ship-to and FFL rules for the order writer.
 *
 * Every portal order names the address it ships to and the FFL it ships
 * under (migration 20261030120000). submit_order() is the authority — it
 * refuses an order without an active ship-to on the account or without a
 * full, unexpired licence — and these helpers mirror it so the rep sees the
 * problem before pressing Submit, plus two things only a warning can say:
 * the licence differs from the one on file in Visual, or there is none on
 * file. Those don't block submit (a renewed licence is legitimately new);
 * order entry fixes Visual's ship-to before the order can be entered, and
 * the order loader refuses to write it until they match.
 *
 * Pure and exported so it can be tested without a DB.
 */

/** erp.dim_ship_to, the columns the writer reads (bi.vw_DimShipTo). */
export interface ShipToRow {
  ship_to_key: string
  ship_to_id: string | null
  ship_to_name: string | null
  address1: string | null
  address2: string | null
  city: string | null
  state: string | null
  zip_code: string | null
  active_flag: string | null
  ffl_license_number: string | null
  ffl_expiration_raw: string | null
  address_source: string | null
  is_unknown_ship_to: boolean | null
}

/**
 * Addresses an order can ship to: real CUST_ADDRESS rows (they have a
 * SHIPTO_ID Visual can carry), not the sold-to fallback the BI view adds for
 * reporting. Active first, then by ship-to ID; inactive ones are still
 * returned so the picker can show them greyed out rather than vanish.
 */
export function orderableShipTos(rows: ShipToRow[]): ShipToRow[] {
  return rows
    .filter(
      (r) =>
        r.address_source === 'ShipTo' &&
        !r.is_unknown_ship_to &&
        (r.ship_to_id ?? '').trim() !== '',
    )
    .sort(
      (a, b) =>
        Number(!isActiveShipTo(a)) - Number(!isActiveShipTo(b)) ||
        (a.ship_to_id ?? '').localeCompare(b.ship_to_id ?? ''),
    )
}

export function isActiveShipTo(row: ShipToRow): boolean {
  return (row.active_flag ?? 'Y').trim().toUpperCase() !== 'N'
}

/** "STORE — Dealer Store, Boise ID" */
export function shipToLabel(row: ShipToRow): string {
  const place = [row.city, row.state].filter(Boolean).join(' ')
  const name = [row.ship_to_name, place].filter(Boolean).join(', ')
  return `${row.ship_to_id}${name ? ` — ${name}` : ''}`
}

/** FFL numbers are written with and without dashes and spaces. */
export function normalizeFfl(value: string | null | undefined): string {
  return (value ?? '').replace(/[^0-9A-Za-z]/g, '').toUpperCase()
}

/** A full ATF licence number is 15 characters: 1-23-456-78-9A-12345. */
export const FFL_LENGTH = 15

/**
 * Same licence? ATF EZ Check masks the middle segments with X's
 * ("1-XX-XXX-XX-XX-12345"), so an all-X segment matches anything. Ported
 * from sql-toolbox's audit (mcp-server/app/src/ffl.py numbers_match) so the
 * portal, the order loader and the audit agree on what "matches" means.
 */
export function fflNumbersMatch(
  a: string | null | undefined,
  b: string | null | undefined,
): boolean {
  const ta = tokens(a)
  const tb = tokens(b)
  if (ta.length === 0 || tb.length === 0) return false
  if (ta.length !== tb.length) {
    // One side stored without separators: compare bare.
    return normalizeFfl(a) === normalizeFfl(b)
  }
  return ta.every((left, i) => {
    const right = tb[i]
    return isMask(left) || isMask(right) || left === right
  })
}

function tokens(value: string | null | undefined): string[] {
  return (value ?? '')
    .replace(/[\s\-_.]+/g, ' ')
    .trim()
    .toUpperCase()
    .split(' ')
    .filter(Boolean)
}

function isMask(token: string): boolean {
  return token.length > 0 && /^X+$/.test(token)
}

const ymd = (d: Date) => format(d, 'yyyy-MM-dd')

/**
 * What the FFL fields start as when a ship-to is picked: the licence on file
 * for that address, and its expiry when the free-form ERP string parses
 * (parseFflExpiry refuses rather than guesses — then the rep types it).
 */
export function fflPrefill(
  row: ShipToRow | null | undefined,
  today: Date = new Date(),
): { number: string; expiresOn: string } {
  if (!row) return { number: '', expiresOn: '' }
  const expires = parseFflExpiry(row.ffl_expiration_raw, today)
  return {
    number: (row.ffl_license_number ?? '').trim(),
    expiresOn: expires ? ymd(expires) : '',
  }
}

export interface ShipToFflCheck {
  /** Block submit — submit_order() would refuse these too. */
  errors: string[]
  /** Order entry will have to act; the rep should know. */
  warnings: string[]
}

export function checkShipToAndFfl(input: {
  shipTo: ShipToRow | null | undefined
  fflNumber: string
  fflExpiresOn: string
  today?: Date
}): ShipToFflCheck {
  const today = input.today ?? new Date()
  const errors: string[] = []
  const warnings: string[] = []
  const shipTo = input.shipTo

  if (!shipTo) {
    errors.push('Pick the ship-to address for this order.')
  } else if (!isActiveShipTo(shipTo)) {
    errors.push(`Ship-to ${shipTo.ship_to_id} is inactive in the ERP — pick another address.`)
  }

  const number = normalizeFfl(input.fflNumber)
  if (number.length !== FFL_LENGTH) {
    errors.push('Enter the full 15-character FFL number, e.g. 1-23-456-78-9A-12345.')
  }
  if (!input.fflExpiresOn) {
    errors.push('Enter the FFL expiration date.')
  } else if (input.fflExpiresOn < ymd(today)) {
    errors.push(`This FFL expired on ${input.fflExpiresOn} — get the renewed licence first.`)
  }

  if (shipTo && number.length === FFL_LENGTH) {
    const onFile = (shipTo.ffl_license_number ?? '').trim()
    if (!onFile) {
      warnings.push(
        `${shipTo.ship_to_id} has no FFL on file in the ERP. Order entry will add this one before entering the order.`,
      )
    } else if (!fflNumbersMatch(input.fflNumber, onFile)) {
      warnings.push(
        `This FFL differs from the one on file for ${shipTo.ship_to_id} (${onFile}). Order entry will update the ERP before entering the order — attach or send the new licence.`,
      )
    }
  }
  return { errors, warnings }
}
