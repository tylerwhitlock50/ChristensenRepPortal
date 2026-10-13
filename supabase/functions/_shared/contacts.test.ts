/*============================================================================
  contacts.test.ts — the Edge Functions' copy of the contact ranking still
  ranks exactly like the frontend's.

      deno test --allow-env supabase/functions/

  _shared/contacts.ts is a copy of frontend/src/lib/contacts.ts (see its
  header for why). This imports both and runs the same awkward contact
  lists through each; a difference means someone edited one and not the
  other. The frontend's own rules are tested in
  frontend/tests/unit/contacts.test.ts — this file only checks the copy.
============================================================================*/

import * as copy from './contacts.ts'
import * as frontend from '../../../frontend/src/lib/contacts.ts'

function assertEquals(got: unknown, want: unknown, what: string): void {
  const g = JSON.stringify(got)
  const w = JSON.stringify(want)
  if (g !== w) throw new Error(`FAILED: ${what}\n  copy:     ${g}\n  frontend: ${w}`)
}

const dealer: copy.RankableContact[] = [
  // The real-world shape: the ERP primary is the AP mailbox, with no phone.
  { contact_key: 'erp-1', source: 'erp', name: 'INVOICE', email: 'importinvoice@dealer.com', is_primary: true },
  { contact_key: 'erp-2', source: 'erp', name: '0027284', display_name: 'Dana Buyer', title: 'Firearms Buyer', phone: '(406) 555-0142', email: 'dana@dealer.com' },
  { contact_key: 'erp-3', source: 'erp', name: 'Pat Owner', title: 'Owner', phone: '406-555-0100', do_not_call: true },
  { contact_key: 'erp-4', source: 'erp', name: 'Orders', email: 'orders@dealer.com', phone: '406 555 0199' },
  { contact_key: 'erp-5', source: 'erp', name: 'Casey AR', email: 'casey@christensenarms.com', phone: '435-555-0101' },
  { contact_key: 'erp-6', source: 'erp', name: 'Purchasing / AP', phone: '406-555-0177', email: 'ap@dealer.com' },
  { contact_key: 'erp-7', source: 'erp', name: 'Sam Lee', email: 'statements@dealer.com' },
  { contact_key: 'erp-8', source: 'erp', name: 'Billings Gun Club', phone: '406-555-0111' },
]
const withRepPrimary: copy.RankableContact[] = [
  ...dealer,
  { contact_key: 'rep-9', source: 'rep', name: 'Jordan (counter)', phone: '406-555-0123', is_primary: true, updated_at: '2026-09-01T00:00:00Z' },
]
const billing = { invoiceEmail: 'importinvoice@dealer.com; ap@dealer.com', statementEmail: 'statements@dealer.com' }

const cases: Array<[string, copy.RankableContact[], copy.BillingContext]> = [
  ['an ERP book with an AP primary', dealer, {}],
  ['with the account billing addresses', dealer, billing],
  ['with a rep-entered primary', withRepPrimary, billing],
  ['the same rows reversed', [...withRepPrimary].reverse(), billing],
  ['nobody to call', [dealer[0], dealer[6]], billing],
  ['no rows', [], {}],
]

for (const [label, list, opts] of cases) {
  Deno.test(`copy ranks like the frontend: ${label}`, () => {
    assertEquals(copy.rankContacts(list, opts), frontend.rankContacts(list, opts), 'rankContacts')
    assertEquals(copy.bestContact(list, opts), frontend.bestContact(list, opts), 'bestContact')
    for (const c of list) {
      assertEquals(copy.contactKind(c, opts), frontend.contactKind(c, opts), `contactKind ${JSON.stringify(c)}`)
      assertEquals(copy.contactDisplayName(c), frontend.contactDisplayName(c), 'contactDisplayName')
    }
  })
}

Deno.test('the copy exports what the frontend exports', () => {
  assertEquals(Object.keys(copy).sort(), Object.keys(frontend).sort(), 'export names')
  assertEquals(copy.CONTACT_KINDS, frontend.CONTACT_KINDS, 'CONTACT_KINDS order')
})
