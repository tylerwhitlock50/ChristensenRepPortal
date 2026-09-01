<script setup lang="ts" generic="T">
/**
 * The admin grid primitive — TanStack Table (headless) + Tailwind, which is the
 * trade TECH_STACK §2.4 made instead of pulling in a component kit.
 *
 * What it owns: sorting, global filtering, sticky header, and the scroll
 * container. What it deliberately does not own: what a cell looks like (use the
 * `cell-<columnId>` slots) and what the page does with the visible rows (it
 * emits them, so an export button can export exactly what is on screen).
 *
 * Phone behaviour: the admin is desktop-first but the admin also stands in a
 * warehouse holding a phone. Provide the `card` slot and small screens get a
 * stacked list plus a sort control instead of a table they have to drag
 * sideways. Without it, the table still scrolls horizontally — inside its own
 * wrapper, never the page.
 */
import { computed, ref, watch } from 'vue'
import {
  FlexRender,
  getCoreRowModel,
  getFacetedRowModel,
  getFacetedUniqueValues,
  getFilteredRowModel,
  getSortedRowModel,
  useVueTable,
} from '@tanstack/vue-table'
import type {
  Column,
  ColumnDef,
  ColumnFiltersState,
  Row,
  SortingState,
} from '@tanstack/vue-table'

/**
 * Per-column filters are OPT-IN via column meta:
 *
 *   { accessorKey: 'product_family', header: 'Family',
 *     meta: { filter: 'select' } }
 *
 * 'select' renders a dropdown fed by the column's distinct values (faceted
 * over the OTHER filters' results) and matches exactly; 'text' renders a
 * small search input and matches case-insensitive substring. Columns without
 * meta.filter — i.e. every existing consumer of this grid — get no filter UI
 * and no behaviour change. Filtered rows flow into `rowsChange`, so CSV
 * export always matches the screen.
 */
type ColumnFilterKind = 'text' | 'select'

const props = withDefaults(
  defineProps<{
    columns: ColumnDef<T, any>[]
    data: T[]
    /** Seeds the sort on first render; the user owns it after that. */
    initialSorting?: SortingState
    /** Supports `v-model:globalFilter`. */
    globalFilter?: string
    /** Render the built-in search box. Leave off if the page owns the input. */
    searchable?: boolean
    searchLabel?: string
    searchPlaceholder?: string
    /** Stable row identity — falls back to row index. */
    getRowId?: (row: T, index: number) => string
    /** Height of the scroll box that makes the sticky header useful. */
    maxHeight?: string
    /** Keeps columns readable; the wrapper scrolls, the page does not. */
    minWidth?: string
  }>(),
  {
    globalFilter: '',
    searchable: false,
    searchLabel: 'Search',
    searchPlaceholder: 'Search…',
    maxHeight: '65vh',
    minWidth: '44rem',
  },
)

const emit = defineEmits<{
  'update:globalFilter': [value: string]
  /** Sorted + filtered rows, in display order. This is what CSV export uses. */
  rowsChange: [rows: T[]]
}>()

const sorting = ref<SortingState>(
  props.initialSorting ? [...props.initialSorting] : [],
)

const filter = ref(props.globalFilter)
watch(
  () => props.globalFilter,
  (value) => {
    if (value !== filter.value) filter.value = value
  },
)

function setFilter(value: string) {
  filter.value = value
  emit('update:globalFilter', value)
}

const data = computed(() => props.data)

const columnFilters = ref<ColumnFiltersState>([])

/**
 * The opted-in filter kind, read off the RESOLVED column's def — never
 * re-derive the id from accessorKey here: TanStack also derives ids from
 * headers for accessorFn columns, and a parallel derivation would silently
 * skip exactly those.
 */
function metaFilterKind(def: {
  meta?: unknown
}): ColumnFilterKind | undefined {
  return (def.meta as { filter?: ColumnFilterKind } | undefined)?.filter
}

/**
 * Default filterFn, keyed off the column's declared kind: 'select' values
 * come from the facet list so they match exactly (substring would make
 * "PRC" swallow "6.5 PRC"); 'text' is the familiar case-insensitive
 * contains. A columnDef's own filterFn still wins — this is only the
 * default. (`table` is assigned below; filtering only ever runs after
 * setup, so the forward reference is safe.)
 */
function columnFilterFn(row: Row<T>, columnId: string, filterValue: unknown) {
  const value = String(row.getValue(columnId) ?? '')
  const def = table.getColumn(columnId)?.columnDef
  if (def && metaFilterKind(def) === 'select') {
    return value === String(filterValue)
  }
  return value.toLowerCase().includes(String(filterValue).toLowerCase().trim())
}

