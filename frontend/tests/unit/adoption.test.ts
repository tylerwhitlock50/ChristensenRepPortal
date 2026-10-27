/**
 * Unit tests for lib/adoption.ts — Admin › Users "Not signed in yet" (the
 * poke).
 *
 * Run with:  npm run test:unit -- adoption
 *
 * Pinned: who is listed (active reps only — never admins, order entry or
 * deactivated users), the two modes, the reminder draft (the portal link,
 * "Forgot your password?", first names, and never a password), and the
 * de-duplicated address list for "Copy emails".
 */
import {
  emailList,
  firstName,
  NOT_SIGNED_IN_DAYS,
  notSignedIn,
  reminderMailto,
  type AdoptionProfile,
} from '../../src/lib/adoption'

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

const now = new Date('2026-10-26T16:00:00Z')
const daysAgoIso = (d: number) => new Date(now.getTime() - d * 86_400_000).toISOString()

const profiles: AdoptionProfile[] = [
  { user_id: 'u-never', full_name: 'Jim Hall', email: 'jim@example.com', role: 'rep', active: true },
  { user_id: 'u-quiet', full_name: 'Ann Lee', email: 'ann@example.com', role: 'rep', active: true },
  { user_id: 'u-recent', full_name: 'Bo Diaz', email: 'bo@example.com', role: 'rep', active: true },
  { user_id: 'u-quieter', full_name: 'Cy Fox', email: 'cy@example.com', role: 'rep', active: true },
  { user_id: 'u-admin', full_name: 'Tyler W', email: 'tyler@example.com', role: 'admin', active: true },
  { user_id: 'u-entry', full_name: 'Order Desk', email: 'desk@example.com', role: 'order_entry', active: true },
  { user_id: 'u-gone', full_name: 'Old Rep', email: 'old@example.com', role: 'rep', active: false },
  { user_id: 'u-never-2', full_name: 'Al Ames', email: 'JIM@example.com', role: 'rep', active: true },
]
const lastLogin = {
  'u-quiet': daysAgoIso(20),
  'u-recent': daysAgoIso(2),
  'u-quieter': daysAgoIso(40),
  'u-admin': null,
}

t('14 days is the "quiet" line', NOT_SIGNED_IN_DAYS, 14)
t(
  'never: active reps with no sign-in at all, by name',
  notSignedIn(profiles, lastLogin, 'never', now).map((r) => r.user_id),
  ['u-never-2', 'u-never'],
)
t(
  '14+ days: never first, then the longest quiet',
  notSignedIn(profiles, lastLogin, 'stale', now).map((r) => r.user_id),
  ['u-never-2', 'u-never', 'u-quieter', 'u-quiet'],
)
t(
  'admins, order entry and deactivated users are never listed',
  notSignedIn(profiles, lastLogin, 'stale', now).some((r) =>
    ['u-admin', 'u-entry', 'u-gone'].includes(r.user_id),
  ),
  false,
)
t(
  'the last sign-in rides along',
  notSignedIn(profiles, lastLogin, 'stale', now).find((r) => r.user_id === 'u-quiet')?.last_login_at,
  daysAgoIso(20),
)

t('first name', firstName('  Jayelynne   Thompson '), 'Jayelynne')
t('first name fallback', firstName(null, 'there'), 'there')

const href = reminderMailto({ full_name: 'Jim Hall', email: 'jim@example.com' }, 'Jayelynne T', 'https://portal.example.com')
const [to, query] = href.replace(/^mailto:/, '').split('?')
const params = new URLSearchParams(query)
const body = params.get('body') ?? ''
t('addressed to the rep', decodeURIComponent(to!), 'jim@example.com')
t('a subject', (params.get('subject') ?? '').length > 0, true)
t('greets them by first name', body.startsWith('Hi Jim,'), true)
t('carries the portal link', body.includes('https://portal.example.com'), true)
t('points at Forgot your password', body.includes('"Forgot your password?"'), true)
t('signed with the admin\'s first name', body.trimEnd().endsWith('Thanks,\nJayelynne'), true)
t('never a password in it', /password:/i.test(body), false)
t(
  'a rep with no name still gets a greeting',
  new URLSearchParams(reminderMailto({ full_name: null, email: 'x@example.com' }, '', 'u').split('?')[1])
    .get('body')
    ?.startsWith('Hi there,'),
  true,
)

t(
  'copy emails: once each (case-insensitive), "; "-separated, blanks dropped',
  emailList([{ email: 'jim@example.com' }, { email: null }, { email: 'JIM@example.com' }, { email: ' ann@example.com ' }]),
  'jim@example.com; ann@example.com',
)
t('copy emails: nobody, nothing', emailList([]), '')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
