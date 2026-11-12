/*============================================================================
  mcp/orderDocuments.ts — the order-document naming rules, as the portal has
  them (20261113090000).

  A COPY of the pure rules in frontend/src/lib/orderDocuments.ts: the bucket,
  the extension → content-type table, the file-name sanitizer and the
  '<order id>/<epoch ms>-<name>' object name. One rule, two runtimes: a PO
  attached through Claude and the same PO dropped on the order page are
  stored under the same name, and both sides refuse the same file types.
  orderDocuments.test.ts imports both and fails if they ever answer
  differently. Change the portal's first, then copy it here.

  Storage RLS reads the FIRST folder of the object name as the order id, so
  an object is named exactly `<order id>/<epoch ms>-<sanitized name>`: one
  folder level, the numeric order id.
============================================================================*/

export const ORDER_DOCUMENTS_BUCKET = 'order-documents'

/** The bucket's file_size_limit: 25 MB. */
export const ORDER_DOCUMENT_MAX_BYTES = 25 * 1024 * 1024

/**
 * Extension → the content type sent with the upload. The values are the
 * bucket's allowed_mime_types, all of them; the keys are the extensions
 * people actually have. Storage checks only the Content-Type the uploader
 * declares, so this table decides what a client must send.
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

/** The accepted extensions, for a refusal: '.pdf, .xlsx, …'. */
export const ORDER_DOCUMENT_EXTENSIONS = Object.keys(ORDER_DOCUMENT_TYPES).map((ext) => `.${ext}`).join(', ')

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
      .replace(/[̀-ͯ]/g, '')
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
export function isOrderId(orderId: number): boolean {
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

/** The `<epoch ms>-` orderDocumentPath puts in front of a stored name. */
const STAMP = /^(\d{13})-(?=.)/

/** What to call a stored object to a person: its name without folder or stamp. */
export function documentDisplayName(objectName: string): string {
  const base = objectName.slice(objectName.lastIndexOf('/') + 1)
  return base.replace(STAMP, '')
}
