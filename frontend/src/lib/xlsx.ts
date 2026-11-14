/**
 * Excel export — the .xlsx half of the grid download button
 * (components/ui/ExportMenu.vue). The CSV half is lib/csv.ts.
 *
 * Dependency-free for the same reason csv.ts is: this file decides what lands
 * in a manager's inbox, and the npm options are either ~1 MB (exceljs) or no
 * longer published to npm (SheetJS). An .xlsx is a zip of a few XML files;
 * writing one sheet of text, numbers and dates is about this much code.
 *
 * What the file looks like when it opens:
 *
 *   Row 1   the title, bold            "In stock — available to sell"
 *   Row 2   when, and from where       "Downloaded Nov 13, 2026, 6:16 PM MST · Christensen Arms Rep Portal"
 *   Row 3…  what it is and what narrowed it (description, filters, "47 rows")
 *   blank
 *   header  bold, shaded, filter arrows on, frozen so it stays put
 *   data    numbers as numbers, dates as dates, everything else as text
 *
 * Things it gets right that a hand-rolled one usually does not:
 *
 *  1. Text stays text. UPCs and part numbers are written as strings, so Excel
 *     does not turn 840290526725 into 8.4E+11 or drop a leading zero — the
 *     thing CSV cannot prevent. Only real JS numbers (or a column declared
 *     numeric) become number cells.
 *  2. No formula injection. Strings are inline-string cells, which Excel never
 *     evaluates, so a dealer name starting with `=` is just text (csv.ts needs
 *     an apostrophe guard for this; here it is structural).
 *  3. Characters XML forbids (control codes, lone surrogates) are dropped
 *     instead of producing a file Excel calls corrupt, and Excel's own
 *     `_x0041_` escape is itself escaped so such text survives literally.
 *  4. Dates are serial numbers in the user's local calendar, so 2026-11-13
 *     is the 13th everywhere, never the 12th in Mountain time.
 *
 * The zip is deflated with the browser's own CompressionStream (Chrome/Edge
 * 103+, Firefox 113+, Safari 16.4+), so a year of company-wide shipment
 * lines is ~2 MB, not ~30 MB over every mail limit. Where CompressionStream
 * is missing it falls back to STORE (no compression), which every reader
 * also opens. buildXlsx() is the synchronous STORE build the tests read.
 */
import type { CsvColumn, CsvValue } from './csv'
import { downloadBlob, exportFilename, exportTimestamp } from './download'

/** How Excel should show a column. Absent: inferred from each value. */
export type ExportCellType =
  | 'text'
  | 'number'
  | 'integer'
  | 'money'
  /** A fraction: 0.25 shows as 25.0%. */
  | 'percent'
  | 'date'
  | 'datetime'

/**
 * A CSV column plus an optional Excel type — so one column list drives both
 * downloads. Every existing `CsvColumn[]` is already a valid `ExportColumn[]`.
 */
export type ExportColumn<T> = CsvColumn<T> & {
  type?: ExportCellType
}

export interface XlsxMeta {
  /** Row 1, and the workbook's document title. */
  title: string
  /** One sentence on what the rows are (what "Available" means, etc.). */
  description?: string | null
  /**
   * What narrowed the rows: filters, account, date range, data freshness.
   * Blank entries are dropped, so callers can write `cond && 'In stock only'`.
   */
  details?: readonly (string | null | undefined | false)[]
  /** Defaults to now; the printed timestamp and the file's created date. */
  generatedAt?: Date
  /** Tab name; cleaned to Excel's rules and cut to 31 characters. */
  sheetName?: string
  /** Printed after the timestamp. */
  source?: string
}

export const XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
const DEFAULT_SOURCE = 'Christensen Arms Rep Portal'

/* ---- styles (indexes into cellXfs in styles.xml below) ------------------ */
const S = {
  default: 0,
  title: 1,
  meta: 2,
  header: 3,
  date: 4,
  datetime: 5,
  money: 6,
  integer: 7,
  percent: 8,
} as const

/* ---- text hygiene -------------------------------------------------------- */

