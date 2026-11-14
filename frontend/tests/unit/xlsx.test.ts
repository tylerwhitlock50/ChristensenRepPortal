/**
 * Unit tests for lib/xlsx.ts (the Excel half of the grid download) and the
 * file-name/time-stamp helpers in lib/download.ts.
 *
 * Run with:  npm run test:unit -- xlsx
 *
 * Same no-framework harness as ffl.test.ts. The zip is read back with a
 * small STORE-only reader below, so the test proves the bytes are a valid
 * package (every CRC, size and offset) and not just that a string was built.
 * Run with TZ=America/Denver to match the printed-time-stamp assertions —
 * the runner does not set it, so those are written to hold in any zone.
 */
import { inflateRawSync } from 'node:zlib'
import {
  buildXlsx,
  buildXlsxCompressed,
  csvColumnsFor,
  buildXlsxParts,
  columnLetter,
  crc32,
  metaLines,
  sheetNameFor,
  toCell,
  xmlEscape,
  type ExportColumn,
} from '../../src/lib/xlsx'
import { exportFilename } from '../../src/lib/download'
import { toCsv } from '../../src/lib/csv'

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

/* --- a small zip reader (STORE + DEFLATE), to check the writer against ---- */
const methods = new Map<string, number>()
function readZip(buf: Uint8Array): Map<string, string> {
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
  const dec = new TextDecoder()
  const eocd = buf.length - 22
  if (view.getUint32(eocd, true) !== 0x06054b50) throw new Error('no end-of-central-directory')
  const count = view.getUint16(eocd + 10, true)
  const cdSize = view.getUint32(eocd + 12, true)
  let p = view.getUint32(eocd + 16, true)
  if (p + cdSize !== eocd) throw new Error('central directory size/offset disagree')
  const out = new Map<string, string>()
  for (let i = 0; i < count; i++) {
    if (view.getUint32(p, true) !== 0x02014b50) throw new Error(`bad central header ${i}`)
    const method = view.getUint16(p + 10, true)
    const crc = view.getUint32(p + 16, true)
    const size = view.getUint32(p + 20, true)
    const nameLen = view.getUint16(p + 28, true)
    const local = view.getUint32(p + 42, true)
    const name = dec.decode(buf.subarray(p + 46, p + 46 + nameLen))
    if (method !== 0 && method !== 8) throw new Error(`${name}: method ${method}`)
    const usize = view.getUint32(p + 24, true)
    if (view.getUint32(local, true) !== 0x04034b50) throw new Error(`${name}: bad local header`)
    const localNameLen = view.getUint16(local + 26, true)
    const start = local + 30 + localNameLen + view.getUint16(local + 28, true)
    const raw = buf.subarray(start, start + size)
    const data = method === 8 ? new Uint8Array(inflateRawSync(raw)) : raw
    if (data.length !== usize) throw new Error(`${name}: size mismatch`)
    if (crc32(data) !== crc) throw new Error(`${name}: CRC mismatch`)
    methods.set(name, method)
    out.set(name, dec.decode(data))
    p += 46 + nameLen + view.getUint16(p + 30, true) + view.getUint16(p + 32, true)
  }
  return out
}

/* --- crc32 against the standard check value ------------------------------ */
t('crc32("123456789") is the IEEE check value', crc32(new TextEncoder().encode('123456789')), 0xcbf43926)

/* --- column letters ------------------------------------------------------ */
t('A', columnLetter(0), 'A')
t('Z', columnLetter(25), 'Z')
t('AA', columnLetter(26), 'AA')
t('AZ', columnLetter(51), 'AZ')
t('ZZ', columnLetter(701), 'ZZ')
t('AAA', columnLetter(702), 'AAA')

/* --- sheet names --------------------------------------------------------- */
t('forbidden characters become spaces', sheetNameFor('In stock: [today]'), 'In stock today')
t('cut to 31 characters', sheetNameFor('x'.repeat(40)).length, 31)
t('blank falls back', sheetNameFor('  '), 'Sheet1')
t('reserved History falls back', sheetNameFor('History'), 'Sheet1')
t('edge apostrophes dropped', sheetNameFor("'quoted'"), 'quoted')

