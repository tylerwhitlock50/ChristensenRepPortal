/**
 * Unit tests for lib/contacts.ts — who to ring at a dealer.
 *
 * Run with:  npm run test:unit
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. The rows below are shaped on what live list_contacts returned for
 * sampled dealers: an 'INVOICE' ERP primary with no phone above the real
 * buyer, buyers stored under a bare contact id, our own staff listed as a
 * dealer's contacts, and accounts with no phone on any row.
 */
import {
  bestContact,
  contactDisplayName,
  contactKind,
  isBillingContact,
  isInternalContact,
  isOrdersMailbox,
  rankContacts,
  type RankableContact,
} from '../../src/lib/contacts'

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

function erp(key: string, over: Partial<RankableContact>): RankableContact {
  return {
    contact_key: `erp-${key}`,
    source: 'erp',
    name: null,
    title: null,
    phone: null,
    email: null,
    is_primary: null,
    do_not_call: false,
    ...over,
  }
}

function rep(id: number, over: Partial<RankableContact>): RankableContact {
  return {
    contact_key: `rep-${id}`,
    source: 'rep',
    name: null,
    title: null,
    phone: null,
    email: null,
    is_primary: false,
    do_not_call: false,
    updated_at: '2026-10-01T00:00:00Z',
    ...over,
  }
}

const keys = (list: { contact_key?: string | null }[]) => list.map((c) => c.contact_key)

/* --- the INVOICE primary (the bug this file exists for) ------------------ */
const invoicePrimary = erp('inv', {
  name: 'INVOICE',
  email: 'IMPORTINVOICE@HQ.SPORTSINC.COM',
  is_primary: true,
})
const buyer = erp('buyer', {
  name: 'Dana Fox',
  title: 'Firearms Buyer',
  phone: '(406) 555-0101',
  email: 'dfox@dealer.com',
})
const clerk = erp('clerk', { name: 'Sam Lee', phone: '406-555-0102' })
const dealer = [invoicePrimary, clerk, buyer]

t('INVOICE name is billing', isBillingContact(invoicePrimary), true)
t('buyer is not billing', isBillingContact(buyer), false)
t('INVOICE primary ranks last', keys(rankContacts(dealer)).at(-1), 'erp-inv')
t(
  'buyer title ranks above a plain callable person',
  keys(rankContacts(dealer)),
  ['erp-buyer', 'erp-clerk', 'erp-inv'],
)
t('best contact is the buyer', bestContact(dealer).contact?.contact_key, 'erp-buyer')
t('and is callable', bestContact(dealer).callable, true)
t('reason says why', bestContact(dealer).reason, 'buyer')
t(
  'order of input does not matter',
  keys(rankContacts([buyer, invoicePrimary, clerk])),
  keys(rankContacts([clerk, buyer, invoicePrimary])),
)
t(
  'an INVOICE primary alone is not a best contact',
  bestContact([invoicePrimary]),
  { contact: null, callable: false, reason: 'none' },
)

/* --- billing signals ------------------------------------------------------ */
t('INVOICES', isBillingContact(erp('a', { name: 'INVOICES' })), true)
t('AP', isBillingContact(erp('a', { name: 'AP' })), true)
t('A/P', isBillingContact(erp('a', { name: 'A/P Dept' })), true)
t('Accounts Payable title', isBillingContact(erp('a', { title: 'Accounts Payable' })), true)
t('BILLING', isBillingContact(erp('a', { name: 'BILLING' })), true)
t('statements', isBillingContact(erp('a', { name: 'Statements' })), true)
t('AR', isBillingContact(erp('a', { name: 'AR' })), true)
t('ap@ local part', isBillingContact(erp('a', { name: 'Kim', email: 'ap@dealer.com' })), true)
t('accountspayable@', isBillingContact(erp('a', { email: 'accountspayable@d.com' })), true)
t('accounting@', isBillingContact(erp('a', { email: 'accounting@d.com' })), true)
t('"Apex" is not AP', isBillingContact(erp('a', { name: 'Apex Outdoors' })), false)
t('"AR-15 buyer" is not AR', isBillingContact(erp('a', { title: 'AR-15 buyer' })), false)
t('"Bill Smith" is not billing', isBillingContact(erp('a', { name: 'Bill Smith' })), false)
t('AP/AR is two billing tokens, not one glued word', isBillingContact(erp('a', { title: 'AP/AR' })), true)
t('Accounting/AP', isBillingContact(erp('a', { name: 'Kim', title: 'Accounting/AP' })), true)
t('a/r spelled with spaces', isBillingContact(erp('a', { title: 'A / R clerk' })), true)
t('AP Manager stays billing ("manag" is not a buying role)', isBillingContact(erp('a', { name: 'Kim', title: 'AP Manager' })), true)
t('Accounting Manager stays billing', isBillingContact(erp('a', { name: 'Kim', title: 'Accounting Manager' })), true)

