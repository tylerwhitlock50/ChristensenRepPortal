/**
 * Unit tests for DataGrid's search box (lib/gridFilter.ts) — G08.
 *
 * Run with:  npm run test:unit -- gridFilter
 *
 * Drives a real TanStack table (table-core, which @tanstack/vue-table
 * re-exports) with and without the options DataGrid now passes, so the bug
 * is pinned as well as the fix: by default TanStack only searches the
 * columns whose value in ROW 0 is a string or number, and the first In stock
 * row had no chambering — "creedmoor" found nothing.
 */
import {
  createTable,
  getCoreRowModel,
  getFilteredRowModel,
  type ColumnDef,
  type TableOptionsResolved,
} from '@tanstack/vue-table'
import { globalFilterText, gridGlobalFilterOptions } from '../../src/lib/gridFilter'

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

interface Row {
  part_id: string
  chambering: string | null
  upc: string | null
  ats_qty: number
}

// Row 0 is a part with no chambering and no UPC — the shape that broke search.
const data: Row[] = [
  { part_id: 'CA-KIT-1', chambering: null, upc: null, ats_qty: 40 },
  { part_id: 'MPR-65', chambering: '6.5 Creedmoor', upc: '810034', ats_qty: 5 },
  { part_id: 'RIDGE-65', chambering: '6.5 CREEDMOOR', upc: '810099', ats_qty: 2 },
  { part_id: 'MESA-308', chambering: '.308 Win', upc: null, ats_qty: 0 },
]

const columns: ColumnDef<Row, any>[] = [
  { id: 'part_id', accessorKey: 'part_id' },
  { id: 'chambering', accessorKey: 'chambering' },
  { id: 'upc', accessorKey: 'upc' },
  { id: 'ats_qty', accessorKey: 'ats_qty' },
  // A button column: no accessor, never searched.
  { id: 'who', header: '' },
]

function search(term: string, fixed: boolean): string[] {
  const table = createTable<Row>({
    data,
    columns,
    state: {},
    onStateChange: () => {},
    renderFallbackValue: null,
    getCoreRowModel: getCoreRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    ...(fixed ? gridGlobalFilterOptions : {}),
  } as TableOptionsResolved<Row>)
  table.setOptions((prev) => ({
    ...prev,
    state: { ...table.initialState, globalFilter: term },
  }))
  return table.getRowModel().rows.map((r) => r.original.part_id)
}

/* --- the bug, as TanStack ships it ---------------------------------------- */
t('default: a null chambering in row 0 hides every Creedmoor', search('creedmoor', false), [])

/* --- the fix ------------------------------------------------------------- */
t('fixed: "creedmoor" finds both, case-insensitively', search('creedmoor', true), ['MPR-65', 'RIDGE-65'])
t('fixed: a UPC is searchable though row 0 has none', search('810099', true), ['RIDGE-65'])
t('fixed: the SKU still matches', search('mesa', true), ['MESA-308'])
t('fixed: numbers stay searchable', search('40', true), ['CA-KIT-1'])
t('fixed: surrounding spaces are ignored', search('  308 ', true), ['MESA-308'])
t('fixed: an empty term keeps every row', search('', true).length, 4)
t('fixed: no match is no rows, not an error', search('zzz', true), [])

/* --- the text a cell searches as ----------------------------------------- */
t('null is blank', globalFilterText(null), '')
t('undefined is blank', globalFilterText(undefined), '')
t('a string is itself', globalFilterText('6.5 PRC'), '6.5 PRC')
t('a number is its digits', globalFilterText(12), '12')
t('NaN is blank', globalFilterText(Number.NaN), '')
t('a boolean is not text', globalFilterText(true), '')
t('an object is not "[object Object]"', globalFilterText({ a: 1 }), '')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