const table = useVueTable<T>({
  data,
  get columns() {
    return props.columns
  },
  getRowId: props.getRowId,
  defaultColumn: { filterFn: columnFilterFn },
  state: {
    get sorting() {
      return sorting.value
    },
    get globalFilter() {
      return filter.value
    },
    get columnFilters() {
      return columnFilters.value
    },
  },
  onSortingChange: (updater) => {
    sorting.value =
      typeof updater === 'function' ? updater(sorting.value) : updater
  },
  onGlobalFilterChange: (updater) => {
    setFilter(typeof updater === 'function' ? updater(filter.value) : updater)
  },
  onColumnFiltersChange: (updater) => {
    columnFilters.value =
      typeof updater === 'function' ? updater(columnFilters.value) : updater
  },
  getCoreRowModel: getCoreRowModel(),
  getSortedRowModel: getSortedRowModel(),
  getFilteredRowModel: getFilteredRowModel(),
  getFacetedRowModel: getFacetedRowModel(),
  getFacetedUniqueValues: getFacetedUniqueValues(),
})

const rows = computed(() => table.getRowModel().rows)
const visibleRows = computed(() => rows.value.map((r) => r.original))

watch(visibleRows, (value) => emit('rowsChange', value), { immediate: true })

function ariaSort(column: Column<T, unknown>) {
  if (!column.getCanSort()) return undefined
  const dir = column.getIsSorted()
  if (dir === 'asc') return 'ascending'
  if (dir === 'desc') return 'descending'
  return 'none'
}

function headerLabel(column: Column<T, unknown>) {
  const header = column.columnDef.header
  return typeof header === 'string' ? header : column.id
}

const sortableColumns = computed(() =>
  table.getAllLeafColumns().filter((c) => c.getCanSort()),
)
const activeSort = computed(() => sorting.value[0])

/* ---- per-column filter UI ---------------------------------------------- */

function filterKind(column: Column<T, unknown>): ColumnFilterKind | undefined {
  return metaFilterKind(column.columnDef)
}

/** Any column opted in → the desktop filter row exists at all. */
const hasColumnFilters = computed(() =>
  table.getAllLeafColumns().some((c) => filterKind(c)),
)

/** Select-kind columns, for the phone's stacked dropdowns. */
const selectFilterColumns = computed(() =>
  table.getAllLeafColumns().filter((c) => filterKind(c) === 'select'),
)

/**
 * Distinct values for a select filter, faceted: the options shrink to what
 * the other active filters leave visible. Sorted for scannability. The
 * column's OWN active value is always included even when the current data
 * no longer contains it (a data swap — account picker, in-stock toggle —
 * must not leave the select rendering blank while its filter still bites).
 */
function selectOptions(column: Column<T, unknown>): string[] {
  const keys = Array.from(column.getFacetedUniqueValues().keys())
  const active = columnFilterValue(column)
  if (active && !keys.includes(active)) keys.push(active)
  return keys
    .map((k) => String(k ?? ''))
    .filter((k) => k.trim() !== '')
    .sort((a, b) => a.localeCompare(b))
}

function setColumnFilter(column: Column<T, unknown>, value: string) {
  column.setFilterValue(value === '' ? undefined : value)
}

function columnFilterValue(column: Column<T, unknown>): string {
  const v = column.getFilterValue()
  return v == null ? '' : String(v)
}

function clearColumnFilters() {
  columnFilters.value = []
}

function onMobileSort(event: Event) {
  const id = (event.target as HTMLSelectElement).value
  sorting.value = id ? [{ id, desc: activeSort.value?.desc ?? false }] : []
}

function flipSortDirection() {
  const current = activeSort.value
  if (!current) return
  sorting.value = [{ id: current.id, desc: !current.desc }]
}

defineExpose({ table, visibleRows })
</script>

