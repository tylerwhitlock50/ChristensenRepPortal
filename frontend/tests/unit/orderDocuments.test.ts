/**
 * Unit tests for lib/orderDocuments.ts — the naming and file rules around
 * the `order-documents` bucket (20261113090000). The bucket's RLS reads the
 * first path segment as the order id, so the path shape is pinned here.
 *
 * Run with:  npm run test:unit -- orderDocuments
 */
import {
  ORDER_DOCUMENT_ACCEPT,
  ORDER_DOCUMENT_MAX_BYTES,
  ORDER_DOCUMENT_TYPES,
  canOfferRemove,
  documentDisplayName,
  documentErrorText,
  documentStampedAt,
  fileExtension,
  formatFileSize,
  isBucketMissing,
  opensInBrowser,
  orderDocumentFolder,
  orderDocumentPath,
  sanitizeDocumentName,
  toOrderDocuments,
  validateDocumentFile,
} from '../../src/lib/orderDocuments'

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

function throws(fn: () => unknown): boolean {
  try {
    fn()
    return false
  } catch {
    return true
  }
}

// ------------------------------------------------------------- extension
t('extension is lower-cased', fileExtension('PO 4471.PDF'), 'pdf')
t('extension is the last one', fileExtension('order.v2.final.xlsx'), 'xlsx')
t('no extension', fileExtension('Scan'), '')
t('a dot file has no extension', fileExtension('.pdf'), '')
t('a trailing dot is not an extension', fileExtension('file.'), '')
t('a folder in front does not count', fileExtension('12/1700000000000-a.b/readme'), '')

// -------------------------------------------------------------- sanitize
t('a clean name is kept', sanitizeDocumentName('PO-4471_rev2.pdf'), 'PO-4471_rev2.pdf')
t('spaces and symbols become one underscore', sanitizeDocumentName('PO #4471  (signed).pdf'), 'PO_4471_signed.pdf')
t('slashes cannot make a folder', sanitizeDocumentName('../../etc/passwd'), 'etc_passwd')
t('a backslash path is flattened', sanitizeDocumentName('C:\\Users\\me\\PO.pdf'), 'C_Users_me_PO.pdf')
t('accents fold to letters', sanitizeDocumentName('Commandé façade.pdf'), 'Commande_facade.pdf')
t('a name with nothing usable keeps its extension', sanitizeDocumentName('注文書.pdf'), 'file.pdf')
t('a mid-name run of dots and underscores is one dot', sanitizeDocumentName('a_._.b.pdf'), 'a.b.pdf')
t('a symbol stuck to the extension is not an extension', sanitizeDocumentName('po.pdf#1'), 'po.pdf_1')
t('repeated dots collapse', sanitizeDocumentName('a..b...pdf'), 'a.b.pdf')
t('a space before the extension does not break it', sanitizeDocumentName('PO .pdf'), 'PO.pdf')
t('leading dots and dashes go', sanitizeDocumentName('.-draft.pdf'), 'draft.pdf')
t('an empty name is still a name', sanitizeDocumentName('   '), 'file')
t('only symbols is still a name', sanitizeDocumentName('###'), 'file')
t('case is kept', sanitizeDocumentName('Signed PO.PDF'), 'Signed_PO.PDF')

const long = sanitizeDocumentName(`${'a'.repeat(300)}.xlsx`)
t('a long name is cut to 100', long.length, 100)
t('…and keeps its extension', long.endsWith('.xlsx'), true)
t('a long name with no extension is just cut', sanitizeDocumentName('b'.repeat(300)).length, 100)
t('only safe characters survive', /^[A-Za-z0-9._-]+$/.test(sanitizeDocumentName('été 2026 — PO №7 (v2)!.pdf')), true)

