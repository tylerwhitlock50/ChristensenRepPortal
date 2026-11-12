/**
 * Unit tests for composables/useOrderDocuments.ts against a stubbed bucket:
 * the Storage calls behind the Documents card (20261113090000), which the
 * pure rules in orderDocuments.test.ts do not reach.
 *
 * Run with:  npm run test:unit -- orderDocuments
 *
 * What matters: a .msg the browser gives no type goes up typed as Outlook
 * mail (storage-js takes a File's own type, not the contentType option); a
 * remove that Storage filters out (an empty list back) is a refusal, not a
 * success; the files this browser uploaded are remembered for the person who
 * uploaded them and forgotten once removed; a missing bucket is learned from
 * an upload; a blank tab left behind by a download is closed, but only on a
 * desktop browser and never on a touch device, where it is still loading.
 */
import {
  blankTabCloserApplies,
  closeIfStillBlank,
  orderDocumentsUnavailable,
  removeOrderDocument,
  uploadOrderDocument,
  wasUploadedHere,
} from '../../src/composables/useOrderDocuments'
import type { OrderDocument } from '../../src/lib/orderDocuments'

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

async function rejection(promise: Promise<unknown>): Promise<string | null> {
  try {
    await promise
    return null
  } catch (e) {
    return (e as Error).message
  }
}

type UploadCall = { path: string; body: Blob; options: Record<string, unknown> }

/** A bucket that records uploads and answers with `error` (none by default). */
function uploadBucket(error: unknown = null) {
  const calls: UploadCall[] = []
  return {
    calls,
    upload: async (path: string, body: Blob, options: Record<string, unknown>) => {
      calls.push({ path, body, options })
      return error ? { data: null, error } : { data: { id: 'x', path, fullPath: `order-documents/${path}` }, error: null }
    },
  }
}

/** A bucket whose remove answers with these rows (or this error). */
function removeBucket(rows: unknown[] | null, error: unknown = null) {
  const calls: string[][] = []
  return {
    calls,
    remove: async (paths: string[]) => {
      calls.push(paths)
      return error ? { data: null, error } : { data: rows, error: null }
    },
  }
}

const AT = 1763000000000
const REP = '00000000-0000-0000-0000-00000000000a'
const OTHER = '00000000-0000-0000-0000-00000000000b'

// ------------------------------------------------------------- uploading
{
  const bucket = uploadBucket()
  // What a browser hands over for an Outlook message: no type at all.
  const msg = new File(['From: buyer'], 'RE PO 4471.msg', { type: '' })
  const path = await uploadOrderDocument(bucket as never, { orderId: 8123, file: msg, at: AT, uploaderId: REP })
  const call = bucket.calls[0]
  t('the .msg goes to <order id>/<ms>-<sanitized name>', path, '8123/1763000000000-RE_PO_4471.msg')
  t('…the path it was stored under', call.path, path)
  t('…as a body typed as Outlook mail, not the empty type the browser gave', call.body.type, 'application/vnd.ms-outlook')
  t('…with every byte', call.body.size, msg.size)
  t('…the content type option says the same', call.options.contentType, 'application/vnd.ms-outlook')
  t('…and never overwrites', call.options.upsert, false)
  t('the uploader is remembered for that file', wasUploadedHere(8123, path, REP), true)
  t('…not for someone else signed in later', wasUploadedHere(8123, path, OTHER), false)
  t('…not on another order', wasUploadedHere(8124, path, REP), false)
  t('…and not without a user', wasUploadedHere(8123, path, null), false)
}
{
  const bucket = uploadBucket()
  const pdf = new File(['%PDF-1.7'], 'PO.pdf', { type: 'application/pdf' })
  await uploadOrderDocument(bucket as never, { orderId: 8123, file: pdf, at: AT })
  t('a file already typed right goes up as itself', bucket.calls[0].body === pdf, true)
}
{
  const bucket = uploadBucket()
  const zip = new File(['PK'], 'po.zip', { type: 'application/zip' })
  const message = await rejection(uploadOrderDocument(bucket as never, { orderId: 8123, file: zip, at: AT }))
  t('a refused type never reaches the bucket', bucket.calls.length, 0)
  t('…and says why', message?.startsWith("po.zip isn't a file type"), true)
}
{
  const bucket = uploadBucket({ message: 'new row violates row-level security policy' })
  const pdf = new File(['%PDF'], 'PO.pdf', { type: 'application/pdf' })
  const message = await rejection(
    uploadOrderDocument(bucket as never, { orderId: 8123, file: pdf, at: AT + 5, uploaderId: REP }),
  )
  t('a refused upload names the file', message, "PO.pdf didn't upload: you don't have access to this order's documents.")
  t('…and is not remembered as uploaded', wasUploadedHere(8123, '8123/1763000000005-PO.pdf', REP), false)
  t('…and is not taken for a missing bucket', orderDocumentsUnavailable.value, false)
}
{
  const bucket = uploadBucket({ name: 'StorageApiError', message: 'Bucket not found', status: 404 })
  const pdf = new File(['%PDF'], 'PO.pdf', { type: 'application/pdf' })
  const message = await rejection(uploadOrderDocument(bucket as never, { orderId: 8123, file: pdf, at: AT }))
  t('no bucket: the upload says so', message, "PO.pdf didn't upload: order documents aren't set up on this database yet.")
  t('…and the card learns the bucket is missing', orderDocumentsUnavailable.value, true)
  orderDocumentsUnavailable.value = false
}
{
  const bucket = {
    upload: async () => {
      throw new TypeError('Failed to fetch')
    },
  }
  const pdf = new File(['%PDF'], 'PO.pdf', { type: 'application/pdf' })
  const message = await rejection(uploadOrderDocument(bucket as never, { orderId: 8123, file: pdf, at: AT }))
  t('a call that throws is worded like one that answered', message?.startsWith("PO.pdf didn't upload: this device couldn't reach the network"), true)
}

