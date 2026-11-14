<script setup lang="ts">
/**
 * Goal attainment per rep (023), on the shared DataGrid beside the execution
 * table. Two questions, in this order: who has actually set goals, and of
 * those, who is tracking against them.
 *
 * Coverage is the first column for a reason — an attainment percentage over
 * four accounts out of forty is not a rep's year, it is a sample. The grid
 * opens sorted by accounts behind, which is the row a sales manager is
 * looking for.
 */
import { ref } from 'vue'
import DataGrid from '@/components/DataGrid.vue'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import {
  currentGoalYear,
  useRepGoalAttainment,
  type RepGoalAttainment,
} from '@/composables/useAccountGoals'
import { count, money } from '@/lib/format'
import type { ExportColumn } from '@/lib/xlsx'
import type { ColumnDef } from '@tanstack/vue-table'

const year = currentGoalYear()
const reps = useRepGoalAttainment()

const search = ref('')
const visibleRows = ref<RepGoalAttainment[]>([])
/** The grid's own search, in words (DataGrid filtersChange). */
const gridFilters = ref<string[]>([])

function rowId(row: RepGoalAttainment) {
  return row.user_id ?? row.full_name ?? ''
}

/** "12 / 40" — goals set against the book they were set on. */
function coverage(row: RepGoalAttainment): string {
  return `${count(row.accounts_with_goal)} / ${count(row.assigned_accounts)}`
}

const columns: ColumnDef<RepGoalAttainment, any>[] = [
  { id: 'full_name', accessorFn: (row) => row.full_name ?? '', header: 'Rep' },
  {
    id: 'accounts_with_goal',
    accessorFn: (row) => row.accounts_with_goal,
    header: 'Goals set',
  },
  { id: 'target_total', accessorFn: (row) => row.target_total, header: 'Target' },
  { id: 'revenue_total', accessorFn: (row) => row.revenue_total, header: 'Actual' },
  {
    id: 'attainment_pct',
    // A rep with no goals shows '—': sort them below every real percentage
    // (undefined + DataGrid's sortUndefined 'last'), not tied with a real 0%.
    accessorFn: (row) => (row.accounts_with_goal > 0 ? (row.attainment_pct ?? 0) : undefined),
    header: '% of goal',
  },
  {
    id: 'accounts_behind',
    accessorFn: (row) => row.accounts_behind,
    header: 'Behind',
  },
]

/* ---- Download: the rows on screen, in screen order. */

/**
 * The view's percents are 0–100; Excel's % format wants a fraction. A rep
 * with no goals is blank, as the screen shows '—' rather than 0%.
 */
function goalFraction(row: RepGoalAttainment, pct: number | null): number | null {
  return row.accounts_with_goal > 0 ? (pct ?? 0) / 100 : null
}

const exportColumns: ExportColumn<RepGoalAttainment>[] = [
  { key: 'full_name', header: 'Rep' },
  { key: 'accounts_with_goal', header: 'Goals set', type: 'integer' },
  { key: 'assigned_accounts', header: 'Assigned accounts', type: 'integer' },
  { key: 'target_total', header: `${year} target`, type: 'money' },
  { key: 'revenue_total', header: 'Actual (invoiced)', type: 'money' },
  {
    key: 'attainment_pct',
    header: '% of goal',
    type: 'percent',
    format: (row) => goalFraction(row, row.attainment_pct),
  },
  {
    key: 'expected_pct',
    header: 'Expected by now %',
    type: 'percent',
    format: (row) => goalFraction(row, row.expected_pct),
  },
  {
    // The progress bar's on-track state, in words.
    key: 'on_pace',
    header: 'On pace',
    format: (row) =>
      row.accounts_with_goal > 0
        ? (row.attainment_pct ?? 0) >= (row.expected_pct ?? 0)
          ? 'Yes'
          : 'No'
        : null,
  },
  { key: 'accounts_behind', header: 'Accounts behind pace', type: 'integer' },
  { key: 'active', header: 'Active', format: (row) => (row.active ? 'Yes' : 'No') },
]

const EXPORT_DESCRIPTION =
  `Each rep's ${year} account goals added up, against revenue invoiced so far. ` +
  'Expected by now = where those goals should be today on pace (seasonal where the ' +
  'account has last-year history); Accounts behind pace counts accounts under it.'
</script>