/* --- real buyers the patterns must not catch ----------------------------- */
t('"APRIL" is not AP', isBillingContact(erp('a', { name: 'APRIL', phone: '555-555-0140' })), false)
t('"April Jones" is not AP', isBillingContact(erp('a', { name: 'April Jones' })), false)
t('"Snap" is not AP', isBillingContact(erp('a', { name: 'Snap' })), false)
t('"Billings Sporting Goods" is not billing', isBillingContact(erp('a', { name: 'Billings Sporting Goods' })), false)
t(
  'a surname Billings in the email is not billing',
  isBillingContact(erp('a', { name: 'Tom Billings', email: 'tbillings@shop.com' })),
  false,
)
t('a Billings, MT shop address is not billing', isBillingContact(erp('a', { email: 'billingsguns@gmail.com' })), false)
t('but billing@ still is', isBillingContact(erp('a', { email: 'billing@shop.com' })), true)
t('and billingdept@ still is', isBillingContact(erp('a', { email: 'billingdept@shop.com' })), true)

/* --- one person, both jobs: the buying half wins ------------------------- */
t(
  '"Purchasing / AP" is the buyer, not billing',
  contactKind(erp('a', { name: 'Kim Lee', title: 'Purchasing / AP', phone: '555-555-0150' })),
  'buyer',
)
t('"Owner/Accounting" is the buyer', contactKind(erp('a', { name: 'Kim Lee', title: 'Owner/Accounting', phone: '555-555-0151' })), 'buyer')
t('"Buyer & A/P" is the buyer', contactKind(erp('a', { name: 'Kim Lee', title: 'Buyer & A/P', phone: '555-555-0152' })), 'buyer')
t(
  'an owner reading the ap@ inbox is still the buyer',
  contactKind(erp('a', { name: 'Pat Lee', title: 'Owner', email: 'ap@shop.com', phone: '555-555-0153' })),
  'buyer',
)
t(
  'a buying title on another field does not rescue an INVOICES name',
  isBillingContact(erp('a', { name: 'INVOICES', title: 'Purchasing' })),
  true,
)
t(
  '"invoice" is never rescued by a buying role',
  isBillingContact(erp('a', { name: 'Kim Lee', title: 'Purchasing / Invoices', phone: '555-555-0154' })),
  true,
)
t(
  'nor is an invoices@ inbox',
  isBillingContact(erp('a', { name: 'Pat Lee', title: 'Owner', email: 'invoices@shop.com' })),
  true,
)
t('a BUYING GROUP AP row is billing (the co-op pays, it does not buy)', isBillingContact(erp('a', { name: 'BUYING GROUP AP' })), true)
t(
  'a PURCHASING / AP mailbox is not billing (it reaches the buyer too)',
  isBillingContact(erp('a', { name: 'PURCHASING / AP', email: 'purchasing@shop.com' })),
  false,
)
t(
  'email equal to invoice_email is billing',
  isBillingContact(erp('a', { name: '0018901', email: 'payments@dealer.com' }), {
    invoiceEmail: 'Payments@Dealer.com',
  }),
  true,
)
t(
  'statement_email in a list is billing',
  isBillingContact(erp('a', { email: 'x@dealer.com' }), {
    statementEmail: 'y@dealer.com; x@dealer.com',
  }),
  true,
)
t(
  'small shop: a named owner with a phone on the invoice address stays a person',
  isBillingContact(erp('a', { name: 'Pat Owner', phone: '555-555-0100', email: 'pat@shop.com' }), {
    invoiceEmail: 'pat@shop.com',
  }),
  false,
)

/* --- rep override --------------------------------------------------------- */
const repPrimary = rep(7, { name: 'Tucker', is_primary: true })
const withRep = [invoicePrimary, buyer, repPrimary]
t(
  'rep primary beats an ERP INVOICE primary that would win on name',
  keys(rankContacts(withRep))[0],
  'rep-7',
)
t('rep primary is the best contact even with no phone', bestContact(withRep).contact?.contact_key, 'rep-7')
t('but is not callable without a phone', bestContact(withRep).callable, false)
t('reason rep-primary', bestContact(withRep).reason, 'rep-primary')
t(
  'two rep primaries: the most recently updated wins',
  keys(
    rankContacts([
      rep(1, { name: 'Old', is_primary: true, updated_at: '2026-01-01T00:00:00Z' }),
      rep(2, { name: 'New', is_primary: true, updated_at: '2026-09-01T00:00:00Z' }),
    ]),
  )[0],
  'rep-2',
)
t(
  'an ERP primary is not a rep override',
  contactKind(erp('p', { name: 'Jo', is_primary: true, phone: '5555550100' })),
  'callable',
)

