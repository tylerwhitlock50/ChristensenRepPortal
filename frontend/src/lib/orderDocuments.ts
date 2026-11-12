/**
 * Order documents — the customer's PO as it arrived, and anything else that
 * belongs with an order (20261113090000). The pure rules, unit tested in
 * tests/unit/orderDocuments.test.ts; the Storage calls are in
 * composables/useOrderDocuments.ts.
 *
 * There is no table. The private bucket `order-documents` IS the list, and
 * its RLS reads the FIRST folder of the object name as the order id:
 *
 *   can_read_order(order_document_order_id(name))   -- '<order id>/<file name>'
 *
 * so an object is named exactly `<order id>/<epoch ms>-<sanitized name>`:
 * one folder level, the numeric order id. Get that segment wrong and the
 * upload is refused, which is the failure we want. Whoever can read the
 * order can list, open and add; removing is the uploader, an admin or
 * inside sales.
 *
 * Everything here mirrors what the bucket enforces (size, MIME types) so the
 * person hears about a bad file before a 25 MB upload, not after it.
 */

export const ORDER_DOCUMENTS_BUCKET = 'order-documents'

/** The bucket's file_size_limit: 25 MB. */
export const ORDER_DOCUMENT_MAX_BYTES = 25 * 1024 * 1024

/** How long a link to open one document lasts. */
export const ORDER_DOCUMENT_URL_SECONDS = 300

/**
 * Extension → the content type sent with the upload. The values are the
 * bucket's allowed_mime_types, all of them; the keys are the extensions
 * people actually have. The extension decides, not the browser's `type`:
 * browsers report nothing for .msg and .eml, and Excel's MIME type for a .csv
 * on a PC with Office installed.
 */
export const ORDER_DOCUMENT_TYPES: Readonly<Record<string, string>> = {
  pdf: 'application/pdf',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  xls: 'application/vnd.ms-excel',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  doc: 'application/msword',
  csv: 'text/csv',
  txt: 'text/plain',
  eml: 'message/rfc822',
  msg: 'application/vnd.ms-outlook',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  heic: 'image/heic',
}

/** A file with no usable extension, told apart by its type: type → extension. */
const EXTENSION_BY_MIME: Readonly<Record<string, string>> = Object.fromEntries(
  Object.entries(ORDER_DOCUMENT_TYPES)
    .filter(([ext]) => ext !== 'jpeg')
    .map(([ext, mime]) => [mime, ext]),
)

/** For the file picker's `accept`: every extension, then the picture types
 *  (which is what makes a phone offer its camera and photo library). */
export const ORDER_DOCUMENT_ACCEPT = [
  ...Object.keys(ORDER_DOCUMENT_TYPES).map((ext) => `.${ext}`),
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/heic',
].join(',')

/** In words, for the drop zone and the refusal. */
export const ORDER_DOCUMENT_TYPES_LABEL =
  'PDF, Excel, Word, CSV, text, an email (.eml, .msg) or a picture (PNG, JPEG, WebP, HEIC)'

const MAX_NAME_LENGTH = 100
/** What counts as an extension to keep: short, and nothing but letters and digits. */
const EXTENSION = /^[A-Za-z0-9]{1,10}$/

/** 'PO 4471.PDF' → 'pdf'; '' when there is none. A leading dot is not one. */
export function fileExtension(name: string): string {
  const base = name.slice(name.lastIndexOf('/') + 1)
  const dot = base.lastIndexOf('.')
  if (dot <= 0 || dot === base.length - 1) return ''
  return base.slice(dot + 1).toLowerCase()
}

/** Letters, digits, dot, dash, underscore; everything else is one `_`. */
function cleanNamePart(part: string): string {
  return (
    part
      // 'Commandé' → 'Commande' rather than 'Command_'.
      .normalize('NFKD')
      .replace(/[\u0300-\u036f]/g, '')
      .replace(/[^A-Za-z0-9._-]+/g, '_')
      .replace(/_+/g, '_')
      // Any run of dots and underscores with a dot in it is one dot:
      // 'a..b', 'PO _.v2', and '../..' cannot survive as they were.
      .replace(/_*(?:\._*)+/g, '.')
      .replace(/^[._-]+/, '')
      .replace(/[._-]+$/, '')
  )
}