<template>
  <AppCard>
    <template #header>
      <div class="min-w-0">
        <h2 class="u-label text-ink">Goals by rep · {{ year }}</h2>
        <p class="text-muted mt-1 text-[13px]">
          Rep-entered goals, against revenue booked so far
        </p>
      </div>
      <ExportMenu
        :rows="visibleRows"
        :columns="exportColumns"
        :title="`Goals by rep — ${year}`"
        :filename="`rep-goal-attainment-${year}`"
        :description="EXPORT_DESCRIPTION"
        :details="gridFilters"
        sheet-name="Goals by rep"
      />
    </template>

    <AsyncState
      :loading="reps.isPending.value"
      :error="reps.error.value"
      :has-data="reps.data.value !== undefined"
      :updated-at="reps.dataUpdatedAt.value"
      :empty="(reps.data.value?.length ?? 0) === 0"
      empty-title="No reps yet"
      empty-body="Create users in Supabase Auth, then set their sales_rep_key on the profile."
      @retry="reps.refetch()"
    >
      <DataGrid
        v-model:globalFilter="search"
        :columns="columns"
        :data="reps.data.value ?? []"
        :initial-sorting="[{ id: 'accounts_behind', desc: true }]"
        searchable
        search-label="Search reps"
        search-placeholder="Search reps…"
        :get-row-id="rowId"
        min-width="44rem"
        @rows-change="visibleRows = $event"
        @filters-change="gridFilters = $event"
      >
        <template #cell-full_name="{ row }">
          <span class="text-ink font-semibold">{{ row.full_name ?? '—' }}</span>
          <span v-if="!row.active" class="text-muted ml-1 text-[13px]">
            (inactive)
          </span>
        </template>

        <template #cell-accounts_with_goal="{ row }">
          <span class="text-ink tabular-nums">{{ coverage(row) }}</span>
        </template>

        <template #cell-target_total="{ row }">
          <span class="text-ink tabular-nums">{{ money(row.target_total) }}</span>
        </template>

        <template #cell-revenue_total="{ row }">
          <span class="text-ink tabular-nums">{{ money(row.revenue_total) }}</span>
        </template>

        <!-- The bar carries the pace marker, so a rep at 55% in August reads
             as fine or as late without the manager doing the arithmetic. -->
        <template #cell-attainment_pct="{ row }">
          <div v-if="row.accounts_with_goal > 0" class="min-w-28">
            <span class="text-ink tabular-nums">
              {{ Math.round(row.attainment_pct ?? 0) }}%
            </span>
            <GoalProgressBar
              height="sm"
              class="mt-1"
              :attainment-pct="row.attainment_pct ?? 0"
              :expected-pct="row.expected_pct ?? 0"
              :on-track="(row.attainment_pct ?? 0) >= (row.expected_pct ?? 0)"
              :label="`${row.full_name ?? 'Rep'} goal attainment`"
            />
          </div>
          <span v-else class="text-muted">—</span>
        </template>

        <template #cell-accounts_behind="{ row }">
          <AppBadge v-if="row.accounts_behind > 0" tone="late">
            {{ count(row.accounts_behind) }}
          </AppBadge>
          <span v-else class="text-muted tabular-nums">0</span>
        </template>

        <!-- Phone layout -->
        <template #card="{ row }">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0 flex-1">
              <p class="text-ink truncate font-semibold">
                {{ row.full_name ?? '—' }}
                <span v-if="!row.active" class="text-muted text-[13px] font-normal">
                  (inactive)
                </span>
              </p>
              <p class="text-muted mt-0.5 text-[15px]">
                {{ coverage(row) }} accounts with a goal
              </p>
              <template v-if="row.accounts_with_goal > 0">
                <p class="text-muted mt-0.5 text-[15px] tabular-nums">
                  {{ money(row.revenue_total) }} of {{ money(row.target_total) }} ·
                  {{ Math.round(row.attainment_pct ?? 0) }}%
                </p>
                <GoalProgressBar
                  height="sm"
                  class="mt-1"
                  :attainment-pct="row.attainment_pct ?? 0"
                  :expected-pct="row.expected_pct ?? 0"
                  :on-track="(row.attainment_pct ?? 0) >= (row.expected_pct ?? 0)"
                  :label="`${row.full_name ?? 'Rep'} goal attainment`"
                />
              </template>
            </div>
            <AppBadge v-if="row.accounts_behind > 0" tone="late">
              {{ count(row.accounts_behind) }} late
            </AppBadge>
          </div>
        </template>

        <template #empty>
          <p class="text-muted py-10 text-center text-[15px]">
            No reps match that search.
          </p>
        </template>
      </DataGrid>
    </AsyncState>
  </AppCard>
</template>