/* --- escaping ------------------------------------------------------------ */
t('xml escape', xmlEscape(`a & b < c > "d"`), 'a &amp; b &lt; c &gt; &quot;d&quot;')
{
  const parts = buildXlsxParts([{ a: '_x0041_x0042_' }], [{ key: 'a', header: 'A' }], { title: 't', generatedAt: new Date(2026, 0, 1) })
  t('overlapping _xHHHH_ sequences both escaped', parts['xl/worksheets/sheet1.xml']!.includes('>_x005F_x0041_x005F_x0042_<'), true)
}
t('control characters dropped', xmlEscape('bell\u0007tab\tok'), 'belltab\tok')
t('lone surrogate dropped', xmlEscape('x\uD800y'), 'xy')
t('astral characters kept', xmlEscape('rifle 🔫'), 'rifle 🔫')

/* --- values → cells: text stays text ------------------------------------- */
t('UPC string stays text', toCell('840290526725'), { t: 's', text: '840290526725', style: 0 })
t('leading-zero part stays text', toCell('00123'), { t: 's', text: '00123', style: 0 })
t('formula-looking text is just text', toCell('=SUM(A1)'), { t: 's', text: '=SUM(A1)', style: 0 })
t('a number is a number', toCell(40), { t: 'n', value: 40, style: 0 })
t('NaN is empty', toCell(Number.NaN), null)
t('null is empty', toCell(null), null)
t('empty string is empty', toCell(''), null)
t('boolean', toCell(true), { t: 'b', value: true })
t('declared text keeps a number as text', toCell(12, 'text'), { t: 's', text: '12', style: 0 })

/* --- declared numeric types ---------------------------------------------- */
t('money from a number', toCell(2499.99, 'money'), { t: 'n', value: 2499.99, style: 6 })
t('money from "$1,234.50"', toCell('$1,234.50', 'money'), { t: 'n', value: 1234.5, style: 6 })
t('money from "-$5"', toCell('-$5', 'money'), { t: 'n', value: -5, style: 6 })
t('money from "(12.00)"', toCell('(12.00)', 'money'), { t: 'n', value: -12, style: 6 })
t('percent from "25%"', toCell('25%', 'percent'), { t: 'n', value: 0.25, style: 8 })
t('percent fraction', toCell(0.253, 'percent'), { t: 'n', value: 0.253, style: 8 })
t('integer', toCell(1200, 'integer'), { t: 'n', value: 1200, style: 7 })
t('non-numeric in a numeric column stays text', toCell('n/a', 'number'), { t: 's', text: 'n/a', style: 0 })
t('a part number in a numeric column stays text', toCell('801-06531-00', 'number'), {
  t: 's',
  text: '801-06531-00',
  style: 0,
})

/* --- dates: a calendar day is never shifted by the time zone ------------- */
// 2026-11-13 is Excel serial 46339 (46022 = 2026-01-01).
t('ISO date inferred', toCell('2026-11-13'), { t: 'n', value: 46339, style: 4 })
t('declared date', toCell('2026-11-13', 'date'), { t: 'n', value: 46339, style: 4 })
t('1900-03-01 serial', toCell('1900-03-01', 'date'), { t: 'n', value: 61, style: 4 })
t('1900-02-28 serial (before Excel\'s phantom 29 Feb)', toCell('1900-02-28', 'date'), { t: 'n', value: 59, style: 4 })
t('1900-01-01 is serial 1', toCell('1900-01-01', 'date'), { t: 'n', value: 1, style: 4 })
t('invalid month stays text', toCell('2026-13-01'), { t: 's', text: '2026-13-01', style: 0 })
const local = new Date(2026, 10, 13, 18, 30, 0) // local wall clock, any zone
t('local Date → datetime serial', toCell(local), { t: 'n', value: 46339 + 18.5 / 24, style: 5 })
t('Date as a date drops the time', toCell(local, 'date'), { t: 'n', value: 46339, style: 4 })

/* --- the title block ----------------------------------------------------- */
const when = new Date(2026, 10, 13, 18, 16)
const lines = metaLines(
  { title: 'In stock', description: 'What it is.', details: ['Stock as of 5:45 PM', false, null, '  ', 'Guns only'] },
  1,
  when,
)
t('meta: timestamp line first', lines[0]!.startsWith('Downloaded Nov 13, 2026, 6:16 PM'), true)
t('meta: says where from', lines[0]!.endsWith('· Christensen Arms Rep Portal'), true)
t('meta: falsy and blank details dropped', lines.slice(1), ['What it is.', 'Stock as of 5:45 PM', 'Guns only', '1 row'])
t('meta: row count pluralised and grouped', metaLines({ title: 'x' }, 1234, when).at(-1), '1,234 rows')

