/*============================================================================
  _shared/contacts.ts — who to ring at a dealer, for the Edge Functions.

  A COPY of frontend/src/lib/contacts.ts (everything below this header is
  byte-for-byte that file's code). The bundler builds each function from its
  import graph inside supabase/functions/, so the frontend module cannot be
  imported from here; duplicating ~250 lines of pure functions is the price
  of the MCP list_contacts tool ranking contacts exactly as the account page
  does. contacts.test.ts imports BOTH files and fails if they rank the same
  rows differently — edit the frontend file first, then copy it here.

  The rule in one line: the ERP's is_primary is often an INVOICE / AP
  mailbox with no phone; the buyer is further down. Rank by kind (rep's own
  primary, buyer, callable person, orders line, …, internal, billing last).
============================================================================*/

/** The fields ranking reads. AccountContact (useAccountData.ts) fits. */
export interface RankableContact {
  contact_key?: string | null
  source?: 'rep' | 'erp' | string | null
  name?: string | null
  /** v_account_contacts.display_name (20261013100000); absent before it. */
  display_name?: string | null
  title?: string | null
  phone?: string | null
  email?: string | null
  is_primary?: boolean | null
  do_not_call?: boolean | null
  updated_at?: string | null
}

/** dim_customer's own billing addresses — the exact billing signal. */
export interface BillingContext {
  invoiceEmail?: string | null
  statementEmail?: string | null
}

/**
 * Where a contact lands, best first. The order of this list IS the ranking.
 *
 *   rep-primary      a rep-entered row marked primary: the rep's explicit
 *                    choice, never second-guessed by the heuristics below
 *   buyer            a person with a callable phone and a buying title
 *   callable         a person with a callable phone
 *   orders-callable  an orders@ / purchasing@ mailbox with a callable phone —
 *                    a number at the dealer still beats no number
 *   do-not-call      a person whose shown number is marked do-not-call
 *   no-phone         a person with no number
 *   orders           an orders / purchasing mailbox with no callable phone
 *   internal         one of ours (@christensenarms.com)
 *   billing          invoice / AP / AR / statements
 */
export const CONTACT_KINDS = [
  'rep-primary',
  'buyer',
  'callable',
  'orders-callable',
  'do-not-call',
  'no-phone',
  'orders',
  'internal',
  'billing',
] as const
export type ContactKind = (typeof CONTACT_KINDS)[number]

/** A contact plus what ranking decided about it. All original fields kept. */
export type RankedContact<T extends RankableContact = RankableContact> = T & {
  kind: ContactKind
  /** contactDisplayName(): what to print as the contact's name. */
  label: string
  /** Has a phone and the ERP does not forbid calling it. */
  callable: boolean
}

export interface BestContact<T extends RankableContact = RankableContact> {
  /** Null when no row is a reachable non-billing, non-internal contact. */
  contact: RankedContact<T> | null
  callable: boolean
  /** The chosen contact's kind, or 'none' — so the UI can say why. */
  reason: ContactKind | 'none'
}

/* ----------------------------------------------------------- plumbing */

const lc = (s: string | null | undefined) => (s ?? '').trim().toLowerCase()

/**
 * "INVOICE", "A/P", "Accounts-Payable" → tokens. "A/P" and "A/R" are folded
 * to "ap" / "ar" first; every other '/' separates, so "AP/AR" and
 * "Owner/Accounting" are two tokens each, not one glued word.
 */
function tokens(s: string | null | undefined): string[] {
  return lc(s)
    .replace(/\ba\s*\/\s*([pr])\b/g, 'a$1')
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
}

function emailParts(email: string | null | undefined): { local: string; domain: string } {
  const e = lc(email)
  const at = e.lastIndexOf('@')
  if (at < 0) return { local: '', domain: '' }
  return { local: e.slice(0, at), domain: e.slice(at + 1) }
}

