<script setup lang="ts" generic="T">
/**
 * The shared frame of the two book lists on Sales Intel — Open orders and
 * Shipments (G03, G04), the lists outside reps used to pull from Tableau.
 *
 * Both are "every line in my book, cut down by a few filters, totalled, and
 * handed to Excel", so the frame is one component: a card whose header
 * carries the CSV export, a filter area the page fills (its own dropdowns
 * and toggles — the `filters` slot), a totals strip, and the DataGrid with
 * its search box and phone cards.
 *
 * What the totals and the export cover is what DataGrid emits — the rows
 * left after the page's filters AND the search box, in screen order — so the
 * totals, the CSV and the screen can never disagree. Pages that draw
 * grouping (Open orders prints the account only on the first row of each
 * account) listen to `rowsChange` for the same rows.
 *
 * Cell slots (`cell-<columnId>`), `card` and `empty` pass straight through
 * to DataGrid.
 */
import { computed, shallowRef, useSlots } from 'vue'
import type { ColumnDef, SortingState } from '@tanstack/vue-table'
import DataGrid from '@/components/DataGrid.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import type { BookListTotal } from '@/lib/bookLists'

const props = withDefaults(
  defineProps<{
    title: string
    rows: T[]
    columns: ColumnDef<T, any>[]
    csvColumns: CsvColumn<T>[]
    /** Export file name prefix; the date is appended (lib/csv.ts). */
    csvPrefix: string
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

function onExport() {
  exportCsv(props.csvPrefix, visible.value, props.csvColumns)
}

/* Every cell-* slot the page gave us, handed on to the grid under the
   same name. */
const slots = useSlots()
const cellSlots = computed(() =>
  Object.keys(slots).filter((name): name is `cell-${string}` => name.startsWith('cell-')),
)
</script>

<template>
  <AppCard :padded="false">
    <template #header>
      <h2 class="u-label text-ink">{{ title }}</h2>
      <AppButton variant="ghost" :disabled="visible.length === 0" @click="onExport">
        Export CSV
      </AppButton>
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