/** Code points XML 1.0 does not allow, lone surrogates included. */
const XML_INVALID = /[^\t\n\r -퟿-�\u{10000}-\u{10FFFF}]/gu
/**
 * Excel decodes `_xHHHH_` in cell text; escape the underscore to keep it
 * literal. A lookahead, so `_x0041_x0042_` (two sequences sharing an
 * underscore) gets both escaped.
 */
const EXCEL_ESCAPE = /_(?=x[0-9A-Fa-f]{4}_)/g
/** Excel's per-cell character limit. */
const MAX_CELL_CHARS = 32767

export function xmlEscape(text: string): string {
  return text
    .replace(XML_INVALID, '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function cellText(text: string): string {
  const clean = text.replace(XML_INVALID, '').replace(EXCEL_ESCAPE, '_x005F_')
  return xmlEscape(clean.length > MAX_CELL_CHARS ? clean.slice(0, MAX_CELL_CHARS) : clean)
}

/** Excel forbids `[]:*?/\` in tab names, a leading/trailing `'`, and > 31 chars. */
export function sheetNameFor(name: string | undefined): string {
  const cleaned = (name ?? '')
    .replace(XML_INVALID, '')
    .replace(/[[\]:*?/\\]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/^'+|'+$/g, '')
    .slice(0, 31)
    .trim()
  // "History" is reserved by Excel.
  return cleaned && cleaned.toLowerCase() !== 'history' ? cleaned : 'Sheet1'
}

/** 0 → A, 25 → Z, 26 → AA. */
export function columnLetter(index: number): string {
  let n = index + 1
  let out = ''
  while (n > 0) {
    const rem = (n - 1) % 26
    out = String.fromCharCode(65 + rem) + out
    n = Math.floor((n - 1) / 26)
  }
  return out
}

/* ---- values → cells ------------------------------------------------------ */

type Cell =
  | { t: 's'; text: string; style: number }
  | { t: 'n'; value: number; style: number }
  | { t: 'b'; value: boolean }

const EXCEL_EPOCH = Date.UTC(1899, 11, 30)
const DAY_MS = 86_400_000

/**
 * Excel serial for a local wall-clock time (1900 date system). Excel counts
 * a 29 Feb 1900 that never happened (Lotus compatibility), so the 1899-12-30
 * epoch is right from 1900-03-01 (serial 61) on and one day late before it.
 */
function serial(y: number, mo: number, d: number, h = 0, mi = 0, s = 0): number {
  const days = (Date.UTC(y, mo - 1, d, h, mi, s) - EXCEL_EPOCH) / DAY_MS
  return days < 61 ? days - 1 : days
}

function serialFromDate(date: Date, withTime: boolean): number | null {
  if (Number.isNaN(date.getTime())) return null
  const y = date.getFullYear()
  if (y < 1900 || y > 9999) return null
  return withTime
    ? serial(y, date.getMonth() + 1, date.getDate(), date.getHours(), date.getMinutes(), date.getSeconds())
    : serial(y, date.getMonth() + 1, date.getDate())
}

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/
const ISO_DATETIME = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/

/**
 * A date-only string is a calendar day: read its parts, never `new Date()`,
 * which would parse it as UTC midnight and show the day before in the US.
 */
function serialFromString(text: string, withTime: boolean): number | null {
  const day = ISO_DATE.exec(text)
  if (day) {
    const [y, mo, d] = [Number(day[1]), Number(day[2]), Number(day[3])]
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || y < 1900) return null
    return serial(y, mo, d)
  }
  if (ISO_DATETIME.test(text)) {
    return serialFromDate(new Date(text.replace(' ', 'T')), withTime)
  }
  return null
}

