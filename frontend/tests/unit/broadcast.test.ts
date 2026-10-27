/**
 * Unit tests for lib/broadcast.ts — Admin › Users "Email a group".
 *
 * Run with:  npm run test:unit -- broadcast
 *
 * Pinned: each audience (everyone, principals, one rep group — principals by
 * their own vendor, reps by dim_sales_rep — and one rep), that inactive and
 * email-less users never make the list, and the mailto: (sender on To, the
 * rest on Bcc once each, the sender not twice).
 */
import {
  bccMailto,
  groupOf,
  recipients,
  repGroups,
  type BroadcastProfile,
} from '../../src/lib/broadcast'

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

const p = (
  user_id: string,
  full_name: string,
  extra: Partial<BroadcastProfile> = {},
): BroadcastProfile => ({
  user_id,
  full_name,
  email: `${user_id}@example.com`,
  role: 'rep',
  active: true,
  sales_rep_key: null,
  rep_group_vendor_id: null,
  ...extra,
})

const profiles: BroadcastProfile[] = [
  p('admin', 'Tyler Admin', { role: 'admin' }),
  p('boss', 'Pat Principal', { rep_group_vendor_id: 'ACME' }),
  p('jim', 'Jim Hall', { sales_rep_key: 'R1' }),
  p('ann', 'Ann Lee', { sales_rep_key: 'R2' }),
  p('solo', 'Sam Solo', { sales_rep_key: 'R9' }),
  p('gone', 'Gone Rep', { sales_rep_key: 'R1', active: false }),
  p('nomail', 'No Mail', { sales_rep_key: 'R1', email: null }),
  p('oe', 'Olive Entry', { role: 'order_entry' }),
]
const vendors = { R1: 'ACME', R2: 'BETA', R9: null }
const ids = (rows: BroadcastProfile[]) => rows.map((r) => r.user_id)

t('group: a principal is in the group they run', groupOf(profiles[1]!, vendors), 'ACME')
t('group: a rep is in their rep code\'s vendor', groupOf(profiles[2]!, vendors), 'ACME')
t('group: no vendor, no group', groupOf(profiles[4]!, vendors), null)

t(
  'everyone: active with an email, by name',
  ids(recipients(profiles, 'everyone', '', vendors)),
  ['ann', 'jim', 'oe', 'boss', 'solo', 'admin'],
)
t('principals: only reps carrying a vendor', ids(recipients(profiles, 'principals', '', vendors)), ['boss'])
t('group ACME: principal + its reps, not the inactive or email-less', ids(recipients(profiles, 'group', 'ACME', vendors)), ['jim', 'boss'])
t('group: none picked, nobody', ids(recipients(profiles, 'group', '', vendors)), [])
t('rep: just that one', ids(recipients(profiles, 'rep', 'ann', vendors)), ['ann'])
t('rep: an inactive one is not draftable', ids(recipients(profiles, 'rep', 'gone', vendors)), [])

t('group list: counts active-with-email only', repGroups(profiles, vendors), [
  { vendor_id: 'ACME', count: 2 },
  { vendor_id: 'BETA', count: 1 },
])

t(
  'mailto: sender on To, rest on Bcc once each, sender not repeated',
  bccMailto(
    [{ email: 'admin@example.com' }, { email: 'jim@example.com' }, { email: 'JIM@example.com' }, { email: 'ann@example.com' }],
    'Admin@example.com',
  ),
  'mailto:Admin%40example.com?bcc=jim%40example.com,ann%40example.com',
)
t('mailto: nobody else, no bcc', bccMailto([], 'a@example.com'), 'mailto:a%40example.com')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
