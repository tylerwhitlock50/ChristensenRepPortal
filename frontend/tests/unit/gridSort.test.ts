/**
 * Unit tests for DataGrid's header sort (lib/gridSort.ts).
 *
 * Run with:  npm run test:unit -- gridSort
 *
 * Drives a real TanStack table with and without the defaults DataGrid now
 * passes. Pins the bug (TanStack's 'auto' sort on a small grid with blank
 * cells), the fix, and the "no value goes last both ways" rule.
 */
import {
  createTable,
  getCoreRowModel,
  getSortedRowModel,
  type ColumnDef,
  type TableOptionsResolved,
} from '@tanstack/vue-table'
import { compareCells, gridSortDefaults } from '../../src/lib/gridSort'

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
  id: string
  promise: string | null
  qty: number
  goal_pct: number | null
}

// Fewer than ten rows, blanks first — the shape that defeated 'auto'.
const data: Row[] = [
  { id: 'a', promise: null, qty: 9, goal_pct: null },
  { id: 'b', promise: '2026-12-01', qty: 100, goal_pct: 40 },
  { id: 'c', promise: null, qty: 10, goal_pct: 0 },
  { id: 'd', promise: '2026-11-15', qty: -2, goal_pct: 95 },
  { id: 'e', promise: '2027-01-03', qty: 0, goal_pct: null },
]

const columns: ColumnDef<Row, any>[] = [
  { id: 'promise', accessorKey: 'promise' },
  { id: 'qty', accessorKey: 'qty' },
  // "No goal" is not 0% — undefined, so it sits last whichever way.
  { id: 'goal_pct', accessorFn: (r) => r.goal_pct ?? undefined },
]

function sorted(id: string, desc: boolean, fixed: boolean): string[] {
  const table = createTable<Row>({
    data,
    columns,
    state: {},
    onStateChange: () => {},
    renderFallbackValue: null,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    ...(fixed ? { defaultColumn: gridSortDefaults } : {}),
  } as TableOptionsResolved<Row>)
  table.setOptions((prev) => ({
    ...prev,
    state: { ...table.initialState, sorting: [{ id, desc }] },
  }))
  return table.getRowModel().rows.map((r) => r.original.id)
}

/* --- the bug, as TanStack ships it ---------------------------------------- */
const broken = sorted('promise', false, false)
t(
  'default: a nullable date on a small grid does not come out in date order',
  JSON.stringify(broken.filter((x) => ['b', 'd', 'e'].includes(x))) === JSON.stringify(['d', 'b', 'e']) &&
    broken.indexOf('a') < broken.indexOf('d') && broken.indexOf('c') < broken.indexOf('d'),
  false,
)

/* --- the fix ------------------------------------------------------------- */
t('dates ascending: blanks first, then oldest', sorted('promise', false, true), ['a', 'c', 'd', 'b', 'e'])
t('dates descending: newest first, blanks last', sorted('promise', true, true), ['e', 'b', 'd', 'a', 'c'])
t('numbers ascending are numeric, not text', sorted('qty', false, true), ['d', 'e', 'a', 'c', 'b'])
t('numbers descending', sorted('qty', true, true), ['b', 'c', 'a', 'e', 'd'])
t('no-goal last when ascending', sorted('goal_pct', false, true), ['c', 'b', 'd', 'a', 'e'])
t('no-goal last when descending', sorted('goal_pct', true, true), ['d', 'b', 'c', 'a', 'e'])

/* --- comparator details -------------------------------------------------- */
t('text with digits reads them as numbers', compareCells('CA-9', 'CA-10') < 0, true)
t('case is ignored', compareCells('6.5 PRC', '6.5 prc'), 0)
t('blank equals blank', compareCells(null, ''), 0)
t('Dates compare by time', compareCells(new Date(1), new Date(2)) < 0, true)
t('booleans: false before true', compareCells(false, true) < 0, true)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
