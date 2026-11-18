/**
 * Sections for DataGrid (`groupBy`): the sorted, filtered rows cut into named
 * groups — the In stock list by product family — without giving up the
 * grid's sort, search, filters or export. Pure, for tests/unit/gridGroup.test.ts.
 */
export interface GridGroup<R> {
  key: string
  rows: R[]
}

/**
 * Rows into groups. Inside a group the rows keep the order they came in (the
 * grid's sort); the groups themselves are ordered by `order`, or by name.
 */
export function groupRows<R>(
  rows: readonly R[],
  keyOf: (row: R) => string,
  order: (a: string, b: string) => number = (a, b) => a.localeCompare(b),
): GridGroup<R>[] {
  const byKey = new Map<string, R[]>()
  for (const row of rows) {
    const key = keyOf(row)
    const list = byKey.get(key)
    if (list) list.push(row)
    else byKey.set(key, [row])
  }
  return [...byKey.entries()]
    .map(([key, list]) => ({ key, rows: list }))
    .sort((a, b) => order(a.key, b.key))
}

export type GridItem<R> =
  | { kind: 'group'; group: GridGroup<R>; collapsed: boolean }
  | { kind: 'row'; row: R }

/**
 * What gets drawn: every group's header, and under each open group its rows,
 * until `limit` rows are on screen. Headers past the limit are still drawn —
 * the list of sections is the map of the page, and a closed section costs
 * one line. `drawable` is how many rows the open sections hold in all.
 */
export function drawItems<R>(
  groups: readonly GridGroup<R>[],
  collapsed: ReadonlySet<string>,
  limit: number,
): { items: GridItem<R>[]; drawn: number; drawable: number } {
  const items: GridItem<R>[] = []
  let drawn = 0
  let drawable = 0
  for (const group of groups) {
    const closed = collapsed.has(group.key)
    items.push({ kind: 'group', group, collapsed: closed })
    if (closed) continue
    drawable += group.rows.length
    for (const row of group.rows) {
      if (drawn >= limit) break
      items.push({ kind: 'row', row })
      drawn++
    }
  }
  return { items, drawn, drawable }
}
