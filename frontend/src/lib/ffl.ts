import { differenceInCalendarDays, isValid, parse } from 'date-fns'

/**
 * FFL expiry parsing.
 *
 * For a firearms manufacturer this is the highest-value unsurfaced field in
 * the schema: an expired Federal Firearms License stops the shipment, and the
 * rep — the one person with the dealer relationship — is the last to find
 * out. erp.dim_customer.ffl_expiration_raw has been landed since 002 and read
 * by nothing.
 *
 * The catch is in the column name. bi.vw_DimCustomer sources it from
 * CUSTOMER.USER_4 / USER_5 — free-form user-defined ERP fields — and the view
 * header says so outright: "(free-form string)". Nobody has ever validated
 * what goes in there, so this parser's job is as much to REFUSE as to parse.
 *
 * The rule everything below follows: never render a date we are not sure of.
 * A wrong expiry on a compliance field is worse than no expiry — it tells a
 * rep the licence is good when it is not. When parsing fails we show the raw
 * string, exactly as the ERP holds it, and say nothing about when it expires.
 *
 * Pure and exported so it can be reasoned about (and tested) without a DB.
 */

/**
 * Formats seen in free-text US licence-expiry fields, most specific first.
 * date-fns `parse` is strict about these, which is what we want — a loose
 * parse is how "12/31" becomes a confident wrong answer.
 */
const FORMATS = [
  'yyyy-MM-dd',
  'MM/dd/yyyy',
  'M/d/yyyy',
  'MM-dd-yyyy',
  'M-d-yyyy',
  'MM/dd/yy',
  'M/d/yy',
  'MM-dd-yy',
  'M-d-yy',
  'MMddyyyy',
  'MMMM d, yyyy',
  'MMM d, yyyy',
  'MMM yyyy',
  'MMMM yyyy',
]

/**
 * A date this far out is not a licence expiry, it is a typo or a different
 * field entirely ("20261231" read as a year, a serial number, a phone
 * number). Refusing implausible results is most of what stops garbage
 * reaching a compliance badge.
 */
const MAX_YEARS_AHEAD = 25
const MAX_YEARS_BEHIND = 25

function plausible(d: Date, today: Date): boolean {
  const years = (d.getTime() - today.getTime()) / (365.25 * 24 * 3600 * 1000)
  return years <= MAX_YEARS_AHEAD && years >= -MAX_YEARS_BEHIND
}

/**
 * Best-effort date out of a free-form string. Returns null whenever the value
 * is missing, unparseable, or parses to something implausible — and null
 * always means "we do not know", never "no expiry".
 */
export function parseFflExpiry(
  raw: string | null | undefined,
  today: Date = new Date(),
): Date | null {
  const value = (raw ?? '').trim()
  if (!value) return null

  // Strip common noise: "EXP 12/31/26", "Expires: 12/31/2026", trailing dots.
  const cleaned = value
    .replace(/^(exp(ires?)?|valid\s+(un)?til)\b[:.\s]*/i, '')
    .replace(/[.,;]+$/, '')
    .trim()
  if (!cleaned) return null

  for (const fmt of FORMATS) {
    // referenceDate matters for two-digit years: date-fns resolves 'yy'
    // against it, so 26 becomes 2026 rather than 1926.
    const parsed = parse(cleaned, fmt, today)
    if (isValid(parsed) && plausible(parsed, today)) return parsed
  }
  return null
}

export type FflState =
  /** No licence number recorded at all. */
  | 'missing'
  /** Number recorded, expiry unparseable or absent — show the raw string. */
  | 'unknown'
  | 'expired'
  | 'expiring'
  | 'valid'

export interface FflStatus {
  state: FflState
  licenseNumber: string | null
  /** The ERP's string, always kept so a rep can read what was actually typed. */
  raw: string | null
  expiresOn: Date | null
  /** Negative once expired. Null when we could not parse a date. */
  daysRemaining: number | null
}

/**
 * How close is close enough to be worth a conversation. A licence renewal is
 * paperwork the dealer has to start well before the date, so this is
 * deliberately generous rather than a last-minute alarm.
 */
export const FFL_EXPIRING_DAYS = 60

export function fflStatus(
  licenseNumber: string | null | undefined,
  raw: string | null | undefined,
  today: Date = new Date(),
): FflStatus {
  const license = (licenseNumber ?? '').trim() || null
  const rawValue = (raw ?? '').trim() || null
  const expiresOn = parseFflExpiry(rawValue, today)

  if (!license && !rawValue) {
    return {
      state: 'missing',
      licenseNumber: null,
      raw: null,
      expiresOn: null,
      daysRemaining: null,
    }
  }

  if (!expiresOn) {
    return {
      state: 'unknown',
      licenseNumber: license,
      raw: rawValue,
      expiresOn: null,
      daysRemaining: null,
    }
  }

  const daysRemaining = differenceInCalendarDays(expiresOn, today)
  const state: FflState =
    daysRemaining < 0
      ? 'expired'
      : daysRemaining <= FFL_EXPIRING_DAYS
        ? 'expiring'
        : 'valid'

  return { state, licenseNumber: license, raw: rawValue, expiresOn, daysRemaining }
}

/** One line a rep can act on, or null when there is nothing worth saying. */
export function fflSentence(status: FflStatus): string | null {
  switch (status.state) {
    case 'expired':
      return status.daysRemaining === -1
        ? 'FFL expired yesterday'
        : `FFL expired ${Math.abs(status.daysRemaining ?? 0)} days ago`
    case 'expiring':
      return status.daysRemaining === 0
        ? 'FFL expires today'
        : `FFL expires in ${status.daysRemaining} days`
    case 'valid':
      return null
    case 'unknown':
      // Say what the ERP holds rather than guessing at it.
      return status.raw ? `FFL expiry on file: “${status.raw}”` : null
    case 'missing':
      return null
  }
}

/**
 * Credit status strings that mean "this order is not going to ship". The ERP
 * is free-form here too, so this matches on substrings rather than an enum —
 * and errs toward flagging, because a false alarm costs a phone call while a
 * miss costs a rep an afternoon writing an order that cannot be filled.
 */
const BLOCKING_CREDIT = /hold|block|suspend|stop|revoke|inactive|delinquent/i

export function isCreditBlocked(creditStatus: string | null | undefined): boolean {
  return BLOCKING_CREDIT.test((creditStatus ?? '').trim())
}