/**
 * A file name Storage will take as an object name, still recognisable:
 * letters, digits, dot, dash and underscore are kept, everything else
 * (spaces, #, slashes, other scripts) becomes `_`, repeats collapse, and it
 * is cut to MAX_NAME_LENGTH. The extension is set aside first and put back
 * untouched, so neither the cut nor a name with nothing usable in it
 * ('注文書.pdf') can lose it. Never empty, never starting with a dot.
 */
export function sanitizeDocumentName(name: string): string {
  const raw = String(name ?? '').trim()
  const dot = raw.lastIndexOf('.')
  const tail = dot > 0 ? raw.slice(dot + 1) : ''
  const hasExtension = EXTENSION.test(tail)
  const extension = hasExtension ? `.${tail}` : ''
  const base = cleanNamePart(hasExtension ? raw.slice(0, dot) : raw)
    .slice(0, MAX_NAME_LENGTH - extension.length)
    .replace(/[._-]+$/, '')
  return `${base || 'file'}${extension}`
}

/** Storage RLS reads this as a bigint: a positive whole number, 18 digits at most. */
function isOrderId(orderId: number): boolean {
  return Number.isSafeInteger(orderId) && orderId > 0
}

/** `<order id>/` is the folder a listing asks for (without the slash). */
export function orderDocumentFolder(orderId: number): string {
  if (!isOrderId(orderId)) {
    throw new Error(
      `Order documents need a real order id; got "${orderId}". It is the first ` +
        'path segment and the only thing Storage access control reads.',
    )
  }
  return String(orderId)
}

/**
 * `<order id>/<epoch ms>-<sanitized name>`. The timestamp keeps two uploads
 * of "PO.pdf" apart (upsert is off, so a clash would be refused) and sorts
 * the folder oldest to newest by name.
 */
export function orderDocumentPath(orderId: number, fileName: string, now: number = Date.now()): string {
  return `${orderDocumentFolder(orderId)}/${Math.trunc(now)}-${sanitizeDocumentName(fileName)}`
}

/** The `<epoch ms>-` this module puts in front of a stored name. */
const STAMP = /^(\d{13})-(?=.)/

/** What to call a stored object on screen: its name without folder or stamp. */
export function documentDisplayName(objectName: string): string {
  const base = objectName.slice(objectName.lastIndexOf('/') + 1)
  return base.replace(STAMP, '')
}

/** When a stored object was uploaded, going by its name; null without a stamp. */
export function documentStampedAt(objectName: string): string | null {
  const base = objectName.slice(objectName.lastIndexOf('/') + 1)
  const match = STAMP.exec(base)
  if (!match) return null
  const d = new Date(Number(match[1]))
  return Number.isNaN(d.getTime()) ? null : d.toISOString()
}

/** The slice of a File these rules read (so a test needs no File). */
export interface DocumentFileLike {
  name: string
  size: number
  type?: string | null
}

export type DocumentFileCheck =
  | {
      ok: true
      /** What to send as the upload's content type: one the bucket allows. */
      contentType: string
      /** The name to store under: the file's own, with an extension when it had none. */
      fileName: string
    }
  | { ok: false; error: string }

/**
 * Whether the bucket will take this file, and as what. Size first (the
 * commonest refusal: a phone photo of every page as one PDF), then type.
 */
export function validateDocumentFile(file: DocumentFileLike): DocumentFileCheck {
  const name = file.name?.trim() || 'file'
  if (!(file.size > 0)) {
    return { ok: false, error: `${name} is empty.` }
  }
  if (file.size > ORDER_DOCUMENT_MAX_BYTES) {
    return {
      ok: false,
      error: `${name} is too large (${formatFileSize(file.size)}). The limit is ${formatFileSize(ORDER_DOCUMENT_MAX_BYTES)} per file.`,
    }
  }

  const byExtension = ORDER_DOCUMENT_TYPES[fileExtension(name)]
  if (byExtension) return { ok: true, contentType: byExtension, fileName: name }

  // No extension we know ('Scan', a photo straight off a camera roll): the
  // browser's own word for it, when that is a type the bucket takes.
  const type = (file.type ?? '').split(';')[0].trim().toLowerCase()
  const extension = EXTENSION_BY_MIME[type]
  if (extension) return { ok: true, contentType: type, fileName: `${name}.${extension}` }

  return {
    ok: false,
    error: `${name} isn't a file type that can be attached. Use ${ORDER_DOCUMENT_TYPES_LABEL}.`,
  }
}