/* --- do not call ---------------------------------------------------------- */
const dnc = erp('dnc', { name: 'Alex Buyer', title: 'Buyer', phone: '555-555-0111', do_not_call: true })
const noPhone = erp('nophone', { name: 'Robin', email: 'robin@d.com' })
t('do-not-call ranks below a callable person', keys(rankContacts([dnc, clerk])), ['erp-clerk', 'erp-dnc'])
t('do-not-call ranks above no phone', keys(rankContacts([noPhone, dnc])), ['erp-dnc', 'erp-nophone'])
t('a do-not-call best contact is not callable', bestContact([dnc]).callable, false)
t('and says so', bestContact([dnc]).reason, 'do-not-call')
t('a 3-digit "phone" is no phone', contactKind(erp('x', { name: 'Lee', phone: '411' })), 'no-phone')

/* --- internal ------------------------------------------------------------- */
const staff = erp('staff', {
  name: 'TYLER WHITLOCK',
  phone: '435-555-0100',
  email: 'tyler.whitlock@ChristensenArms.com',
})
t('our domain is internal', isInternalContact(staff), true)
t('a dealer domain is not', isInternalContact(buyer), false)
t('internal ranks after outside people', keys(rankContacts([staff, noPhone])), ['erp-nophone', 'erp-staff'])
t('internal is never the best contact', bestContact([staff]).contact, null)
t(
  'our Billing@ is billing, after internal',
  keys(rankContacts([erp('bill', { name: 'Billing', email: 'billing@christensenarms.com' }), staff])),
  ['erp-staff', 'erp-bill'],
)

/* --- orders mailboxes ----------------------------------------------------- */
const orders = erp('orders', { name: 'ORDERS', email: 'orders@dealer.com' })
const ordersPhone = erp('ordersph', { email: 'purchasing@dealer.com', phone: '555-555-0199' })
t('ORDERS name is a mailbox', isOrdersMailbox(orders), true)
t('purchasing@ with no name is a mailbox', isOrdersMailbox(ordersPhone), true)
t(
  'a named person on orders@ stays a person',
  isOrdersMailbox(erp('p', { name: 'Chris Park', email: 'orders@dealer.com' })),
  false,
)
t('orders mailbox ranks below a person with no phone', keys(rankContacts([orders, noPhone])), ['erp-nophone', 'erp-orders'])
t(
  'a callable orders line beats a person with no number',
  bestContact([noPhone, ordersPhone]).contact?.contact_key,
  'erp-ordersph',
)

/* --- names ---------------------------------------------------------------- */
t('display_name wins', contactDisplayName(erp('n', { name: '0027284', display_name: 'Dana Fox' })), 'Dana Fox')
t('name when no display_name', contactDisplayName(erp('n', { name: 'Dana Fox' })), 'Dana Fox')
t(
  'bare numeric id falls back to email',
  contactDisplayName(erp('n', { name: '0027284', email: 'dfox@dealer.com' })),
  'dfox@dealer.com',
)
t('bare id is the last resort', contactDisplayName(erp('n', { name: '0027284' })), '0027284')
t('nothing at all', contactDisplayName(erp('n', {})), 'Unnamed contact')
t(
  'an empty display_name falls through to name',
  contactDisplayName(erp('n', { name: '0027284', display_name: '' })),
  '0027284',
)
t(
  'an empty display_name does not hide an ORDERS name',
  isOrdersMailbox(erp('n', { name: 'ORDERS', display_name: '' })),
  true,
)
t(
  'a named contact outranks an id-only one at the same kind',
  keys(
    rankContacts([
      erp('id', { name: '0018901', phone: '555-555-0120' }),
      erp('named', { name: 'Zed Young', phone: '555-555-0121' }),
    ]),
  ),
  ['erp-named', 'erp-id'],
)
t(
  'ranked rows carry label and callable',
  (({ label, callable, kind }) => ({ label, callable, kind }))(
    rankContacts([erp('id', { name: '0027284', email: 'b@d.com', phone: '555-555-0130' })])[0]!,
  ),
  { label: 'b@d.com', callable: true, kind: 'callable' },
)

/* --- empty ---------------------------------------------------------------- */
t('empty list ranks to empty', rankContacts([]), [])
t('null list ranks to empty', rankContacts(null), [])
t('empty list has no best contact', bestContact([]), { contact: null, callable: false, reason: 'none' })
t(
  'no phone anywhere: best contact exists but is not callable',
  (({ contact, callable }) => ({ key: contact?.contact_key, callable }))(bestContact([noPhone, invoicePrimary])),
  { key: 'erp-nophone', callable: false },
)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
