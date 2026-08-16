/**
 * CSV export — the "small CSV helper" half of TECH_STACK §2.4.
 *
 * Dependency-free on purpose: this is the file that has to be obviously correct
 * when the untouched-accounts list lands in a sales manager's inbox. No date-fns,
 * no papaparse, nothing to audit but this.
 *
 * Three things it gets right that a `rows.map(r => r.join(',')).join('\n')`
 * one-liner does not:
 *
 *  1. RFC 4180 quoting — commas, embedded double quotes (doubled), and newlines.
 *  2. Formula injection — a value starting with `=`, `+`, `-`, or `@` is a live
 *     formula the moment Excel opens the file. Every such value is prefixed with
 *     an apostrophe. This file goes to management; a dealer name that happens to
 *     start with `=` must not execute.
 *  3. A UTF-8 BOM, because Excel on Windows otherwise reads the file as the
 *     system codepage and mangles every accented dealer name.
 */

/** Anything a cell can hold before it becomes text. */
export type CsvValue = string | number | boolean | Date | null | undefined

export type CsvColumn<T> = {
  /** Property name on the row — the value source when `format` is absent. */
  key: string
  /** Header text written to row 1. */
  header: string
  /** Derive the cell from the whole row (computed columns, Yes/No, money). */
  format?: (row: T) => CsvValue
}

/** Excel reads a lone `﻿` at byte 0 as "this file is UTF-8". */
export const CSV_BOM = '﻿'

/** RFC 4180: these force the field to be quoted. */
const NEEDS_QUOTES = /[",\r\n]/
/** OWASP CSV-injection leaders. Tab and CR are in here for the same reason. */
const FORMULA_LEAD = /^[=+\-@\t\r]/
/** `-1200` and `-3.5e4` are numbers, not formulas — don't apostrophe them. */
const PLAIN_NUMBER = /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/

function toText(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? '' : value.toISOString()
  }
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : ''
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  return String(value)
}

/**
 * One field, escaped. Exported because it is the part worth unit-testing.
 *
 * Order matters: the formula guard runs before quoting so the apostrophe ends
 * up inside the quotes rather than outside them.
 */
export function escapeCsvValue(value: unknown): string {
  let text = toText(value)
  if (text === '') return ''

  let quoted = NEEDS_QUOTES.test(text)

  if (FORMULA_LEAD.test(text) && !PLAIN_NUMBER.test(text)) {
    text = `'${text}`
    // Quote it too, so nothing downstream strips the guard as leading noise.
    quoted = true
  }

  return quoted ? `"${text.replace(/"/g, '""')}"` : text
}

function cellValue<T>(row: T, column: CsvColumn<T>): unknown {
  if (column.format) return column.format(row)
  return (row as unknown as Record<string, unknown>)[column.key]
}

/**
 * Rows + column spec → a CSV string, CRLF-delimited (what Excel expects).
 *
 * The BOM is off by default so the output is safe to hash, diff, or paste;
 * `downloadCsv` adds it. Pass `{ bom: true }` if you need it in the string.
 */
export function toCsv<T>(
  rows: readonly T[],
  columns: readonly CsvColumn<T>[],
  options: { bom?: boolean } = {},
): string {
  if (columns.length === 0) return options.bom ? CSV_BOM : ''

  const lines: string[] = [columns.map((c) => escapeCsvValue(c.header)).join(',')]

  for (const row of rows) {
    lines.push(columns.map((c) => escapeCsvValue(cellValue(row, c))).join(','))
  }

  const body = lines.join('\r\n')
  return options.bom ? CSV_BOM + body : body
}

/**
 * Hand the file to the browser. The object URL is revoked on the next tick —
 * revoking synchronously after `.click()` cancels the download in Safari.
 */
export function downloadCsv(filename: string, csv: string): void {
  const name = filename.toLowerCase().endsWith('.csv') ? filename : `${filename}.csv`
  const withBom = csv.startsWith(CSV_BOM) ? csv : CSV_BOM + csv

  const blob = new Blob([withBom], { type: 'text/csv;charset=utf-8;' })
  const url = URL.createObjectURL(blob)

  try {
    const link = document.createElement('a')
    link.href = url
    link.download = name
    link.rel = 'noopener'
    link.style.display = 'none'
    document.body.appendChild(link)
    link.click()
    link.remove()
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 0)
  }
}

/** `coverage` → `coverage-2026-07-31.csv`, in the user's local date. */
export function csvFilename(prefix: string, date: Date = new Date()): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  const stamp = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`
  return `${prefix}-${stamp}.csv`
}

/** Build + download in one call — the shape every export button wants. */
export function exportCsv<T>(
  prefix: string,
  rows: readonly T[],
  columns: readonly CsvColumn<T>[],
): void {
  downloadCsv(csvFilename(prefix), toCsv(rows, columns))
}

/**
 * The other direction: RFC 4180 text → rows of fields. Exists for the admin
 * price-list item upload ("Save as CSV" from the approved Excel sheet), and
 * stays dependency-free for the same reason everything above does.
 *
 * Handles quoted fields, doubled quotes inside them, embedded commas and
 * newlines, CRLF/LF/CR line ends, and a leading BOM. Blank lines are
 * dropped (a trailing newline is not a row). It does NOT undo Excel's
 * ="0123" wrapper or our own formula-guard apostrophe — the upload preview
 * shows exactly what will be saved, which is the honest behaviour.
 */
export function parseCsv(text: string): string[][] {
  const input = text.startsWith(CSV_BOM) ? text.slice(CSV_BOM.length) : text
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let inQuotes = false
  let sawAny = false

  const endField = () => {
    row.push(field)
    field = ''
  }
  const endRow = () => {
    endField()
    // A row of nothing but empty fields is a blank line, not data.
    if (row.some((f) => f !== '')) rows.push(row)
    row = []
  }

  for (let i = 0; i < input.length; i++) {
    const ch = input[i]
    if (inQuotes) {
      if (ch === '"') {
        if (input[i + 1] === '"') {
          field += '"'
          i++
        } else {
          inQuotes = false
        }
      } else {
        field += ch
      }
      continue
    }
    if (ch === '"' && field === '') {
      inQuotes = true
      sawAny = true
    } else if (ch === ',') {
      endField()
      sawAny = true
    } else if (ch === '\n' || ch === '\r') {
      if (ch === '\r' && input[i + 1] === '\n') i++
      endRow()
    } else {
      field += ch
      sawAny = true
    }
  }
  if (sawAny && (field !== '' || row.length > 0)) endRow()

  return rows
}