/** "812 B", "287 KB", "4.1 MB" — '' when Storage did not say. */
export function formatFileSize(bytes: number | null | undefined): string {
  if (bytes == null || !Number.isFinite(bytes) || bytes < 0) return ''
  if (bytes < 1024) return `${Math.round(bytes)} B`
  const kb = bytes / 1024
  if (kb < 1000) return `${Math.round(kb)} KB`
  const mb = kb / 1024
  return `${mb >= 100 ? Math.round(mb) : Number(mb.toFixed(1))} MB`
}

/**
 * Types a browser shows in a tab. The rest (spreadsheets, Word, emails,
 * HEIC) it can only save, so those are fetched as a download under their
 * own name rather than left as a blank tab.
 */
const OPENS_IN_BROWSER = new Set(['pdf', 'png', 'jpg', 'jpeg', 'webp', 'txt'])

export function opensInBrowser(name: string): boolean {
  return OPENS_IN_BROWSER.has(fileExtension(name))
}

/** One row of the card. */
export interface OrderDocument {
  /** The object's name inside the order's folder: `<epoch ms>-<sanitized name>`. */
  name: string
  /** The whole object name: `<order id>/<name>`. What sign and remove take. */
  path: string
  displayName: string
  /** Bytes, when the listing carried them. */
  size: number | null
  /** ISO timestamp: Storage's created_at, else the stamp in the name. */
  uploadedAt: string | null
}

/** The fields of a Storage listing row these rules read. */
export interface ListedObject {
  name: string
  /** Null for a folder. */
  id?: string | null
  created_at?: string | null
  metadata?: Record<string, unknown> | null
}

/**
 * A bucket listing of `<order id>/` as the card's rows, newest first.
 * Folders and Storage's own placeholder files are not documents.
 */
export function toOrderDocuments(orderId: number, listed: readonly ListedObject[]): OrderDocument[] {
  const folder = orderDocumentFolder(orderId)
  const docs: OrderDocument[] = []
  for (const o of listed) {
    // id null is how a listing marks a folder; a dot file is Storage's own
    // '.emptyFolderPlaceholder'.
    if (!o?.name || o.id === null || o.name.startsWith('.')) continue
    const size = o.metadata?.size
    docs.push({
      name: o.name,
      path: `${folder}/${o.name}`,
      displayName: documentDisplayName(o.name),
      size: typeof size === 'number' && Number.isFinite(size) && size >= 0 ? size : null,
      uploadedAt: o.created_at || documentStampedAt(o.name),
    })
  }
  const time = (d: OrderDocument) => (d.uploadedAt ? Date.parse(d.uploadedAt) || 0 : 0)
  return docs.sort((a, b) => {
    const byDate = time(b) - time(a)
    // The stamp in the name breaks a tie (and orders rows with no date).
    return byDate !== 0 ? byDate : b.name.localeCompare(a.name)
  })
}

/**
 * What Storage said when it refused, in words. Unrecognised messages pass
 * through: a specific wrong answer beats a friendly dead end.
 */
export function documentErrorText(error: unknown, fileName = 'That file'): string {
  const message =
    typeof error === 'string' ? error : String((error as { message?: unknown } | null)?.message ?? '')
  if (/row-level security|unauthorized|not authorized|permission denied/i.test(message)) {
    return "You don't have access to this order's documents."
  }
  if (/exceeded the maximum allowed size|payload too large|entity too large/i.test(message)) {
    return `${fileName} is over the ${formatFileSize(ORDER_DOCUMENT_MAX_BYTES)} limit.`
  }
  if (/mime type .* is not supported|invalid_mime_type/i.test(message)) {
    return `${fileName} isn't a file type that can be attached. Use ${ORDER_DOCUMENT_TYPES_LABEL}.`
  }
  if (/already exists|duplicate/i.test(message)) {
    return `${fileName} was just uploaded. Refresh the list before trying again.`
  }
  if (isBucketMissing(error)) {
    return "Order documents aren't set up on this database yet."
  }
  if (/failed to fetch|network ?request ?failed|networkerror|load failed/i.test(message)) {
    return `${fileName} didn't upload: this device couldn't reach the network. Try again when you have signal.`
  }
  return message || 'That failed.'
}

/** The bucket is not there: a database without 20261113090000. */
export function isBucketMissing(error: unknown): boolean {
  const message =
    typeof error === 'string' ? error : String((error as { message?: unknown } | null)?.message ?? '')
  return /bucket not found/i.test(message)
}
