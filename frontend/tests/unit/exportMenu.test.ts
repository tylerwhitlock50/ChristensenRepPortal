/**
 * Unit tests for the grid-download plumbing that is not lib/xlsx.ts itself:
 * DataGrid's `filtersChange` (the words an export prints about what narrowed
 * the rows) and ExportMenu's closed state.
 *
 * Run with:  npm run test:unit -- exportMenu
 *
 * Same harness as asyncState.test.ts: no framework, vite-node, Vue's server
 * renderer. `immediate` watchers run during setup on the server too, so the
 * first emit of filtersChange is observable without a DOM.
 */
import { createSSRApp, h } from 'vue'
import { renderToString } from 'vue/server-renderer'
import DataGrid from '../../src/components/DataGrid.vue'
import ExportMenu from '../../src/components/ui/ExportMenu.vue'

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

type Row = { sku: string; family: string; qty: number }
const data: Row[] = [
  { sku: '801-06133-00', family: 'RIDGELINE FFT', qty: 3 },
  { sku: '801-15020-01', family: 'EVOKE', qty: 23 },
  { sku: '801-15009-01', family: 'EVOKE', qty: 13 },
]
const columns = [
  { id: 'sku', header: 'SKU', accessorKey: 'sku', meta: { filter: 'text' } },
  { id: 'family', header: 'Family', accessorKey: 'family', meta: { filter: 'select' } },
  { id: 'qty', header: 'Available', accessorKey: 'qty' },
]

/** Render a grid and collect what it emitted. */
async function grid(globalFilter: string) {
  const filters: string[][] = []
  const rows: Row[][] = []
  const app = createSSRApp({
    render: () =>
      h(DataGrid as never, {
        columns,
        data,
        globalFilter,
        onFiltersChange: (f: string[]) => filters.push(f),
        onRowsChange: (r: Row[]) => rows.push(r),
      }),
  })
  await renderToString(app)
  return { filters: filters.at(-1), rows: rows.at(-1) }
}

const none = await grid('')
t('no filter: no labels', none.filters, [])
t('no filter: every row', none.rows?.length, 3)

const searched = await grid('  evoke ')
t('search: label quotes the trimmed term', searched.filters, ['Search: “evoke”'])
t('search: rows narrowed to match', searched.rows?.map((r) => r.sku), ['801-15020-01', '801-15009-01'])

/* --- the closed menu ---------------------------------------------------- */
async function menu(props: Record<string, unknown>): Promise<string> {
  const app = createSSRApp({
    render: () =>
      h(ExportMenu as never, {
        columns: [{ key: 'sku', header: 'SKU' }],
        title: 'In stock',
        filename: 'in-stock',
        ...props,
      }),
  })
  return renderToString(app)
}

/** The boolean attribute, not the `disabled:` Tailwind variants in the class list. */
const DISABLED_ATTR = /<button[^>]*\sdisabled(?=[\s>=])/
const empty = await menu({ rows: [] })
t('no rows: trigger disabled', DISABLED_ATTR.test(empty), true)
t('no rows: says why', empty.includes('Nothing to download'), true)
const some = await menu({ rows: data })
t('rows: trigger enabled', DISABLED_ATTR.test(some), false)
t('closed: no menu in the DOM', some.includes('role="menu"'), false)
t('trigger announces a menu', some.includes('aria-haspopup="menu"') && some.includes('aria-expanded="false"'), true)
t('trigger name says which list it downloads', some.includes('aria-label="Download In stock"'), true)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
