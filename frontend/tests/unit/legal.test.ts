/**
 * Unit tests for lib/legal.ts: reading legal_status() and
 * legal_current_documents() defensively, which documents still need
 * agreeing to, where the agreement screen may send someone afterwards, and
 * the per-device "agreed last time we could check" stamp the offline open
 * relies on.
 *
 * Run with:  npm run test:unit -- legal
 */
import { renderMarkdown } from '../../src/lib/markdown'
import { pageViewFor } from '../../src/lib/usage'
import {
  agreedOnThisDevice,
  documentsToAgree,
  isMissingLegalStatusFunction,
  isUpdatedSinceAgreed,
  legalErrorMessage,
  NO_LEGAL_REQUIREMENT,
  parseLegalDocuments,
  parseLegalStatus,
  rememberLegalStatus,
  safeRedirect,
  type LegalDocument,
} from '../../src/lib/legal'

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

/* ---- a localStorage for Node ------------------------------------------- */
const store = new Map<string, string>()
;(globalThis as { localStorage?: unknown }).localStorage = {
  getItem: (k: string) => (store.has(k) ? store.get(k)! : null),
  setItem: (k: string, v: string) => void store.set(k, String(v)),
  removeItem: (k: string) => void store.delete(k),
}

const entry = (over: Record<string, unknown> = {}) => ({
  document_id: 11,
  doc_key: 'terms',
  version: '2026-11-24',
  title: 'Terms of Use',
  effective_at: '2026-11-24T00:00:00Z',
  content_sha256: 'abc',
  accepted_at: null,
  last_accepted_version: null,
  last_accepted_at: null,
  ...over,
})

/* ---- parseLegalStatus ---------------------------------------------------- */
t('null is not a status', parseLegalStatus(null), null)
t('a string is not a status', parseLegalStatus('yes'), null)
t('documents must be a list', parseLegalStatus({ documents: {}, all_accepted: true }), null)
t(
  'a malformed entry spoils the whole answer',
  parseLegalStatus({ documents: [entry({ doc_key: 'cookies' })], all_accepted: true }),
  null,
)
t(
  'nothing published is agreed',
  parseLegalStatus({ documents: [], all_accepted: true }),
  { documents: [], all_accepted: true },
)
t(
  'all_accepted is not trusted over the entries',
  parseLegalStatus({ documents: [entry()], all_accepted: true })?.all_accepted,
  false,
)
t(
  'an absent all_accepted is not agreement',
  parseLegalStatus({ documents: [entry({ accepted_at: '2026-11-24T10:00:00Z' })] })?.all_accepted,
  false,
)
t(
  'both agreed reads as agreed',
  parseLegalStatus({
    documents: [
      entry({ accepted_at: '2026-11-24T10:00:00Z' }),
      entry({ document_id: 12, doc_key: 'privacy', title: 'Privacy Policy', accepted_at: '2026-11-24T10:00:00Z' }),
    ],
    all_accepted: true,
  })?.all_accepted,
  true,
)
t('ids come back as numbers', parseLegalStatus({ documents: [entry({ document_id: '11' })], all_accepted: false })?.documents[0].document_id, 11)
t('NO_LEGAL_REQUIREMENT lets people in', NO_LEGAL_REQUIREMENT.all_accepted, true)

/* ---- parseLegalDocuments ------------------------------------------------- */
const doc = (over: Record<string, unknown> = {}) => ({
  id: 11,
  doc_key: 'terms',
  version: '2026-11-24',
  title: 'Terms of Use',
  summary: null,
  body_md: '## 1. Hello',
  effective_at: '2026-11-24T00:00:00Z',
  content_sha256: 'abc',
  ...over,
})
t('not a list → nothing', parseLegalDocuments({ id: 1 }), [])
t(
  'terms first, junk dropped',
  parseLegalDocuments([
    doc({ id: 12, doc_key: 'privacy', title: 'Privacy Policy' }),
    doc({ id: 99, doc_key: 'other' }),
    doc({ id: 98, body_md: '' }),
    doc(),
  ]).map((d) => d.id),
  [11, 12],
)

/* ---- documentsToAgree ----------------------------------------------------- */
const docs = parseLegalDocuments([doc(), doc({ id: 12, doc_key: 'privacy', title: 'Privacy Policy' })]) as LegalDocument[]
t('no status yet: everything is outstanding', documentsToAgree(docs, null).map((d) => d.id), [11, 12])
t(
  'one agreed, one not',
  documentsToAgree(
    docs,
    parseLegalStatus({
      documents: [entry({ accepted_at: '2026-11-24T10:00:00Z' }), entry({ document_id: 12, doc_key: 'privacy' })],
      all_accepted: false,
    }),
  ).map((d) => d.id),
  [12],
)
t(
  'a version newer than the status is outstanding even if the key was agreed',
  documentsToAgree(
    [doc({ id: 13 })],
    parseLegalStatus({ documents: [entry({ accepted_at: '2026-11-24T10:00:00Z' })], all_accepted: true }),
  ).map((d) => d.id),
  [13],
)