/* --- the whole package --------------------------------------------------- */
type Row = { sku: string; desc: string; upc: string; qty: number; price: number | null; day: string | null }
const rows: Row[] = [
  { sku: '801-06531-00', desc: 'RL FFT <16 IN> & "x" _x0041_', upc: '840290526725', qty: 40, price: 2499.99, day: '2026-11-13' },
  { sku: '00123', desc: '=HYPERLINK("http://example.com")', upc: '012345678905', qty: -3, price: null, day: null },
]
const columns: ExportColumn<Row>[] = [
  { key: 'sku', header: 'SKU', type: 'text' },
  { key: 'desc', header: 'Description' },
  { key: 'upc', header: 'UPC', type: 'text' },
  { key: 'qty', header: 'Available', type: 'number' },
  { key: 'price', header: 'Price', type: 'money' },
  { key: 'day', header: 'Date' },
  { key: 'qty', header: 'Status', format: (r) => (r.qty < 0 ? 'Oversold' : 'OK') },
]
const meta = { title: 'In stock — available to sell', details: ['Guns only'], sheetName: "Rep's list", generatedAt: when }
const files = readZip(buildXlsx(rows, columns, meta))

t('package: every part present', [...files.keys()], [
  '[Content_Types].xml',
  '_rels/.rels',
  'docProps/core.xml',
  'xl/workbook.xml',
  'xl/_rels/workbook.xml.rels',
  'xl/styles.xml',
  'xl/worksheets/sheet1.xml',
])
const sheet = files.get('xl/worksheets/sheet1.xml')!
const workbook = files.get('xl/workbook.xml')!
t('sheet: title in A1', sheet.includes('<c r="A1" s="1" t="inlineStr"><is><t xml:space="preserve">In stock — available to sell</t>'), true)
// title, timestamp, "Guns only", "2 rows" → rows 1-4, blank 5, header 6, data 7-8
t('sheet: header row after a blank row', sheet.includes('<row r="6"><c r="A6" s="3" t="inlineStr">'), true)
t('sheet: header frozen', sheet.includes('<pane ySplit="6" topLeftCell="A7" activePane="bottomLeft" state="frozen"/>'), true)
t('sheet: filter arrows over header + data', sheet.includes('<autoFilter ref="A6:G8"/>'), true)
t('sheet: dimension', sheet.includes('<dimension ref="A1:G8"/>'), true)
t('sheet: UPC written as text', sheet.includes('<c r="C7" t="inlineStr"><is><t xml:space="preserve">840290526725</t>'), true)
t('sheet: leading zero kept', sheet.includes('<t xml:space="preserve">00123</t>'), true)
t('sheet: quantity is a number', sheet.includes('<c r="D7"><v>40</v></c>'), true)
t('sheet: negative quantity', sheet.includes('<c r="D8"><v>-3</v></c>'), true)
t('sheet: money styled', sheet.includes('<c r="E7" s="6"><v>2499.99</v></c>'), true)
t('sheet: null money left empty', sheet.includes('r="E8"'), false)
t('sheet: ISO date became a date', sheet.includes('<c r="F7" s="4"><v>46339</v></c>'), true)
t('sheet: format() column', sheet.includes('<t xml:space="preserve">Oversold</t>'), true)
t('sheet: markup escaped', sheet.includes('RL FFT &lt;16 IN&gt; &amp; &quot;x&quot; _x005F_x0041_'), true)
t('sheet: formula text is an inline string', sheet.includes('<t xml:space="preserve">=HYPERLINK(&quot;http://example.com&quot;)</t>'), true)
t('sheet: no formula cells at all', sheet.includes('<f>'), false)
t('workbook: tab name', workbook.includes(`<sheet name="Rep&apos;s list"`) || workbook.includes(`<sheet name="Rep's list"`), true)
t('workbook: filter range quotes the apostrophe', workbook.includes("'Rep''s list'!$A$6:$G$8"), true)
t('core: document title', files.get('docProps/core.xml')!.includes('<dc:title>In stock — available to sell</dc:title>'), true)

