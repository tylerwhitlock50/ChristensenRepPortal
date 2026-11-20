/**
 * Unit tests for lib/resources.ts — the rules around Resources
 * (public.rep_resources + the `rep-resources` bucket, 20261120120000) that
 * need no network: audiences, the object path, which files the bucket
 * takes, and how the page groups and filters.
 *
 * Run with:  npm run test:unit -- resources
 */
import {
  RESOURCE_ACCEPT,
  RESOURCE_MAX_BYTES,
  audienceColumns,
  audienceOf,
  audienceTag,
  categoryLabel,
  fileExtensionOf,
  groupResources,
  resourceContentType,
  resourceMatches,
  resourcePath,
  validateResourceFile,
  type ResourceRow,
} from '../../src/lib/resources'

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

function row(over: Partial<ResourceRow>): ResourceRow {
  return {
    id: 1,
    title: 'File',
    description: null,
    category: 'other',
    rep_group_vendor_id: null,
    customer_key: null,
    storage_path: 'other/x.pdf',
    file_name: 'x.pdf',
    content_type: 'application/pdf',
    file_size: 10,
    uploaded_by: null,
    uploaded_at: '2026-11-01T00:00:00Z',
    updated_at: '2026-11-01T00:00:00Z',
    ...over,
  }
}

/* ---- audiences ----------------------------------------------------------- */
t('no columns set is everyone', audienceOf(row({})), { kind: 'everyone' })
t('an agency id is one agency', audienceOf(row({ rep_group_vendor_id: 'PMI' })), {
  kind: 'agency',
  vendorId: 'PMI',
})
t('a customer key is one account', audienceOf(row({ customer_key: 'MIDWAY' })), {
  kind: 'account',
  customerKey: 'MIDWAY',
})

t('everyone stores two nulls', audienceColumns({ kind: 'everyone' }), {
  rep_group_vendor_id: null,
  customer_key: null,
})
t('an agency id is trimmed (the DB refuses a padded one)', audienceColumns({ kind: 'agency', vendorId: ' PMI ' }), {
  rep_group_vendor_id: 'PMI',
  customer_key: null,
})
t('an account stores only the key', audienceColumns({ kind: 'account', customerKey: 'MIDWAY' }), {
  rep_group_vendor_id: null,
  customer_key: 'MIDWAY',
})

const names = { MIDWAY: 'MidwayUSA' }
t('a rep sees no tag on an everyone file', audienceTag(row({}), names), null)
t('a rep sees "Your agency"', audienceTag(row({ rep_group_vendor_id: 'PMI' }), names), 'Your agency')
t('an account file is tagged with the account name', audienceTag(row({ customer_key: 'MIDWAY' }), names), 'For MidwayUSA')
t('falls back to the key without a name', audienceTag(row({ customer_key: 'OTHER' }), names), 'For OTHER')
t('an admin sees the agency id', audienceTag(row({ rep_group_vendor_id: 'PMI' }), names, true), 'Agency PMI')
t('an admin sees "Everyone"', audienceTag(row({}), names, true), 'Everyone')

/* ---- files ----------------------------------------------------------------- */
t('extension, lower-cased', fileExtensionOf('2027 Price List.XLSX'), 'xlsx')
t('no extension', fileExtensionOf('README'), '')
t('xlsx with an empty browser type still gets its MIME', resourceContentType({ name: 'a.xlsx', type: '' }),
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
t('octet-stream with a known extension goes by the extension', resourceContentType({ name: 'a.pdf', type: 'application/octet-stream' }),
  'application/pdf')
t('an unknown file is refused', resourceContentType({ name: 'a.exe', type: 'application/x-msdownload' }), null)
t('accept lists pdf and xlsx', RESOURCE_ACCEPT.includes('.pdf') && RESOURCE_ACCEPT.includes('.xlsx'), true)

t('a normal flyer passes', validateResourceFile({ name: 'flyer.pdf', size: 2_000_000 }), null)
t('an empty file is refused', validateResourceFile({ name: 'flyer.pdf', size: 0 }), 'That file is empty.')
t('over the bucket limit is refused', validateResourceFile({ name: 'big.pdf', size: RESOURCE_MAX_BYTES + 1 }),
  'That file is over 50 MB.')
t('an exe is refused', typeof validateResourceFile({ name: 'x.exe', size: 10 }), 'string')

t('path is category/uuid.ext', resourcePath('price_list', 'abc', 'Midway 2027.xlsx'), 'price_list/abc.xlsx')
t('an unknown category files under other', resourcePath('nope', 'abc', 'a.pdf'), 'other/abc.pdf')
t('no extension, no dot', resourcePath('other', 'abc', 'README'), 'other/abc')

/* ---- the page -------------------------------------------------------------- */
t('category labels', [categoryLabel('price_list'), categoryLabel('program'), categoryLabel('zzz')],
  ['Price lists', 'Programs', 'Other'])

const rows = [
  row({ id: 1, title: 'Rewards flyer', category: 'program', updated_at: '2026-11-10T00:00:00Z' }),
  row({ id: 2, title: '2027 Dealer', category: 'price_list', updated_at: '2026-11-15T00:00:00Z' }),
  row({ id: 3, title: 'Midway all SKU', category: 'price_list', customer_key: 'MIDWAY', updated_at: '2026-11-01T00:00:00Z' }),
  row({ id: 4, title: 'Agency 2027', category: 'price_list', rep_group_vendor_id: 'PMI', updated_at: '2026-11-20T00:00:00Z' }),
  row({ id: 5, title: 'Odd', category: 'legacy', updated_at: '2026-11-02T00:00:00Z' }),
]
const groups = groupResources(rows)
t('sections in the fixed order, empty ones dropped', groups.map((g) => g.label), ['Price lists', 'Programs', 'Other'])
t('account file, then agency file, then newest first', groups[0].files.map((r) => r.id), [3, 4, 2])
t('an unknown category lands in Other', groups[2].files.map((r) => r.id), [5])

t('empty search matches', resourceMatches(rows[0], '  ', names), true)
t('title match is case-blind', resourceMatches(rows[0], 'REWARDS', names), true)
t('an account file is found by the account name', resourceMatches(rows[2], 'midwayusa', names), true)
t('a miss is a miss', resourceMatches(rows[0], 'midway', names), false)
t('category words match', resourceMatches(rows[1], 'price list', names), true)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail) process.exit(1)
