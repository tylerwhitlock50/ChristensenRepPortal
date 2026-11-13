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

/*----------------------------------------------------------------------------
  MCP inline upload (not in the portal copy)

  A model that can reach this server but not Storage (claude.ai chat, a
  sandbox with an egress allow-list) sends the file in the tool call itself:
  base64, or the text of a .csv/.txt/.eml. These rules decode and check it
  before the server stores it under the caller's own JWT. They are MCP-only:
  orderDocuments.test.ts compares only the shared names above with the
  portal, and nothing here changes them.

  Storage checks only the declared Content-Type, so the bytes are sniffed
  here: a model must not be able to store any bytes as application/pdf by
  calling them "po.pdf". The portal trusts the extension; this is stricter.
----------------------------------------------------------------------------*/

/** Decoded bytes one call may carry inline, all documents together: 5 MB. */
export const MCP_INLINE_MAX_BYTES = 5 * 1024 * 1024

/** At most this many documents on one create_order_draft. */
export const MCP_INLINE_MAX_DOCUMENTS = 3

/** The longest file_name accepted (the stored name is cut to 100 anyway). */
export const MCP_FILE_NAME_MAX = 200

/** Types that may be sent as content_text (UTF-8) instead of base64. */
export const TEXT_DOCUMENT_TYPES: ReadonlySet<string> = new Set(['text/csv', 'text/plain', 'message/rfc822'])

export type DecodedDocument = { fileName: string; bytes: Uint8Array; contentType: string; sha256: string }

/** A document the model sent that cannot be stored; `code` is the refusal code. */
export class DocumentContentError extends Error {
  constructor(readonly code: string, message: string) {
    super(message)
  }
}

const MB = (n: number) => `${Math.round((n / (1024 * 1024)) * 10) / 10} MB`

/**
 * Strict base64: an optional `data:<type>;base64,` prefix, whitespace and
 * newlines ignored, the standard or url-safe alphabet, padding optional. The
 * size is estimated from the length BEFORE decoding, so an oversized string
 * is refused without being decoded.
 */
export function decodeBase64Strict(input: string, maxBytes: number): Uint8Array {
  const s = String(input ?? '').replace(/^\s*data:[^;,]*;base64,/i, '').replace(/\s+/g, '')
  const padding = s.endsWith('==') ? 2 : s.endsWith('=') ? 1 : 0
  const estimate = Math.floor((s.length * 3) / 4) - padding
  if (estimate > maxBytes) {
    throw new DocumentContentError('document_too_large', `it is about ${MB(estimate)}`)
  }
  if (!s.length) throw new DocumentContentError('document_empty', 'it is empty')
  if (!/^[A-Za-z0-9+/_-]*={0,2}$/.test(s) || s.length % 4 === 1) {
    throw new DocumentContentError('invalid_base64', 'content_base64 is not valid base64')
  }
  let std = s.replace(/=+$/, '').replace(/-/g, '+').replace(/_/g, '/')
  while (std.length % 4) std += '='
  let bin: string
  try {
    bin = atob(std)
  } catch {
    throw new DocumentContentError('invalid_base64', 'content_base64 is not valid base64')
  }
  const bytes = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i)
  if (!bytes.length) throw new DocumentContentError('document_empty', 'it is empty')
  return bytes
}

function startsWith(bytes: Uint8Array, sig: readonly number[], at = 0): boolean {
  if (bytes.length < at + sig.length) return false
  return sig.every((b, i) => bytes[at + i] === b)
}

const ascii = (s: string) => [...s].map((c) => c.charCodeAt(0))
const ZIP = [0x50, 0x4b, 0x03, 0x04]
const OLE = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]
const PDF = ascii('%PDF-')
const HEIC_BRANDS = new Set(['heic', 'heix', 'heim', 'heis', 'hevc', 'hevx', 'hevm', 'hevs', 'mif1', 'msf1'])

function findPdfHeader(bytes: Uint8Array): boolean {
  // Acrobat accepts the header anywhere in the first 1024 bytes.
  const end = Math.min(bytes.length - PDF.length, 1024)
  for (let i = 0; i <= end; i++) if (startsWith(bytes, PDF, i)) return true
  return false
}

/**
 * A magic-byte sniff of the declared type: null when the bytes are what the
 * extension says, else the reason. Text types are refused only on a NUL
 * byte: a CSV exported by Excel on Windows is often Windows-1252, not UTF-8,
 * and the portal takes it.
 */