// --------------------------------------------------------------- removing
const doc = (orderId: number, name: string): OrderDocument => ({
  name,
  path: `${orderId}/${name}`,
  displayName: name.replace(/^\d{13}-/, ''),
  size: 1000,
  uploadedAt: null,
})

{
  // The rep's own upload from above, removed.
  const mine = doc(8123, '1763000000000-RE_PO_4471.msg')
  const bucket = removeBucket([{ name: mine.path }])
  await removeOrderDocument(bucket as never, { orderId: 8123, document: mine })
  t('remove asks for exactly that object', bucket.calls, [['8123/1763000000000-RE_PO_4471.msg']])
  t('…and the removed file is no longer remembered', wasUploadedHere(8123, mine.path, REP), false)
}
{
  const theirs = doc(8123, '1762000000000-PO.pdf')
  const bucket = removeBucket([])
  const message = await rejection(removeOrderDocument(bucket as never, { orderId: 8123, document: theirs }))
  // Storage drops a delete its policy filters out and answers 200 [].
  t('an empty list back is a refusal, not a success', message,
    "PO.pdf wasn't removed. Only the person who added it, an admin or inside sales can remove a document.")
}
{
  const theirs = doc(8123, '1762000000000-PO.pdf')
  const bucket = removeBucket(null)
  t('…and so is no list at all', (await rejection(removeOrderDocument(bucket as never, { orderId: 8123, document: theirs })))?.startsWith("PO.pdf wasn't removed."), true)
}
{
  const theirs = doc(8123, '1762000000000-PO.pdf')
  const bucket = removeBucket(null, { message: 'Failed to fetch' })
  t('a remove with no signal says remove, not upload',
    await rejection(removeOrderDocument(bucket as never, { orderId: 8123, document: theirs })),
    "PO.pdf wasn't removed: this device couldn't reach the network. Try again when you have signal.")
}

// ------------------------------------------------------- the blank tab
/** A tab as the opener sees it: `href` readable while it is still blank. */
function fakeTab(location: () => string, closed = false) {
  const tab = {
    closed,
    closedByUs: false,
    close() {
      tab.closedByUs = true
      tab.closed = true
    },
    get location() {
      return { href: location() } as Location
    },
  }
  return tab
}
const now = (run: () => void) => run()
{
  const tab = fakeTab(() => 'about:blank')
  closeIfStillBlank(tab as never, 6000, now)
  t('a tab still blank (the browser saved the file) is closed', tab.closedByUs, true)
}
{
  const tab = fakeTab(() => {
    throw new DOMException('Blocked a frame with origin', 'SecurityError')
  })
  closeIfStillBlank(tab as never, 6000, now)
  t('a tab showing the document (another origin) is left open', tab.closedByUs, false)
}
{
  const tab = fakeTab(() => 'about:blank', true)
  closeIfStillBlank(tab as never, 6000, now)
  t('a tab the person already closed is left alone', tab.closedByUs, false)
}
{
  let waited = 0
  const tab = fakeTab(() => 'about:blank')
  closeIfStillBlank(tab as never, undefined, (_run, ms) => {
    waited = ms
  })
  t('…and only after a while, not at once', [waited >= 3000, tab.closedByUs], [true, false])
  // A tab still waiting for Storage's first byte reads about:blank too.
  t('…long enough for a slow connection to start a PDF', waited >= 15_000, true)
}
{
  /** A device as matchMedia describes it: the queries that match. */
  const device = (...matching: string[]) => (q: string) => ({ matches: matching.includes(q) })
  t('a desktop with a mouse closes a blank tab',
    blankTabCloserApplies(device('(pointer: fine)')), true)
  t('a phone (touch only) never does: a blank tab there is still loading',
    blankTabCloserApplies(device('(pointer: coarse)', '(any-pointer: coarse)')), false)
  t('…nor a tablet with a trackpad attached',
    blankTabCloserApplies(device('(pointer: fine)', '(any-pointer: coarse)')), false)
  t('…nor a browser without matchMedia', blankTabCloserApplies(null), false)
}

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