/** A field that is only digits (and spacing) — an ERP contact id, not a name. */
function isBareId(s: string | null | undefined): boolean {
  return /^[\s#-]*\d[\d\s-]*$/.test(s ?? '')
}

/* ------------------------------------------------------------ billing */

// Whole tokens only, so "AP" matches and "Apex" / "April" do not, and
// "Billings" (the Montana city, a surname) is not "billing".
const BILLING_TOKENS = new Set([
  'ap', 'ar', 'billing', 'statement', 'statements',
  'accounting', 'payable', 'payables', 'receivable', 'receivables',
])
const BILLING_PHRASE = /invoic|accounts?\s*-?\s*(payable|receivable)|acct\.?\s*(payable|receivable)/i
// A title like "AR-15 specialist" must not read as Accounts Receivable.
const FIREARM_TOKEN = /\bar-?1[05]\b/i

function textIsBilling(s: string | null | undefined): boolean {
  if (!s) return false
  if (BILLING_PHRASE.test(s)) return true
  const cleaned = s.replace(FIREARM_TOKEN, ' ')
  return tokens(cleaned).some((t) => BILLING_TOKENS.has(t))
}

// Email local parts: substrings for the long words (importinvoice@,
// accountspayable@), whole tokens for the short codes (ap@, ap.team@).
// "billing" but not "billings": tbillings@, billingsguns@ are a surname and
// a town, not a billing desk.
const BILLING_LOCAL_SUBSTR = /invoic|payable|receivable|billing(?!s)|statement|accounting/
const BILLING_LOCAL_TOKENS = new Set(['ap', 'ar', 'acctg', 'accts'])

function localIsBilling(local: string): boolean {
  if (!local) return false
  if (BILLING_LOCAL_SUBSTR.test(local)) return true
  return local.split(/[^a-z0-9]+/).some((t) => BILLING_LOCAL_TOKENS.has(t))
}

/** dim_customer.invoice_email can hold several addresses. */
function addressList(s: string | null | undefined): string[] {
  return lc(s)
    .split(/[;,\s]+/)
    .filter((x) => x.includes('@'))
}

// A field that also names a buying role ("Purchasing / AP", "Owner /
// Accounting", "Buyer & A/P") is the small-shop person who does both, and
// the buyer half is the one the rep calls. Narrower than BUYER_TITLE below:
// "manag" would rescue "AP Manager" and "Accounting Manager", and a BUYING
// GROUP is the co-op that pays the invoices, not a buyer.
const BUYING_ROLE = /\bbuy(?:er|ers|ing)?\b(?!\s*group)|purchas|owner|president|proprietor|\bgm\b|general\s+manager/i
// "Invoice" is never rescued: it is the INVOICE / IMPORTINVOICE@ primaries
// this file exists for.
const INVOICE_WORD = /invoic/i

const namesBuyingRole = (s: string | null | undefined) => BUYING_ROLE.test(s ?? '')

/**
 * An invoice / accounts-payable / AR / statements contact: not who places
 * orders.
 *
 * Name or title naming the function (INVOICE, INVOICES, AP, A/P, ACCOUNTS
 * PAYABLE, AR, BILLING, STATEMENTS) counts, unless that same field also
 * names a buying role (BUYING_ROLE). An email local part that names it
 * (invoices@, ap@, payable@, billing@, statements@, accounting@) counts
 * unless the name or title names a buying role — the owner of a two-person
 * shop reading the ap@ inbox is still the buyer. Anything saying "invoice"
 * counts whatever else it says.
 *
 * An email equal to the account's invoice_email / statement_email counts
 * too, with one exception: a NAMED person WITH a phone. Small shops send
 * invoices to the owner's own address, and calling the owner "billing"
 * would leave the header saying "No buyer number on file" over a dialable
 * owner. AP mailboxes that match this way are, in the data, nameless or
 * phoneless — the name rules above catch the rest.
 */
export function isBillingContact(c: RankableContact, opts: BillingContext = {}): boolean {
  const fields = [c.name, c.display_name, c.title]
  // Per field: "Purchasing / AP" rescues itself; an INVOICES name with a
  // Purchasing title does not.
  for (const s of fields) {
    if (textIsBilling(s) && (INVOICE_WORD.test(s ?? '') || !namesBuyingRole(s))) return true
  }
  const { local } = emailParts(c.email)
  if (localIsBilling(local) && (INVOICE_WORD.test(local) || !fields.some(namesBuyingRole))) {
    return true
  }

  const email = lc(c.email)
  if (!email) return false
  const billingAddresses = [
    ...addressList(opts.invoiceEmail),
    ...addressList(opts.statementEmail),
  ]
  if (!billingAddresses.includes(email)) return false
  return !(hasPersonName(c) && hasPhone(c))
}

/* ---------------------------------------------------- internal, orders */

const INTERNAL_DOMAIN = 'christensenarms.com'

/** One of ours: staff and AR show up as dealer contacts. */
export function isInternalContact(c: RankableContact): boolean {
  const { domain } = emailParts(c.email)
  return domain === INTERNAL_DOMAIN || domain.endsWith(`.${INTERNAL_DOMAIN}`)
}

const ORDERS_LOCAL = new Set([
  'order', 'orders', 'purchasing', 'purchase', 'purchases', 'po', 'pos',
  'buying', 'sales', 'info', 'office',
])
const ORDERS_NAME = /^(the\s+)?(orders?|purchasing|purchase\s+orders?|buying|po|sales|info|office)(\s+(dept\.?|department|desk|team|line|mailbox))?$/i

/**
 * A shared ordering mailbox — orders@, purchasing@, info@ — rather than a
 * person. Still worth having (it reaches the store), ranked after people.
 * A named person who happens to use orders@ stays a person.
 */
export function isOrdersMailbox(c: RankableContact): boolean {
  const name = (c.display_name ?? '').trim() || (c.name ?? '').trim()
  if (ORDERS_NAME.test(name)) return true
  const { local } = emailParts(c.email)
  const shared = local.split(/[^a-z0-9]+/).some((t) => ORDERS_LOCAL.has(t))
  return shared && !hasPersonName(c)
}

/* ------------------------------------------------------- name, phone */

/**
 * What to print as the contact's name. display_name (the view's
 * contact_name → first + last → contact_id) wins; then name. A bare numeric
 * ERP id is the last resort: the email is shown instead when there is one.
 */
export function contactDisplayName(c: RankableContact): string {
  for (const s of [c.display_name, c.name]) {
    const v = (s ?? '').trim()
    if (v && !isBareId(v)) return v
  }
  const email = (c.email ?? '').trim()
  if (email) return email
  const id = (c.display_name ?? '').trim() || (c.name ?? '').trim()
  return id || 'Unnamed contact'
}

/** A real name, not an id, an email address, or a mailbox word. */
function hasPersonName(c: RankableContact): boolean {
  const v = (c.display_name ?? '').trim() || (c.name ?? '').trim()
  if (!v || isBareId(v) || v.includes('@')) return false
  if (ORDERS_NAME.test(v) || textIsBilling(v)) return false
  return /[a-z]{2,}/i.test(v)
}

/** Seven digits is the shortest thing worth dialling. */
export function hasPhone(c: RankableContact): boolean {
  return (c.phone ?? '').replace(/\D/g, '').length >= 7
}

/** A number the rep may dial: present, and not marked do-not-call. */
export function isCallable(c: RankableContact): boolean {
  return hasPhone(c) && c.do_not_call !== true
}

const BUYER_TITLE = /buy|purchas|owner|manag|\bgm\b|general\s+manager|president|principal|proprietor/i

/* -------------------------------------------------------------- rank */

/** Where one contact lands. See CONTACT_KINDS for the order. */
export function contactKind(c: RankableContact, opts: BillingContext = {}): ContactKind {
  if (c.source === 'rep' && c.is_primary === true) return 'rep-primary'
  if (isBillingContact(c, opts)) return 'billing'
  if (isInternalContact(c)) return 'internal'
  const callable = isCallable(c)
  if (isOrdersMailbox(c)) return callable ? 'orders-callable' : 'orders'
  if (callable) return BUYER_TITLE.test(c.title ?? '') ? 'buyer' : 'callable'
  return hasPhone(c) ? 'do-not-call' : 'no-phone'
}

const KIND_ORDER = new Map(CONTACT_KINDS.map((k, i) => [k, i] as const))

function compareRanked(a: RankedContact, b: RankedContact): number {
  const byKind = KIND_ORDER.get(a.kind)! - KIND_ORDER.get(b.kind)!
  if (byKind) return byKind
  // Several rep primaries: the one touched last is the rep's current answer.
  if (a.kind === 'rep-primary') {
    const byUpdated = (b.updated_at ?? '').localeCompare(a.updated_at ?? '')
    if (byUpdated) return byUpdated
  }
  // Within a kind the ERP's own primary flag is still a signal; then the
  // rep's own entries (fresher than the ERP), then a real name over an id.
  const byPrimary = Number(b.is_primary === true) - Number(a.is_primary === true)
  if (byPrimary) return byPrimary
  const bySource = Number(b.source === 'rep') - Number(a.source === 'rep')
  if (bySource) return bySource
  const byNamed = Number(hasPersonName(b)) - Number(hasPersonName(a))
  if (byNamed) return byNamed
  const byLabel = a.label.localeCompare(b.label, 'en', { sensitivity: 'base' })
  if (byLabel) return byLabel
  return (a.contact_key ?? '').localeCompare(b.contact_key ?? '')
}

/**
 * Every contact, best to call first, each annotated with kind / label /
 * callable. Deterministic: the same rows in any order rank identically.
 * Billing rows are kept (last), so a UI can still show them grouped.
 */
export function rankContacts<T extends RankableContact>(
  list: readonly T[] | null | undefined,
  opts: BillingContext = {},
): RankedContact<T>[] {
  return (list ?? [])
    .map(
      (c) =>
        ({
          ...c,
          kind: contactKind(c, opts),
          label: contactDisplayName(c),
          callable: isCallable(c),
        }) as RankedContact<T>,
    )
    .sort(compareRanked)
}

/**
 * The one contact to put in a header: the top-ranked row that is neither
 * billing nor internal. `callable` is true only when it has a phone and the
 * ERP does not forbid calling it. contact null → "No buyer number on file".
 */
export function bestContact<T extends RankableContact>(
  list: readonly T[] | null | undefined,
  opts: BillingContext = {},
): BestContact<T> {
  const top = rankContacts(list, opts).find(
    (c) => c.kind !== 'billing' && c.kind !== 'internal',
  )
  if (!top) return { contact: null, callable: false, reason: 'none' }
  return { contact: top, callable: top.callable, reason: top.kind }
}
