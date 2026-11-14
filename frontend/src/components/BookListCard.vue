<script setup lang="ts" generic="T">
/**
 * The shared frame of the two book lists on Sales Intel — Open orders and
 * Shipments (G03, G04), the lists outside reps used to pull from Tableau.
 *
 * Both are "every line in my book, cut down by a few filters, totalled, and
 * handed to Excel", so the frame is one component: a card whose header
 * carries the download (ExportMenu: Excel or CSV), a filter area the page
 * fills (its own dropdowns and toggles — the `filters` slot), a totals
 * strip, and the DataGrid with its search box and phone cards.
 *
 * What the totals and the download cover is what DataGrid emits — the rows
 * left after the page's filters AND the search box, in screen order — so the
 * totals, the file and the screen can never disagree. Pages that draw
 * grouping (Open orders prints the account only on the first row of each
 * account) listen to `rowsChange` for the same rows.
 *
 * The Excel file's header says what the sheet is: the page passes the title,
 * a description and its own filters in words (`exportDetails`: the date
 * window, the account, the toggles, data freshness); this card appends the
 * search box (DataGrid `filtersChange`) and the totals strip.
 *
 * Cell slots (`cell-<columnId>`), `card` and `empty` pass straight through
 * to DataGrid.
 */
import { computed, shallowRef, useSlots } from 'vue'
import type { ColumnDef, SortingState } from '@tanstack/vue-table'
import DataGrid from '@/components/DataGrid.vue'
import AppCard from '@/components/ui/AppCard.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import type { ExportColumn } from '@/lib/xlsx'
import type { BookListTotal } from '@/lib/bookLists'

const props = withDefaults(
  defineProps<{
    title: string
    rows: T[]
    columns: ColumnDef<T, any>[]
    /** The download's columns (Excel and CSV): raw values, with Excel types. */
    exportColumns: readonly ExportColumn<T>[]
    /** Download file name before the time stamp: `open-orders` → open-orders-2026-11-14-0930.xlsx */
    exportFilename: string
    /** Row 1 of the Excel sheet — what this is, naming the scope. Defaults to `title`. */
    exportTitle?: string
    /** One sentence on what the numbers mean. */
    exportDescription?: string | null
    /**
     * What the page's own controls narrowed (date window, account, toggles)
     * and the data freshness, in words. Falsy entries are dropped. The search
     * box and the totals are added here.
     */
    exportDetails?: readonly (string | null | undefined | false)[]
    /** The totals strip, computed over the rows on screen. */
    totals: (rows: T[]) => BookListTotal[]
    getRowId: (row: T, index: number) => string
    initialSorting?: SortingState
    searchPlaceholder?: string
    minWidth?: string
  }>(),
  {
    initialSorting: () => [],
    searchPlaceholder: 'Search…',
    minWidth: '60rem',
    exportTitle: undefined,
    exportDescription: null,
    exportDetails: () => [],
  },
)

const emit = defineEmits<{
  /** Sorted, filtered, searched rows, in display order. */
  rowsChange: [rows: T[]]
}>()

const search = shallowRef('')
const visible = shallowRef<T[]>([])

function onRows(rows: T[]) {
  visible.value = rows
  emit('rowsChange', rows)
}

const totalsLine = computed(() => props.totals(visible.value))

/** The grid's search box in words (DataGrid filtersChange). */
const gridFilters = shallowRef<string[]>([])

/* The page's filters, then the search box, then the totals strip — the
   sheet carries what the screen showed around the grid. */
const sheetDetails = computed(() => [
  ...props.exportDetails,
  ...gridFilters.value,
  totalsLine.value.length > 0 &&
    `Totals — ${totalsLine.value.map((t) => `${t.label}: ${t.value}`).join(' · ')}`,
])

/* Every cell-* slot the page gave us, handed on to the grid under the
   same name. */
const slots = useSlots()
const cellSlots = computed(() =>
  Object.keys(slots).filter((name): name is `cell-${string}` => name.startsWith('cell-')),
)
</script>

<template>
  <AppCard :title="title" :padded="false">
    <template #actions>
      <ExportMenu
        :rows="visible"
        :columns="exportColumns"
        :title="exportTitle ?? title"
        :filename="exportFilename"
        :description="exportDescription"
        :details="sheetDetails"
        :sheet-name="title"
      />
    </template>

    <div v-if="$slots.filters" class="border-line space-y-2 border-b p-3">
      <slot name="filters" />
    </div>

    <!-- The totals row: what is on screen, after every filter and the
         search box. Above the grid rather than under it, so a phone sees
         the answer before scrolling a hundred cards. -->
    <dl
      class="border-line bg-canvas flex flex-wrap gap-x-5 gap-y-1 border-b px-3 py-2"
      aria-label="Totals for the rows shown"
    >
      <div v-for="t in totalsLine" :key="t.label" class="flex items-baseline gap-1.5">
        <dt class="font-label text-muted text-[11px] font-semibold tracking-[0.12em] uppercase">
          {{ t.label }}
        </dt>
        <dd class="text-ink text-sm font-semibold tabular-nums">{{ t.value }}</dd>
      </div>
    </dl>

    <DataGrid
      :columns="columns"
      :data="rows"
      :initial-sorting="initialSorting"
      searchable
      :search-placeholder="searchPlaceholder"
      v-model:global-filter="search"
      :get-row-id="getRowId"
      :min-width="minWidth"
      class="p-3"
      @rows-change="onRows"
      @filters-change="gridFilters = $event"
    >
      <template v-for="name in cellSlots" :key="name" #[name]="slotProps">
        <slot :name="name" v-bind="slotProps" />
      </template>
      <template #card="{ row }">
        <slot name="card" :row="row" />
      </template>
      <template #empty>
        <slot name="empty">
          <p class="text-muted py-10 text-center text-[15px]">
            Nothing matches these filters.
          </p>
        </slot>
      </template>
    </DataGrid>
  </AppCard>
</template>