export function contentMismatch(contentType: string, bytes: Uint8Array): string | null {
  const zip = startsWith(bytes, ZIP)
  const ole = startsWith(bytes, OLE)
  switch (contentType) {
    case 'application/pdf':
      return findPdfHeader(bytes) ? null : 'the bytes are not a PDF (no %PDF- header)'
    case 'image/png':
      return startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) ? null : 'the bytes are not a PNG image'
    case 'image/jpeg':
      return startsWith(bytes, [0xff, 0xd8, 0xff]) ? null : 'the bytes are not a JPEG image'
    case 'image/webp':
      return startsWith(bytes, ascii('RIFF')) && startsWith(bytes, ascii('WEBP'), 8) ? null : 'the bytes are not a WebP image'
    case 'image/heic': {
      const brand = bytes.length >= 12 ? String.fromCharCode(...bytes.slice(8, 12)) : ''
      return startsWith(bytes, ascii('ftyp'), 4) && HEIC_BRANDS.has(brand) ? null : 'the bytes are not a HEIC image'
    }
    case 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
      return zip ? null : ole ? 'the bytes are an old-style .xls workbook: name it .xls' : 'the bytes are not an .xlsx workbook'
    case 'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      return zip ? null : ole ? 'the bytes are an old-style .doc document: name it .doc' : 'the bytes are not a .docx document'
    case 'application/vnd.ms-excel':
      return ole ? null : zip ? 'the bytes are an .xlsx workbook: name it .xlsx' : 'the bytes are not an .xls workbook'
    case 'application/msword':
      return ole ? null : zip ? 'the bytes are a .docx document: name it .docx' : 'the bytes are not a .doc document'
    case 'application/vnd.ms-outlook':
      return ole ? null : 'the bytes are not an Outlook .msg message'
    default:
      if (TEXT_DOCUMENT_TYPES.has(contentType)) {
        return bytes.includes(0) ? 'the bytes are binary (they hold NUL bytes), not text' : null
      }
      return null
  }
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as unknown as BufferSource))
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('')
}

/**
 * One inline document → its checked bytes, or a DocumentContentError whose
 * message the model can act on. `remainingBytes` is what is left of
 * MCP_INLINE_MAX_BYTES in this call.
 */
export async function decodeDocumentInput(
  d: { file_name?: unknown; content_base64?: unknown; content_text?: unknown },
  remainingBytes: number,
): Promise<DecodedDocument> {
  const fileName = typeof d.file_name === 'string' ? d.file_name.trim() : ''
  if (!fileName) throw new DocumentContentError('invalid_input', '`file_name` is required, with its extension.')
  if (fileName.length > MCP_FILE_NAME_MAX) {
    throw new DocumentContentError('invalid_input', `\`file_name\` is over ${MCP_FILE_NAME_MAX} characters.`)
  }
  const contentType = ORDER_DOCUMENT_TYPES[fileExtension(fileName)]
  if (!contentType) {
    throw new DocumentContentError(
      'unsupported_type',
      `${fileName} is not a file type that can be attached. The name must end in one of: ${ORDER_DOCUMENT_EXTENSIONS}.`,
    )
  }
  const hasB64 = d.content_base64 !== undefined && d.content_base64 !== null
  const hasText = d.content_text !== undefined && d.content_text !== null
  if (hasB64 === hasText) {
    throw new DocumentContentError(
      'invalid_input',
      `${fileName}: send exactly one of content_base64 or content_text${hasB64 ? ', not both' : ''}.`,
    )
  }
  const tooLarge = (about: string) =>
    new DocumentContentError(
      'document_too_large',
      `${fileName} does not fit: ${about}, and inline documents are ${MB(MCP_INLINE_MAX_BYTES)} at most across all ` +
        'documents in one call. Use attach_order_document without content for an upload URL, or give the user the ' +
        'portal link.',
    )
  let bytes: Uint8Array
  if (hasText) {
    if (typeof d.content_text !== 'string') {
      throw new DocumentContentError('invalid_input', `${fileName}: content_text must be a string.`)
    }
    if (!TEXT_DOCUMENT_TYPES.has(contentType)) {
      throw new DocumentContentError(
        'invalid_input',
        `${fileName}: content_text is only for .csv, .txt and .eml files; send this file's bytes as content_base64.`,
      )
    }
    bytes = new TextEncoder().encode(d.content_text)
    if (bytes.length > remainingBytes) throw tooLarge(`it is ${MB(bytes.length)}`)
    if (!bytes.length) throw new DocumentContentError('document_empty', `${fileName} is empty.`)
  } else {
    if (typeof d.content_base64 !== 'string') {
      throw new DocumentContentError('invalid_input', `${fileName}: content_base64 must be a string.`)
    }
    try {
      bytes = decodeBase64Strict(d.content_base64, remainingBytes)
    } catch (e) {
      if (!(e instanceof DocumentContentError)) throw e
      if (e.code === 'document_too_large') throw tooLarge(e.message)
      if (e.code === 'document_empty') throw new DocumentContentError(e.code, `${fileName} is empty.`)
      throw new DocumentContentError(e.code, `${fileName}: ${e.message}. Send the file's bytes base64-encoded, unchanged.`)
    }
    const mismatch = contentMismatch(contentType, bytes)
    if (mismatch) {
      throw new DocumentContentError(
        'content_mismatch',
        `${fileName}: the name says .${fileExtension(fileName)} but ${mismatch}. Send the original file, or ask the ` +
          'user for it as a PDF or .xlsx, or to drop it on the order in the portal.',
      )
    }
  }
  return { fileName, bytes, contentType, sha256: await sha256Hex(bytes) }
}