/* ---- isUpdatedSinceAgreed ------------------------------------------------- */
t('never agreed is not an update', isUpdatedSinceAgreed(parseLegalStatus({ documents: [entry()], all_accepted: false })!.documents[0]), false)
t(
  'agreed to an older version is an update',
  isUpdatedSinceAgreed(
    parseLegalStatus({
      documents: [entry({ last_accepted_version: '2026-01-01', last_accepted_at: '2026-01-02T00:00:00Z' })],
      all_accepted: false,
    })!.documents[0],
  ),
  true,
)
t('nothing is not an update', isUpdatedSinceAgreed(undefined), false)

/* ---- safeRedirect ---------------------------------------------------------- */
t('an app path goes through', safeRedirect('/accounts/VECA%7C1?tab=orders'), '/accounts/VECA%7C1?tab=orders')
t('the consent screen keeps its query', safeRedirect('/oauth/consent?authorization_id=abc'), '/oauth/consent?authorization_id=abc')
t('nothing → overview', safeRedirect(undefined), '/')
t('another origin → overview', safeRedirect('https://evil.test/'), '/')
t('protocol-relative → overview', safeRedirect('//evil.test/x'), '/')
t('backslash trick → overview', safeRedirect('/\\evil.test'), '/')
t('never back to itself', safeRedirect('/agreements?redirect=/'), '/')
t('but a path that merely starts alike is fine', safeRedirect('/agreementsfoo'), '/agreementsfoo')
t('first of a repeated query param', safeRedirect(['/lookup', '/x']), '/lookup')

/* ---- legalErrorMessage ------------------------------------------------------ */
t(
  'a stale version says so',
  legalErrorMessage({ message: 'legal_document_not_current: a newer version' }).startsWith('These documents were updated'),
  true,
)
t('a deactivated account says so', legalErrorMessage({ message: 'inactive_profile: …' }).includes('deactivated'), true)
t('no signal says so', legalErrorMessage(new TypeError('Failed to fetch')).startsWith('No connection'), true)

/* ---- only legal_status() itself missing opens the gate ------------------------ */
t('PGRST202 for legal_status opens', isMissingLegalStatusFunction({ code: 'PGRST202', message: 'Could not find the function public.legal_status without parameters in the schema cache' }), true)
t('PGRST202 for another function does not', isMissingLegalStatusFunction({ code: 'PGRST202', message: 'Could not find the function public.other' }), false)
t('42883 naming legal_status opens', isMissingLegalStatusFunction({ code: '42883', message: 'function public.legal_status() does not exist' }), true)
t('42883 for a function it calls stays shut', isMissingLegalStatusFunction({ code: '42883', message: 'function public.legal_current_documents() does not exist' }), false)
t('a missing column stays shut', isMissingLegalStatusFunction({ code: '42703', message: 'column a.doc_key does not exist' }), false)
t('a missing table stays shut', isMissingLegalStatusFunction({ code: '42P01', message: 'relation "public.legal_acceptances" does not exist' }), false)
t('no signal stays shut', isMissingLegalStatusFunction(new TypeError('Failed to fetch')), false)

/* ---- the agreement screen is not use of the portal ---------------------------- */
t('agreements is not a page view', pageViewFor({ name: 'agreements', params: {}, meta: { untracked: true } }), null)
t('the consent screen still is', pageViewFor({ name: 'oauth-consent', params: {}, meta: {} })?.page, 'oauth-consent')

/* ---- numbered clauses keep their numbers -------------------------------------- */
t(
  'a list after a paragraph starts at its own number',
  renderMarkdown('1. First\n\nA paragraph.\n\n7. Seventh\n8. Eighth'),
  '<ol><li>First</li></ol>\n<p>A paragraph.</p>\n<ol start="7"><li>Seventh</li><li>Eighth</li></ol>',
)
t('lazy 1. 1. numbering still counts up', renderMarkdown('1. a\n1. b'), '<ol><li>a</li><li>b</li></ol>')
t('#### renders as a heading, not text', renderMarkdown('#### 7.1 Scope'), '<h4>7.1 Scope</h4>')

/* ---- the device stamp -------------------------------------------------------- */
const agreed = parseLegalStatus({
  documents: [
    entry({ accepted_at: '2026-11-24T10:00:00Z' }),
    entry({ document_id: 12, doc_key: 'privacy', accepted_at: '2026-11-24T10:00:00Z' }),
  ],
  all_accepted: true,
})!
const notAgreed = parseLegalStatus({ documents: [entry()], all_accepted: false })!
t('nothing remembered for a stranger', agreedOnThisDevice('u1'), false)
rememberLegalStatus('u1', agreed)
t('remembered after agreeing', agreedOnThisDevice('u1'), true)
t('per user', agreedOnThisDevice('u2'), false)
t('only versions and a time are kept', Object.keys(JSON.parse(store.get('rep-portal:legal-accepted:u1')!)).sort(), ['at', 'versions'])
rememberLegalStatus('u1', notAgreed)
t('forgotten when a check says otherwise', agreedOnThisDevice('u1'), false)
store.set('rep-portal:legal-accepted:u3', '{not json')
t('a corrupt stamp is not agreement', agreedOnThisDevice('u3'), false)
;(globalThis as { localStorage?: unknown }).localStorage = {
  getItem: () => {
    throw new Error('blocked')
  },
  setItem: () => {
    throw new Error('blocked')
  },
  removeItem: () => {
    throw new Error('blocked')
  },
}
rememberLegalStatus('u1', agreed)
t('blocked storage: never throws, never agrees', agreedOnThisDevice('u1'), false)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
