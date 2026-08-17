/**
 * Unit tests for parseCsv in lib/csv.ts — the admin price-list item upload
 * reads real "Save as CSV from Excel" output through this.
 *
 * Run with:  npm run test:unit
 * Same frameworkless vite-node harness as ffl.test.ts.
 */
import { CSV_BOM, parseCsv } from '../../src/lib/csv'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(
      `FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`,
    )
  }
}

t('simple rows', parseCsv('a,b\nc,d'), [
  ['a', 'b'],
  ['c', 'd'],
])

t('CRLF line ends (what Excel writes)', parseCsv('a,b\r\nc,d\r\n'), [
  ['a', 'b'],
  ['c', 'd'],
])

t('bare CR line ends', parseCsv('a,b\rc,d'), [
  ['a', 'b'],
  ['c', 'd'],
])

t('leading BOM is stripped', parseCsv(`${CSV_BOM}a,b`), [['a', 'b']])

t('quoted field with a comma', parseCsv('"Bolt, 5in",9.99'), [
  ['Bolt, 5in', '9.99'],
])

t('doubled quotes inside a quoted field', parseCsv('"say ""hi""",x'), [
  ['say "hi"', 'x'],
])

t('newline inside a quoted field', parseCsv('"two\nlines",x'), [
  ['two\nlines', 'x'],
])

t('empty fields survive', parseCsv('a,,c'), [['a', '', 'c']])

t('trailing newline is not a row', parseCsv('a,b\n'), [['a', 'b']])

t('blank lines are dropped', parseCsv('a,b\n\n\nc,d\n'), [
  ['a', 'b'],
  ['c', 'd'],
])

t('a line of only commas is a blank line', parseCsv('a,b\n,,\nc,d'), [
  ['a', 'b'],
  ['c', 'd'],
])

t('empty string yields no rows', parseCsv(''), [])

t('whitespace is preserved inside fields', parseCsv(' a ,b'), [[' a ', 'b']])

t(
  'a realistic price sheet',
  parseCsv(
    'part_id,description,unit_price\r\n' +
      'CA-556-BBL,"Barrel, 5.56, 16in",340.00\r\n' +
      'CA-762-BBL,,415.50\r\n',
  ),
  [
    ['part_id', 'description', 'unit_price'],
    ['CA-556-BBL', 'Barrel, 5.56, 16in', '340.00'],
    ['CA-762-BBL', '', '415.50'],
  ],
)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
