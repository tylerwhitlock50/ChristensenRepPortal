import type { Row, SortingFn } from '@tanstack/vue-table'

/**
 * DataGrid's default column sort, made safe for blank cells.
 *
 * TanStack's 'auto' sort picks a comparator by sampling rows — and in
 * table-core 8.21 it samples `flatRows.slice(10)`, i.e. row 10 ONWARD. On a
 * grid of ten rows or fewer (or one whose later rows are blank) it finds no
 * string and falls back to 'basic', whose `a > b` treats null as neither
 * greater nor smaller than a string. A nullable column (promise date,
 * chambering, family…) then "sorts" into an order that depends on where the
 * blanks started, and clicking the header looks like it does nothing.
 *
 * This comparator:
 *  - puts null / '' below every real value (first ascending, last descending)
 *  - compares numbers numerically and booleans as 0/1
 *  - compares Dates by time
 *  - compares everything else as text, with digits read as numbers ("9" < "10")
 *    and case ignored — so "6.5 PRC" and "6.5 prc" tie.
 *
 * A column that means "no value, not lowest value" (no goal set, no prior
 * year) should return `undefined` from its accessor instead: DataGrid sets
 * `sortUndefined: 'last'`, which keeps those rows at the bottom whichever way
 * the header points. A column's own `sortingFn` still wins over this default.
 */
export function compareCells(a: unknown, b: unknown): number {
  const aBlank = a == null || a === ''
  const bBlank = b == null || b === ''
  if (aBlank || bBlank) return aBlank === bBlank ? 0 : aBlank ? -1 : 1

  if (typeof a === 'number' && typeof b === 'number') {
    return a === b ? 0 : a < b ? -1 : 1
  }
  if (typeof a === 'boolean' && typeof b === 'boolean') {
    return Number(a) - Number(b)
  }
  if (a instanceof Date && b instanceof Date) {
    return a.getTime() - b.getTime()
  }
  return collator.compare(String(a), String(b))
}

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })

export const gridSortingFn: SortingFn<any> = (rowA: Row<any>, rowB: Row<any>, columnId: string) =>
  compareCells(rowA.getValue(columnId), rowB.getValue(columnId))

/** Spread into DataGrid's `defaultColumn`. Exported so the unit test drives the same pair. */
export const gridSortDefaults = {
  sortingFn: gridSortingFn,
  sortUndefined: 'last' as const,
}