<template>
  <div>
    <div v-if="searchable" class="mb-3">
      <label class="block">
        <span class="sr-only">{{ searchLabel }}</span>
        <input
          type="search"
          :value="filter"
          :placeholder="searchPlaceholder"
          class="field sm:max-w-xs"
          @input="setFilter(($event.target as HTMLInputElement).value)"
        />
      </label>
    </div>

    <!-- The way back out of a filtered view — rendered only while one is on,
         so nobody has to hunt through the dropdowns for the one that's set. -->
    <div v-if="columnFilters.length" class="mb-2">
      <button type="button" class="btn-ghost text-[13px]" @click="clearColumnFilters">
        Clear filters ({{ columnFilters.length }})
      </button>
    </div>

    <!-- Phone select filters: outside the card-slot gate on purpose — a
         grid with no card slot still renders its (sideways-scrolling) table
         on phones, and the desktop filter row is buried inside that scroll.
         Text-kind columns are covered by global search. -->
    <div
      v-if="selectFilterColumns.length"
      class="mb-2 grid grid-cols-2 gap-2 sm:hidden"
    >
      <label v-for="c in selectFilterColumns" :key="c.id" class="min-w-0">
        <span class="sr-only">Filter by {{ headerLabel(c) }}</span>
        <select
          :value="columnFilterValue(c)"
          class="field"
          @change="setColumnFilter(c, ($event.target as HTMLSelectElement).value)"
        >
          <option value="">{{ headerLabel(c) }}: all</option>
          <option v-for="opt in selectOptions(c)" :key="opt" :value="opt">
            {{ opt }}
          </option>
        </select>
      </label>
    </div>

    <!-- Phone: stacked cards + an explicit sort control, since the sortable
         column headers live in the table that is hidden here. -->
    <template v-if="$slots.card">
      <div v-if="rows.length && sortableColumns.length" class="mb-2 flex gap-2 sm:hidden">
        <label class="min-w-0 flex-1">
          <span class="sr-only">Sort by</span>
          <select
            :value="activeSort?.id ?? ''"
            class="field"
            @change="onMobileSort"
          >
            <option value="">Default order</option>
            <option v-for="c in sortableColumns" :key="c.id" :value="c.id">
              {{ headerLabel(c) }}
            </option>
          </select>
        </label>
        <button
          type="button"
          class="btn-ghost shrink-0 disabled:opacity-50"
          :disabled="!activeSort"
          @click="flipSortDirection"
        >
          {{ activeSort?.desc ? 'Desc' : 'Asc' }}
        </button>
      </div>

      <div v-if="rows.length" class="divide-line divide-y sm:hidden">
        <div v-for="row in rows" :key="row.id" class="py-3 first:pt-0">
          <slot name="card" :row="row.original" />
        </div>
      </div>
      <div v-else class="sm:hidden">
        <slot name="empty">
          <p class="text-muted py-10 text-center text-[15px]">Nothing to show.</p>
        </slot>
      </div>
    </template>

    <!-- The scroll box. Horizontal scroll lives here, never on the page. -->
    <div
      class="border-line overflow-auto border"
      :class="$slots.card ? 'hidden sm:block' : ''"
      :style="{ maxHeight }"
      tabindex="0"
      role="region"
      aria-label="Data table"
    >
      <table class="w-full border-collapse text-[15px]" :style="{ minWidth }">
        <thead>
          <tr
            v-for="headerGroup in table.getHeaderGroups()"
            :key="headerGroup.id"
            class="text-left"
          >
            <th
              v-for="header in headerGroup.headers"
              :key="header.id"
              scope="col"
              :aria-sort="ariaSort(header.column)"
              class="u-label border-line bg-canvas sticky top-0 z-10 border-b whitespace-nowrap"
              :class="header.column.getCanSort() ? '' : 'px-3 py-2.5'"
            >
              <button
                v-if="header.column.getCanSort()"
                type="button"
                class="tap-target u-label flex w-full items-center gap-1.5 px-3 text-left"
                @click="header.column.toggleSorting()"
              >
                <FlexRender
                  :render="header.column.columnDef.header"
                  :props="header.getContext()"
                />
                <span class="text-line-2" aria-hidden="true">
                  {{
                    header.column.getIsSorted() === 'asc'
                      ? '▲'
                      : header.column.getIsSorted() === 'desc'
                        ? '▼'
                        : '↕'
                  }}
                </span>
              </button>
              <FlexRender
                v-else
                :render="header.column.columnDef.header"
                :props="header.getContext()"
              />
            </th>
          </tr>

          <!-- The filter row, only when some column opted in. Deliberately
               NOT sticky: the labels above stay pinned, the controls scroll
               away once set, and no pixel-height offset can drift. -->
          <tr v-if="hasColumnFilters" class="border-line border-b">
            <th
              v-for="column in table.getVisibleLeafColumns()"
              :key="column.id"
              scope="col"
              class="bg-canvas px-2 py-1.5 text-left font-normal"
            >
              <template v-if="filterKind(column) === 'select'">
                <label class="block">
                  <span class="sr-only">Filter by {{ headerLabel(column) }}</span>
                  <select
                    :value="columnFilterValue(column)"
                    class="field h-8 min-w-[6rem] text-[13px]"
                    @change="
                      setColumnFilter(
                        column,
                        ($event.target as HTMLSelectElement).value,
                      )
                    "
                  >
                    <option value="">All</option>
                    <option
                      v-for="opt in selectOptions(column)"
                      :key="opt"
                      :value="opt"
                    >
                      {{ opt }}
                    </option>
                  </select>
                </label>
              </template>
              <template v-else-if="filterKind(column) === 'text'">
                <label class="block">
                  <span class="sr-only">Filter by {{ headerLabel(column) }}</span>
                  <input
                    type="search"
                    :value="columnFilterValue(column)"
                    placeholder="Filter…"
                    class="field h-8 min-w-[6rem] text-[13px]"
                    @input="
                      setColumnFilter(
                        column,
                        ($event.target as HTMLInputElement).value,
                      )
                    "
                  />
                </label>
              </template>
            </th>
          </tr>
        </thead>

        <tbody class="divide-line divide-y">
          <tr v-for="row in rows" :key="row.id" class="bg-surface">
            <td
              v-for="cell in row.getVisibleCells()"
              :key="cell.id"
              class="px-3 py-2.5 align-top"
            >
              <slot
                :name="`cell-${cell.column.id}`"
                :row="row.original"
                :value="cell.getValue()"
              >
                <FlexRender
                  :render="cell.column.columnDef.cell"
                  :props="cell.getContext()"
                />
              </slot>
            </td>
          </tr>

          <tr v-if="!rows.length">
            <td :colspan="table.getVisibleLeafColumns().length" class="bg-surface">
              <slot name="empty">
                <p class="text-muted py-10 text-center text-[15px]">
                  Nothing to show.
                </p>
              </slot>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