// ------------------------------------------------------------------ path
t('path is <order id>/<ms>-<name>', orderDocumentPath(8123, 'PO #4471.pdf', 1763000000000), '8123/1763000000000-PO_4471.pdf')
t('exactly one folder level', orderDocumentPath(8123, 'a/b/c.pdf', 1763000000000).split('/').length, 2)
t('the first segment is the numeric order id', /^[0-9]{1,18}\//.test(orderDocumentPath(42, 'x.pdf', 1)), true)
t('folder is the id as text', orderDocumentFolder(42), '42')
t('no order id, no path', throws(() => orderDocumentPath(0, 'x.pdf')), true)
t('a fractional id is refused', throws(() => orderDocumentPath(1.5, 'x.pdf')), true)
t('NaN is refused', throws(() => orderDocumentFolder(Number('abc'))), true)
t('a negative id is refused', throws(() => orderDocumentFolder(-3)), true)
t('the default timestamp is now', /^7\/\d{13}-x\.pdf$/.test(orderDocumentPath(7, 'x.pdf')), true)

// ---------------------------------------------------------- display name
t('the stamp comes off', documentDisplayName('1763000000000-PO_4471.pdf'), 'PO_4471.pdf')
t('…with the folder too', documentDisplayName('8123/1763000000000-PO_4471.pdf'), 'PO_4471.pdf')
t('a name that starts with a year is not a stamp', documentDisplayName('2026-PO.pdf'), '2026-PO.pdf')
t('a stamped name that starts with a number keeps it', documentDisplayName('1763000000000-2026-PO.pdf'), '2026-PO.pdf')
t('an unstamped object shows as it is', documentDisplayName('signed-po.pdf'), 'signed-po.pdf')
t('a bare stamp is not stripped to nothing', documentDisplayName('1763000000000-'), '1763000000000-')
t('round trip: path → display name', documentDisplayName(orderDocumentPath(5, 'Signed PO.pdf', 1763000000000)), 'Signed_PO.pdf')
t('the stamp is the upload time', documentStampedAt('8123/1763000000000-a.pdf'), new Date(1763000000000).toISOString())
t('no stamp, no time', documentStampedAt('a.pdf'), null)

// -------------------------------------------------------------- validate
const pdf = { name: 'PO.pdf', size: 120_000, type: 'application/pdf' }
t('a PDF passes', validateDocumentFile(pdf), { ok: true, contentType: 'application/pdf', fileName: 'PO.pdf' })
t('exactly 25 MB passes', validateDocumentFile({ ...pdf, size: ORDER_DOCUMENT_MAX_BYTES }).ok, true)
t('one byte over is refused', validateDocumentFile({ ...pdf, size: ORDER_DOCUMENT_MAX_BYTES + 1 }).ok, false)
t('a 40 MB scan says how big it is, and the limit',
  validateDocumentFile({ ...pdf, name: 'scan.pdf', size: 40 * 1024 * 1024 }),
  { ok: false, error: 'scan.pdf is too large (40 MB). The limit is 25 MB per file.' })
t('an empty file is refused', validateDocumentFile({ ...pdf, size: 0 }), { ok: false, error: 'PO.pdf is empty.' })
t('.msg with no browser type is taken by its extension',
  validateDocumentFile({ name: 'RE order.msg', size: 5000, type: '' }),
  { ok: true, contentType: 'application/vnd.ms-outlook', fileName: 'RE order.msg' })
t('.eml likewise',
  validateDocumentFile({ name: 'order.eml', size: 5000, type: null }),
  { ok: true, contentType: 'message/rfc822', fileName: 'order.eml' })
t('a .csv Windows calls Excel is sent as CSV',
  validateDocumentFile({ name: 'lines.csv', size: 900, type: 'application/vnd.ms-excel' }),
  { ok: true, contentType: 'text/csv', fileName: 'lines.csv' })
t('an upper-case extension counts',
  validateDocumentFile({ name: 'IMG_0042.JPG', size: 900_000, type: 'image/jpeg' }),
  { ok: true, contentType: 'image/jpeg', fileName: 'IMG_0042.JPG' })
t('no extension: the browser type decides, and an extension is added',
  validateDocumentFile({ name: 'Scan', size: 900_000, type: 'image/jpeg' }),
  { ok: true, contentType: 'image/jpeg', fileName: 'Scan.jpg' })
t('a type with parameters still matches',
  validateDocumentFile({ name: 'notes', size: 10, type: 'text/plain;charset=utf-8' }),
  { ok: true, contentType: 'text/plain', fileName: 'notes.txt' })
t('an executable is refused', validateDocumentFile({ name: 'setup.exe', size: 10, type: 'application/x-msdownload' }).ok, false)
t('a zip is refused, and told what works',
  (validateDocumentFile({ name: 'po.zip', size: 10, type: 'application/zip' }) as { error: string }).error,
  "po.zip isn't a file type that can be attached. Use PDF, Excel, Word, CSV, text, an email (.eml, .msg) or a picture (PNG, JPEG, WebP, HEIC).")
t('html is refused whatever it claims', validateDocumentFile({ name: 'page.html', size: 10, type: 'text/html' }).ok, false)
t('svg is refused', validateDocumentFile({ name: 'logo.svg', size: 10, type: 'image/svg+xml' }).ok, false)
t('a double extension goes by the last one', validateDocumentFile({ name: 'po.pdf.exe', size: 10, type: '' }).ok, false)

// The bucket's allowed_mime_types, all thirteen, and nothing else.
t('every content type sent is one the bucket allows',
  [...new Set(Object.values(ORDER_DOCUMENT_TYPES))].sort(),
  [
    'application/msword',
    'application/pdf',
    'application/vnd.ms-excel',
    'application/vnd.ms-outlook',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'image/heic',
    'image/jpeg',
    'image/png',
    'image/webp',
    'message/rfc822',
    'text/csv',
    'text/plain',
  ])
t('the limit is the bucket file_size_limit', ORDER_DOCUMENT_MAX_BYTES, 26214400)
// The picker names every type but HEIC, so an iPhone converts its photos to
// JPEG; a HEIC chosen or dropped anyway is still taken.
t('the picker lists every extension but HEIC, then the picture types', ORDER_DOCUMENT_ACCEPT,
  '.pdf,.xlsx,.xls,.docx,.doc,.csv,.txt,.eml,.msg,.png,.jpg,.jpeg,.webp,image/png,image/jpeg,image/webp')
t('…and never HEIC', /heic/i.test(ORDER_DOCUMENT_ACCEPT), false)
t('a HEIC that arrives anyway is still taken',
  validateDocumentFile({ name: 'IMG_0042.HEIC', size: 900_000, type: 'image/heic' }),
  { ok: true, contentType: 'image/heic', fileName: 'IMG_0042.HEIC' })

// ------------------------------------------------------------------ size
t('bytes', formatFileSize(812), '812 B')
t('kilobytes', formatFileSize(293_888), '287 KB')
t('megabytes, one decimal', formatFileSize(4.12 * 1024 * 1024), '4.1 MB')
t('a round megabyte has no .0', formatFileSize(25 * 1024 * 1024), '25 MB')
t('zero', formatFileSize(0), '0 B')
t('unknown size is blank', formatFileSize(null), '')
t('NaN is blank', formatFileSize(Number.NaN), '')

// ------------------------------------------------------ opens in browser
t('a PDF opens in a tab', opensInBrowser('1763000000000-PO.pdf'), true)
t('a photo opens in a tab', opensInBrowser('IMG.JPG'), true)
t('a spreadsheet downloads', opensInBrowser('lines.xlsx'), false)
t('an Outlook message downloads', opensInBrowser('RE_order.msg'), false)
t('HEIC downloads (most browsers cannot show it)', opensInBrowser('IMG_1.heic'), false)

// --------------------------------------------------------------- listing
const listed = [
  { name: '1763000000000-PO_4471.pdf', id: 'a', created_at: '2025-11-13T02:13:20.000Z', metadata: { size: 293_888, mimetype: 'application/pdf' } },
  { name: '1763000500000-signed.pdf', id: 'b', created_at: '2025-11-13T02:21:40.000Z', metadata: { size: 1000 } },
  { name: '.emptyFolderPlaceholder', id: 'c', created_at: '2025-11-13T02:00:00.000Z', metadata: { size: 0 } },
  { name: 'subfolder', id: null, created_at: null, metadata: null },
  { name: '1763000900000-no_meta.eml', id: 'd', created_at: null, metadata: null },
]
const docs = toOrderDocuments(8123, listed)
t('folders and placeholders are not documents', docs.length, 3)
t('newest first', docs.map((d) => d.displayName), ['no_meta.eml', 'signed.pdf', 'PO_4471.pdf'])
t('a row carries its full path', docs[2].path, '8123/1763000000000-PO_4471.pdf')
t('…its size', docs[2].size, 293_888)
t('…and when it was uploaded', docs[2].uploadedAt, '2025-11-13T02:13:20.000Z')
t('no created_at: the stamp in the name', docs[0].uploadedAt, new Date(1763000900000).toISOString())
t('no metadata: size unknown', docs[0].size, null)
t('an empty folder is an empty list', toOrderDocuments(8123, []), [])
t('a listing needs a real order id', throws(() => toOrderDocuments(0, listed)), true)

// ---------------------------------------------------------------- errors
// Every per-file failure names the file and what was being done with it.
t('RLS refusal on an upload', documentErrorText({ message: 'new row violates row-level security policy' }, 'PO.pdf'),
  "PO.pdf didn't upload: you don't have access to this order's documents.")
t('…on an open', documentErrorText({ message: 'new row violates row-level security policy' }, 'PO.pdf', 'open'),
  "PO.pdf couldn't be opened: you don't have access to this order's documents.")
t('…on a remove', documentErrorText({ message: 'permission denied' }, 'PO.pdf', 'remove'),
  "PO.pdf wasn't removed: you don't have access to this order's documents.")
t('too large', documentErrorText({ message: 'The object exceeded the maximum allowed size' }, 'PO.pdf'),
  'PO.pdf is over the 25 MB limit.')
t('wrong type', documentErrorText({ message: 'mime type application/zip is not supported' }, 'po.zip').startsWith("po.zip isn't a file type"), true)
t('duplicate', documentErrorText({ message: 'The resource already exists' }, 'PO.pdf'),
  'PO.pdf was just uploaded. Refresh the list before trying again.')
t('no bucket', documentErrorText({ message: 'Bucket not found' }, 'PO.pdf'),
  "PO.pdf didn't upload: order documents aren't set up on this database yet.")
t('removed by someone else since the list loaded', documentErrorText({ message: 'Object not found' }, 'PO.pdf', 'open'),
  'PO.pdf was removed; refresh the list.')
t('no signal on an upload', documentErrorText(new Error('Failed to fetch'), 'PO.pdf'),
  "PO.pdf didn't upload: this device couldn't reach the network. Try again when you have signal.")
t('no signal on an open does not say upload', documentErrorText(new Error('Load failed'), 'PO.pdf', 'open'),
  "PO.pdf couldn't be opened: this device couldn't reach the network. Try again when you have signal.")
t('no signal on a remove', documentErrorText(new TypeError('NetworkError when attempting to fetch resource.'), 'PO.pdf', 'remove'),
  "PO.pdf wasn't removed: this device couldn't reach the network. Try again when you have signal.")
t('anything else passes through, after the name', documentErrorText({ message: 'Something odd' }, 'PO.pdf'),
  "PO.pdf didn't upload: Something odd")
t('nothing at all', documentErrorText(null), "That file didn't upload.")
// Storage says 'Bucket not found' (404) to an upload, a sign and a remove of a
// missing bucket. A listing never does: it answers with an empty list.
t('an upload or sign refused for a missing bucket is recognised',
  isBucketMissing({ name: 'StorageApiError', message: 'Bucket not found', status: 404 }), true)
t('…as a bare message too', isBucketMissing('Bucket not found'), true)
t('another error is not', isBucketMissing({ message: 'jwt expired' }), false)
t('a missing object is not a missing bucket', isBucketMissing({ message: 'Object not found' }), false)
t('no error is not', isBucketMissing(null), false)

// ------------------------------------------------------------ remove rule
// Storage lets the uploader, an admin or inside sales remove. A listing does
// not say who uploaded, so anyone else is offered it only on the files this
// browser uploaded for them; nobody is offered it without a session that writes.
const rep = { canWrite: true, isAdmin: false, isOrderEntry: false }
const admin = { canWrite: true, isAdmin: true, isOrderEntry: false }
const insideSales = { canWrite: true, isAdmin: false, isOrderEntry: true }
t('admin: every file', canOfferRemove(admin, false), true)
t('inside sales: every file', canOfferRemove(insideSales, false), true)
t('a rep: the file they just uploaded', canOfferRemove(rep, true), true)
t('a rep: not a file from before (who added it is unknown)', canOfferRemove(rep, false), false)
t('viewing as someone: nothing, even as an admin', canOfferRemove({ ...admin, canWrite: false }, false), false)
t('offline: nothing, even the file just uploaded', canOfferRemove({ ...rep, canWrite: false }, true), false)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
