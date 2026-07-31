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
  getFilteredRowModel,
  getSortedRowModel,
  useVueTable,
} from '@tanstack/vue-table'
import type { Column, ColumnDef, SortingState } from '@tanstack/vue-table'

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

const table = useVueTable<T>({
  data,
  get columns() {
    return props.columns
  },
  getRowId: props.getRowId,
  state: {
    get sorting() {
      return sorting.value
    },
    get globalFilter() {
      return filter.value
    },
  },
  onSortingChange: (updater) => {
    sorting.value =
      typeof updater === 'function' ? updater(sorting.value) : updater
  },
  onGlobalFilterChange: (updater) => {
    setFilter(typeof updater === 'function' ? updater(filter.value) : updater)
  },
  getCoreRowModel: getCoreRowModel(),
  getSortedRowModel: getSortedRowModel(),
  getFilteredRowModel: getFilteredRowModel(),
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
