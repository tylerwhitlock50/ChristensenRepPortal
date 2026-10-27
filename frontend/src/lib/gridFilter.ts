import type { FilterFn } from '@tanstack/vue-table'

/**
 * DataGrid's search box (TanStack's "global filter"), made to search every
 * column with a value, whatever the first row holds.
 *
 * TanStack decides which columns the global filter may search by looking at
 * ROW 0 ONLY: a column joins the search when that row's value is a string or
 * a number. A null family, chambering or UPC on whichever SKU sorts first
 * dropped the whole column from search — on In stock, "creedmoor" found 0 of
 * the 9 Creedmoor rifles because the first row had no chambering (G08). The
 * grid now lets every accessor column take part (getColumnCanGlobalFilter),
 * and this filter fn turns each cell into text the same way on every row:
 * null and undefined are '', so a blank cell is simply not a match instead of
 * being decided by a different row.
 *
 * Strings and finite numbers are searchable, as before. Anything else
 * (booleans, objects, dates) is '' — searching "true" or "object" should not
 * match on a column nobody can see as text. Columns without an accessor (the
 * button columns) never take part: TanStack requires an accessorFn for that.
 */

/** A cell's searchable text. */
export function globalFilterText(value: unknown): string {
  if (typeof value === 'string') return value
  if (typeof value === 'number') return Number.isFinite(value) ? String(value) : ''
  return ''
}

/** Case-insensitive "contains", trimmed; an empty term matches everything. */
export const gridGlobalFilterFn: FilterFn<unknown> = (row, columnId, filterValue) => {
  const term = String(filterValue ?? '').trim().toLowerCase()
  if (!term) return true
  return globalFilterText(row.getValue(columnId)).toLowerCase().includes(term)
}

/** Spread into a table's options. Exported so the unit test drives the same pair. */
export const gridGlobalFilterOptions = {
  getColumnCanGlobalFilter: () => true,
  globalFilterFn: gridGlobalFilterFn,
}