const PLAIN_DIGITS = /^(?:(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\.\d+)$/

/**
 * "1,234.50", "$1,234", "-$5", "$-5", "(12.00)", "25%" → a number; anything
 * else → null. Only used for columns DECLARED numeric, so a part number is
 * never at risk of this.
 */
function numberFromText(text: string): number | null {
  let s = text.trim()
  let negative = false
  if (/^\(.*\)$/.test(s)) {
    negative = true
    s = s.slice(1, -1).trim()
  }
  if (s.startsWith('-')) {
    negative = !negative
    s = s.slice(1).trim()
  } else if (s.startsWith('+')) {
    s = s.slice(1).trim()
  }
  if (s.startsWith('$')) s = s.slice(1).trim()
  if (s.startsWith('-')) {
    negative = !negative
    s = s.slice(1).trim()
  }
  const percent = s.endsWith('%')
  if (percent) s = s.slice(0, -1).trim()
  if (!PLAIN_DIGITS.test(s)) return null
  let value = Number(s.replace(/,/g, ''))
  if (!Number.isFinite(value)) return null
  if (percent) value /= 100
  return negative ? -value : value
}

const NUMERIC_STYLE: Record<'number' | 'integer' | 'money' | 'percent', number> = {
  number: S.default,
  integer: S.integer,
  money: S.money,
  percent: S.percent,
}

/** One value → one cell, or null for an empty cell. Exported for the tests. */
export function toCell(value: unknown, type?: ExportCellType): Cell | null {
  if (value === null || value === undefined) return null

  if (type === 'text') {
    const text =
      value instanceof Date ? (Number.isNaN(value.getTime()) ? '' : value.toISOString()) : String(value)
    return text === '' ? null : { t: 's', text, style: S.default }
  }

  if (type === 'number' || type === 'integer' || type === 'money' || type === 'percent') {
    const n = typeof value === 'number' ? value : typeof value === 'string' ? numberFromText(value) : null
    if (n !== null && Number.isFinite(n)) return { t: 'n', value: n, style: NUMERIC_STYLE[type] }
    // Not a number after all ("n/a", "—"): keep what the screen showed.
    return toCell(value, 'text')
  }

  if (type === 'date' || type === 'datetime') {
    const withTime = type === 'datetime'
    const n =
      value instanceof Date
        ? serialFromDate(value, withTime)
        : typeof value === 'string'
          ? serialFromString(value.trim(), withTime)
          : null
    if (n !== null) {
      return { t: 'n', value: withTime ? n : Math.floor(n), style: withTime ? S.datetime : S.date }
    }
    return toCell(value, 'text')
  }

  // Inferred.
  if (typeof value === 'number') {
    return Number.isFinite(value) ? { t: 'n', value, style: S.default } : null
  }
  if (typeof value === 'boolean') return { t: 'b', value }
  if (value instanceof Date) {
    const n = serialFromDate(value, true)
    return n === null ? null : { t: 'n', value: n, style: S.datetime }
  }
  const text = String(value)
  if (text === '') return null
  if (ISO_DATE.test(text)) {
    const n = serialFromString(text, false)
    if (n !== null) return { t: 'n', value: n, style: S.date }
  } else if (ISO_DATETIME.test(text)) {
    const n = serialFromString(text, true)
    if (n !== null) return { t: 'n', value: n, style: S.datetime }
  }
  return { t: 's', text, style: S.default }
}

function cellXml(ref: string, cell: Cell): string {
  if (cell.t === 's') {
    const style = cell.style ? ` s="${cell.style}"` : ''
    return `<c r="${ref}"${style} t="inlineStr"><is><t xml:space="preserve">${cellText(cell.text)}</t></is></c>`
  }
  if (cell.t === 'b') return `<c r="${ref}" t="b"><v>${cell.value ? 1 : 0}</v></c>`
  const style = cell.style ? ` s="${cell.style}"` : ''
  return `<c r="${ref}"${style}><v>${cell.value}</v></c>`
}

/** Rough on-screen width of a cell, in Excel's character units. */
function displayWidth(cell: Cell): number {
  if (cell.t === 's') {
    const longestLine = cell.text.split(/\r?\n/).reduce((m, l) => Math.max(m, l.length), 0)
    return longestLine
  }
  if (cell.t === 'b') return 5
  if (cell.style === S.date) return 10
  if (cell.style === S.datetime) return 19
  const digits = String(Math.round(Math.abs(cell.value))).length
  const grouping = Math.floor((digits - 1) / 3)
  if (cell.style === S.money) return digits + grouping + 5
  if (cell.style === S.integer) return digits + grouping + 1
  if (cell.style === S.percent) return digits + 4
  return Math.min(String(cell.value).length, 15)
}

function cellValueOf<T>(row: T, column: ExportColumn<T>): unknown {
  if (column.format) return column.format(row)
  return (row as unknown as Record<string, unknown>)[column.key]
}

/* ---- the package --------------------------------------------------------- */

const XML_HEAD = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
const NS_MAIN = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
const NS_REL = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
const NS_PKG_REL = 'http://schemas.openxmlformats.org/package/2006/relationships'

const CONTENT_TYPES =
  XML_HEAD +
  '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
  '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
  '<Default Extension="xml" ContentType="application/xml"/>' +
  '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
  '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' +
  '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' +
  '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>' +
  '</Types>'

const ROOT_RELS =
  XML_HEAD +
  `<Relationships xmlns="${NS_PKG_REL}">` +
  `<Relationship Id="rId1" Type="${NS_REL}/officeDocument" Target="xl/workbook.xml"/>` +
  '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>' +
  '</Relationships>'

const WORKBOOK_RELS =
  XML_HEAD +
  `<Relationships xmlns="${NS_PKG_REL}">` +
  `<Relationship Id="rId1" Type="${NS_REL}/worksheet" Target="worksheets/sheet1.xml"/>` +
  `<Relationship Id="rId2" Type="${NS_REL}/styles" Target="styles.xml"/>` +
  '</Relationships>'

const FONT = '<name val="Calibri"/><family val="2"/>'
const STYLES =
  XML_HEAD +
  `<styleSheet xmlns="${NS_MAIN}">` +
  '<numFmts count="3">' +
  '<numFmt numFmtId="164" formatCode="m/d/yyyy h:mm AM/PM"/>' +
  '<numFmt numFmtId="165" formatCode="&quot;$&quot;#,##0.00"/>' +
  '<numFmt numFmtId="166" formatCode="0.0%"/>' +
  '</numFmts>' +
  '<fonts count="4">' +
  `<font><sz val="11"/>${FONT}</font>` +
  `<font><b/><sz val="14"/>${FONT}</font>` +
  `<font><i/><sz val="10"/><color rgb="FF595959"/>${FONT}</font>` +
  `<font><b/><sz val="11"/>${FONT}</font>` +
  '</fonts>' +
  '<fills count="3">' +
  '<fill><patternFill patternType="none"/></fill>' +
  '<fill><patternFill patternType="gray125"/></fill>' +
  '<fill><patternFill patternType="solid"><fgColor rgb="FFE7E6E6"/><bgColor indexed="64"/></patternFill></fill>' +
  '</fills>' +
  '<borders count="2">' +
  '<border><left/><right/><top/><bottom/><diagonal/></border>' +
  '<border><left/><right/><top/><bottom style="thin"><color auto="1"/></bottom><diagonal/></border>' +
  '</borders>' +
  '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
  '<cellXfs count="9">' +
  '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
  '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>' +
  '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>' +
  '<xf numFmtId="0" fontId="3" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>' +
  '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
  '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
  '<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
  '<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
  '<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
  '</cellXfs>' +
  '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>' +
  '</styleSheet>'

/** The rows above the header, in order. Exported for the tests. */
export function metaLines(meta: XlsxMeta, rowCount: number, when: Date): string[] {
  const source = meta.source ?? DEFAULT_SOURCE
  const lines = [`Downloaded ${exportTimestamp(when)}${source ? ` · ${source}` : ''}`]
  if (meta.description) lines.push(meta.description)
  for (const d of meta.details ?? []) {
    if (typeof d === 'string' && d.trim() !== '') lines.push(d.trim())
  }
  lines.push(`${rowCount.toLocaleString('en-US')} ${rowCount === 1 ? 'row' : 'rows'}`)
  return lines
}

/** Rows + columns + title → the four XML parts that carry content. */
export function buildXlsxParts<T>(
  rows: readonly T[],
  columns: readonly ExportColumn<T>[],
  meta: XlsxMeta,
): Record<string, string> {
  const when = meta.generatedAt ?? new Date()
  const sheetName = sheetNameFor(meta.sheetName ?? meta.title)
  const lastCol = columnLetter(Math.max(0, columns.length - 1))

  const out: string[] = []
  let r = 0
  const textRow = (text: string, style: number, height?: number) => {
    r++
    const ht = height ? ` ht="${height}" customHeight="1"` : ''
    out.push(`<row r="${r}"${ht}>${cellXml(`A${r}`, { t: 's', text, style })}</row>`)
  }

  textRow(meta.title || 'Export', S.title, 20)
  for (const line of metaLines(meta, rows.length, when)) textRow(line, S.meta)
  r++ // one blank row between the title block and the table

  const headerRow = ++r
  const widths = columns.map((c) => Math.max(8, Math.min(60, c.header.length + 3)))
  out.push(
    `<row r="${headerRow}">` +
      columns
        .map((c, i) => cellXml(`${columnLetter(i)}${headerRow}`, { t: 's', text: c.header, style: S.header }))
        .join('') +
      '</row>',
  )

  for (const row of rows) {
    r++
    let cells = ''
    columns.forEach((column, i) => {
      const cell = toCell(cellValueOf(row, column), column.type)
      if (!cell) return
      widths[i] = Math.max(widths[i]!, Math.min(60, displayWidth(cell) + 2))
      cells += cellXml(`${columnLetter(i)}${r}`, cell)
    })
    out.push(`<row r="${r}">${cells}</row>`)
  }

  const lastRow = Math.max(r, headerRow)
  const filterRef = `A${headerRow}:${lastCol}${lastRow}`
  const firstData = headerRow + 1

  const sheet =
    XML_HEAD +
    `<worksheet xmlns="${NS_MAIN}" xmlns:r="${NS_REL}">` +
    '<sheetPr><pageSetUpPr fitToPage="1"/></sheetPr>' +
    `<dimension ref="A1:${lastCol}${lastRow}"/>` +
    '<sheetViews><sheetView workbookViewId="0">' +
    `<pane ySplit="${headerRow}" topLeftCell="A${firstData}" activePane="bottomLeft" state="frozen"/>` +
    `<selection pane="bottomLeft" activeCell="A${firstData}" sqref="A${firstData}"/>` +
    '</sheetView></sheetViews>' +
    '<sheetFormatPr defaultRowHeight="15"/>' +
    (columns.length
      ? '<cols>' +
        widths.map((w, i) => `<col min="${i + 1}" max="${i + 1}" width="${w}" customWidth="1"/>`).join('') +
        '</cols>'
      : '') +
    `<sheetData>${out.join('')}</sheetData>` +
    (columns.length ? `<autoFilter ref="${filterRef}"/>` : '') +
    '<pageMargins left="0.5" right="0.5" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>' +
    '<pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/>' +
    '</worksheet>'

  // The quoted, absolute range Excel itself writes for a sheet's filter.
  const quotedName = `'${sheetName.replace(/'/g, "''")}'`
  const absRef = `$A$${headerRow}:$${lastCol}$${lastRow}`
  const workbook =
    XML_HEAD +
    `<workbook xmlns="${NS_MAIN}" xmlns:r="${NS_REL}">` +
    '<bookViews><workbookView/></bookViews>' +
    `<sheets><sheet name="${xmlEscape(sheetName)}" sheetId="1" r:id="rId1"/></sheets>` +
    (columns.length
      ? '<definedNames>' +
        `<definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">${xmlEscape(quotedName)}!${absRef}</definedName>` +
        `<definedName name="_xlnm.Print_Titles" localSheetId="0">${xmlEscape(quotedName)}!$${headerRow}:$${headerRow}</definedName>` +
        '</definedNames>'
      : '') +
    '</workbook>'

  const created = when.toISOString().replace(/\.\d{3}Z$/, 'Z')
  const core =
    XML_HEAD +
    '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" ' +
    'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" ' +
    'xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' +
    `<dc:title>${xmlEscape(meta.title || 'Export')}</dc:title>` +
    (meta.description ? `<dc:description>${xmlEscape(meta.description)}</dc:description>` : '') +
    `<dc:creator>${xmlEscape(meta.source ?? DEFAULT_SOURCE)}</dc:creator>` +
    `<dcterms:created xsi:type="dcterms:W3CDTF">${created}</dcterms:created>` +
    '</cp:coreProperties>'

  return {
    '[Content_Types].xml': CONTENT_TYPES,
    '_rels/.rels': ROOT_RELS,
    'docProps/core.xml': core,
    'xl/workbook.xml': workbook,
    'xl/_rels/workbook.xml.rels': WORKBOOK_RELS,
    'xl/styles.xml': STYLES,
    'xl/worksheets/sheet1.xml': sheet,
  }
}

/* ---- zip (STORE) --------------------------------------------------------- */

const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

export function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

type ZipEntryIn = { name: string; data: Uint8Array }
/** `body` is what is written: `data` itself (method 0) or its raw deflate (8). */
type ZipEntry = ZipEntryIn & { body: Uint8Array; method: 0 | 8 }

/** A zip with every entry stored uncompressed. Names must be ASCII. */
export function zipStore(files: readonly ZipEntryIn[], when: Date): Uint8Array {
  return writeZip(
    files.map((f) => ({ ...f, body: f.data, method: 0 as const })),
    when,
  )
}

/** Raw DEFLATE via the platform's CompressionStream; null where unsupported. */
async function deflateRaw(data: Uint8Array): Promise<Uint8Array | null> {
  if (typeof CompressionStream === 'undefined') return null
  try {
    const stream = new Blob([data as BlobPart]).stream().pipeThrough(new CompressionStream('deflate-raw'))
    return new Uint8Array(await new Response(stream).arrayBuffer())
  } catch {
    return null
  }
}

/**
 * A zip with each entry deflated (method 8) where that is smaller and the
 * platform can, stored otherwise. The CRC is always over the original bytes.
 */
export async function zipDeflate(files: readonly ZipEntryIn[], when: Date): Promise<Uint8Array> {
  const entries = await Promise.all(
    files.map(async (f): Promise<ZipEntry> => {
      const packed = await deflateRaw(f.data)
      return packed && packed.length < f.data.length
        ? { ...f, body: packed, method: 8 }
        : { ...f, body: f.data, method: 0 }
    }),
  )
  return writeZip(entries, when)
}

function writeZip(files: readonly ZipEntry[], when: Date): Uint8Array {
  const dosTime = (when.getHours() << 11) | (when.getMinutes() << 5) | (when.getSeconds() >> 1)
  const dosDate =
    ((Math.min(Math.max(when.getFullYear(), 1980), 2107) - 1980) << 9) |
    ((when.getMonth() + 1) << 5) |
    when.getDate()
  const enc = new TextEncoder()

  const entries = files.map((f) => ({
    name: enc.encode(f.name),
    body: f.body,
    size: f.data.length,
    method: f.method,
    crc: crc32(f.data),
  }))
  const localSize = entries.reduce((sum, e) => sum + 30 + e.name.length + e.body.length, 0)
  const centralSize = entries.reduce((sum, e) => sum + 46 + e.name.length, 0)
  const buf = new Uint8Array(localSize + centralSize + 22)
  const view = new DataView(buf.buffer)

  let p = 0
  const u16 = (v: number) => {
    view.setUint16(p, v, true)
    p += 2
  }
  const u32 = (v: number) => {
    view.setUint32(p, v >>> 0, true)
    p += 4
  }
  const bytes = (b: Uint8Array) => {
    buf.set(b, p)
    p += b.length
  }

  const offsets: number[] = []
  for (const e of entries) {
    offsets.push(p)
    u32(0x04034b50) // local file header
    u16(20) // version needed (2.0)
    u16(0) // flags
    u16(e.method) // 0 STORE, 8 DEFLATE
    u16(dosTime)
    u16(dosDate)
    u32(e.crc)
    u32(e.body.length) // compressed size
    u32(e.size) // uncompressed size
    u16(e.name.length)
    u16(0) // extra length
    bytes(e.name)
    bytes(e.body)
  }

  const centralStart = p
  entries.forEach((e, i) => {
    u32(0x02014b50) // central directory header
    u16(20) // version made by
    u16(20) // version needed
    u16(0) // flags
    u16(e.method)
    u16(dosTime)
    u16(dosDate)
    u32(e.crc)
    u32(e.body.length)
    u32(e.size)
    u16(e.name.length)
    u16(0) // extra
    u16(0) // comment
    u16(0) // disk number start
    u16(0) // internal attributes
    u32(0) // external attributes
    u32(offsets[i]!)
    bytes(e.name)
  })

  const centralEnd = p
  u32(0x06054b50) // end of central directory
  u16(0)
  u16(0)
  u16(entries.length)
  u16(entries.length)
  u32(centralEnd - centralStart)
  u32(centralStart)
  u16(0) // comment length
  return buf
}

/* ---- the same columns, for the CSV half ---------------------------------- */

/** Drop binary-float noise (0.1 + 0.2 → 0.3) without rounding real digits. */
const denoise = (value: number) => Number(value.toPrecision(15))

/**
 * ExportColumn[] → CsvColumn[] for lib/csv.ts, which knows nothing of types.
 * A CSV has no cell formats, so a declared type is applied to the value:
 * a 'percent' fraction is written on the 0-100 scale the portal's CSVs
 * always used (0.553 → 55.3) and its header gains "(%)" if it has no "%";
 * money and other numbers are written as they are — never rounded to the
 * cent, so the column still sums to the screen's total — with float noise
 * dropped. Text and dates pass through untouched.
 */
export function csvColumnsFor<T>(columns: readonly ExportColumn<T>[]): CsvColumn<T>[] {
  return columns.map((column) => {
    const { type } = column
    if (type !== 'percent' && type !== 'money' && type !== 'number' && type !== 'integer') {
      return column
    }
    const header =
      type === 'percent' && !column.header.includes('%') ? `${column.header} (%)` : column.header
    return {
      key: column.key,
      header,
      format: (row: T) => {
        const value = cellValueOf(row, column)
        if (typeof value !== 'number' || !Number.isFinite(value)) return value as CsvValue
        return denoise(type === 'percent' ? value * 100 : value)
      },
    }
  })
}

/* ---- public API ---------------------------------------------------------- */

function packageFiles<T>(
  rows: readonly T[],
  columns: readonly ExportColumn<T>[],
  meta: XlsxMeta,
): ZipEntryIn[] {
  const enc = new TextEncoder()
  // [Content_Types].xml first: some readers sniff the first entry.
  return Object.entries(buildXlsxParts(rows, columns, meta)).map(([name, xml]) => ({
    name,
    data: enc.encode(xml),
  }))
}

/** Rows + columns + title → the bytes of an .xlsx file, stored (no compression). */
export function buildXlsx<T>(
  rows: readonly T[],
  columns: readonly ExportColumn<T>[],
  meta: XlsxMeta,
): Uint8Array {
  const when = meta.generatedAt ?? new Date()
  return zipStore(packageFiles(rows, columns, { ...meta, generatedAt: when }), when)
}

/** The same file, deflated where the platform can — what the button downloads. */
export async function buildXlsxCompressed<T>(
  rows: readonly T[],
  columns: readonly ExportColumn<T>[],
  meta: XlsxMeta,
): Promise<Uint8Array> {
  const when = meta.generatedAt ?? new Date()
  return zipDeflate(packageFiles(rows, columns, { ...meta, generatedAt: when }), when)
}

/** Build + download in one call — what the export button does. */
export async function exportXlsx<T>(
  prefix: string,
  rows: readonly T[],
  columns: readonly ExportColumn<T>[],
  meta: XlsxMeta,
): Promise<void> {
  const when = meta.generatedAt ?? new Date()
  const bytes = await buildXlsxCompressed(rows, columns, { ...meta, generatedAt: when })
  downloadBlob(exportFilename(prefix, 'xlsx', when), new Blob([bytes as BlobPart], { type: XLSX_MIME }))
}