/* --- the deflated build the button downloads ---------------------------- */
const bigRows = Array.from({ length: 2000 }, (_, i) => ({ ...rows[0]!, sku: `801-${String(i).padStart(5, '0')}-00` }))
const stored = buildXlsx(bigRows, columns, meta)
const deflated = await buildXlsxCompressed(bigRows, columns, meta)
const storedParts = readZip(stored)
methods.clear()
const inflated = readZip(deflated)
t('deflated: every part round-trips byte for byte', [...inflated.entries()].every(([k, v]) => storedParts.get(k) === v), true)
t('deflated: the sheet is actually compressed (method 8)', methods.get('xl/worksheets/sheet1.xml'), 8)
t('deflated: at least 5x smaller than stored', stored.length / deflated.length > 5, true)

/* --- edge shapes --------------------------------------------------------- */
// title, timestamp, "0 rows" → rows 1-3, blank 4, header 5
const empty = buildXlsxParts([], columns, { title: 'Nothing', generatedAt: when })
t('no rows: header-only filter range', empty['xl/worksheets/sheet1.xml']!.includes('<autoFilter ref="A5:G5"/>'), true)
const noCols = readZip(buildXlsx(rows, [], { title: 'No columns', generatedAt: when }))
t('no columns: still a valid package without a filter', noCols.get('xl/worksheets/sheet1.xml')!.includes('autoFilter'), false)
const wide = buildXlsxParts([{ a: 'x'.repeat(40000) }], [{ key: 'a', header: 'A' }], { title: 'Long', generatedAt: when })
t('cell text capped at 32,767 characters', /x{32767}<\/t>/.test(wide['xl/worksheets/sheet1.xml']!) && !/x{32768}/.test(wide['xl/worksheets/sheet1.xml']!), true)

/* --- the CSV from the same columns is unchanged by the Excel types ------- */
t(
  'csv still plain rows, header on line 1',
  toCsv(rows.slice(0, 1), columns).split('\r\n')[0],
  'SKU,Description,UPC,Available,Price,Date,Status',
)

/* --- the CSV half writes declared types without float noise -------------- */
type Pct = { name: string; pct: number | null; amount: number; qty: number; note: string }
const pctCols: ExportColumn<Pct>[] = [
  { key: 'name', header: 'Rep' },
  { key: 'pct', header: '% of goal', type: 'percent' },
  { key: 'amount', header: 'Revenue', type: 'money' },
  { key: 'qty', header: 'Units', type: 'number' },
  { key: 'note', header: 'Note', type: 'percent' },
]
const pctCsv = toCsv(
  [{ name: 'Jane', pct: 0.553, amount: 0.1 + 0.2, qty: 1.1 * 3, note: 'n/a' }, { name: 'Sam', pct: null, amount: 5, qty: 2, note: '' }],
  csvColumnsFor(pctCols),
).split('\r\n')
t('csv: percent back on the 0-100 scale, money to the cent, no float noise', pctCsv[1], 'Jane,55.3,0.3,3.3,n/a')
t('csv: blanks stay blank', pctCsv[2], 'Sam,,5,2,')
t('csv: untyped columns untouched', csvColumnsFor(pctCols)[0], pctCols[0])
t('csv: percent header without % gains (%)', pctCsv[0], 'Rep,% of goal,Revenue,Units,Note (%)')
t(
  'csv: money is never rounded (column sums match the screen)',
  toCsv([{ name: 'x', pct: null, amount: 1.005, qty: 0, note: '' }], csvColumnsFor(pctCols)).split('\r\n')[1],
  'x,,1.005,0,',
)

/* --- file names ---------------------------------------------------------- */
t('file name carries date and time', exportFilename('in-stock', 'xlsx', when), 'in-stock-2026-11-13-1816.xlsx')
t('unsafe characters cleaned', exportFilename('ats/gaps: C&C Sports', '.csv', when), 'ats-gaps-C-C-Sports-2026-11-13-1816.csv')
t('blank prefix falls back', exportFilename('  ', 'xlsx', when), 'export-2026-11-13-1816.xlsx')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
