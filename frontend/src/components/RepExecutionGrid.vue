<script setup lang="ts">
/**
 * Per-rep execution table (PRD §7) on the shared DataGrid, sourced from the
 * existing `useRepExecution()`. Overdue is the number a sales manager is
 * actually looking for, so it gets the ember badge and the table opens sorted
 * by it — everything else is quiet.
 */
import { ref } from 'vue'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import { useRepExecution, type RepSummary } from '@/composables/useAdmin'
import { count, daysAgo, shortDate } from '@/lib/format'
import type { ExportColumn } from '@/lib/xlsx'
import type { ColumnDef, Row } from '@tanstack/vue-table'

const reps = useRepExecution()

const search = ref('')
const visibleRows = ref<RepSummary[]>([])
/** The grid's own search, in words (DataGrid filtersChange). */
const gridFilters = ref<string[]>([])

function rowId(row: RepSummary) {
  return row.user_id ?? row.full_name ?? ''
}

/** Nulls first: "never logged in" is the row worth looking at. */
function byDateNullsFirst(a: Row<RepSummary>, b: Row<RepSummary>, columnId: string) {
  const av = a.getValue<string | null>(columnId)
  const bv = b.getValue<string | null>(columnId)
  if (av === bv) return 0
  if (!av) return -1
  if (!bv) return 1
  return av < bv ? -1 : 1
}

const columns: ColumnDef<RepSummary, any>[] = [
  { id: 'full_name', accessorFn: (row) => row.full_name ?? '', header: 'Rep' },
  {
    id: 'assigned_accounts',
    accessorFn: (row) => row.assigned_accounts ?? 0,
    header: 'Accounts',
  },
  {
    id: 'open_recommendations',
    accessorFn: (row) => row.open_recommendations ?? 0,
    header: 'Open',
  },
  {
    id: 'overdue_recommendations',
    accessorFn: (row) => row.overdue_recommendations ?? 0,
    header: 'Overdue',
  },
  {
    id: 'actions_last_30d',
    accessorFn: (row) => row.actions_last_30d ?? 0,
    header: 'Actions 30d',
  },
  {
    id: 'last_login_at',
    accessorKey: 'last_login_at',
    header: 'Last active',
    sortingFn: byDateNullsFirst,
  },
]

/* ---- Download: the rows on screen, in screen order. */
const exportColumns: ExportColumn<RepSummary>[] = [
  { key: 'full_name', header: 'Rep' },
  { key: 'rep_group_vendor_id', header: 'Rep group', type: 'text' },
  { key: 'assigned_accounts', header: 'Accounts', type: 'integer' },
  { key: 'open_recommendations', header: 'Open recommendations', type: 'integer' },
  { key: 'overdue_recommendations', header: 'Overdue recommendations', type: 'integer' },
  { key: 'actions_last_30d', header: 'Actions last 30 days', type: 'integer' },
  { key: 'last_action_date', header: 'Last action', type: 'date' },
  // Blank = never signed in (the screen's "never").
  { key: 'last_login_at', header: 'Last active', type: 'datetime' },
  { key: 'active', header: 'Active', format: (row) => (row.active ? 'Yes' : 'No') },
]

const EXPORT_TITLE = 'Rep execution — recommendations and activity by rep'
const EXPORT_DESCRIPTION =
  "Open = recommendations still open on the rep's accounts; Overdue = open and past " +
  'their due date; Actions = activities the rep logged in the last 30 days; ' +
  'Last active = last sign-in to the portal.'
</script>

<template>
  <AppCard>
    <template #header>
      <div class="min-w-0">
        <h2 class="u-label text-ink">By rep</h2>
        <p class="text-muted mt-1 text-[13px]">
          {{ visibleRows.length }} {{ visibleRows.length === 1 ? 'rep' : 'reps' }}
        </p>
      </div>
      <ExportMenu
        :rows="visibleRows"
        :columns="exportColumns"
        :title="EXPORT_TITLE"
        filename="rep-execution"
        :description="EXPORT_DESCRIPTION"
        :details="gridFilters"
        sheet-name="Rep execution"
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
        :initial-sorting="[{ id: 'overdue_recommendations', desc: true }]"
        searchable
        search-label="Search reps"
        search-placeholder="Search reps…"
        :get-row-id="rowId"
        min-width="40rem"
        @rows-change="visibleRows = $event"
        @filters-change="gridFilters = $event"
      >
        <template #cell-full_name="{ row }">
          <span class="text-ink font-semibold">{{ row.full_name ?? '—' }}</span>
          <span v-if="!row.active" class="text-muted ml-1 text-[13px]">
            (inactive)
          </span>
        </template>

        <template #cell-assigned_accounts="{ row }">
          <span class="text-ink tabular-nums">{{ count(row.assigned_accounts) }}</span>
        </template>

        <template #cell-open_recommendations="{ row }">
          <span class="text-ink tabular-nums">
            {{ count(row.open_recommendations) }}
          </span>
        </template>

        <template #cell-overdue_recommendations="{ row }">
          <AppBadge v-if="(row.overdue_recommendations ?? 0) > 0" tone="late">
            {{ count(row.overdue_recommendations) }}
          </AppBadge>
          <span v-else class="text-muted tabular-nums">0</span>
        </template>

        <template #cell-actions_last_30d="{ row }">
          <span class="text-ink tabular-nums">{{ count(row.actions_last_30d) }}</span>
        </template>

        <template #cell-last_login_at="{ row }">
          <span class="text-ink block whitespace-nowrap">
            {{ daysAgo(row.last_login_at) }}
          </span>
          <span v-if="row.last_login_at" class="text-muted block text-[13px]">
            {{ shortDate(row.last_login_at) }}
          </span>
        </template>

        <!-- Phone layout -->
        <template #card="{ row }">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-ink truncate font-semibold">
                {{ row.full_name ?? '—' }}
                <span v-if="!row.active" class="text-muted text-[13px] font-normal">
                  (inactive)
                </span>
              </p>
              <p class="text-muted mt-0.5 text-[15px]">
                {{ count(row.assigned_accounts) }} accounts ·
                {{ count(row.open_recommendations) }} open ·
                {{ count(row.actions_last_30d) }} actions
              </p>
              <p class="text-muted mt-0.5 text-[13px]">
                Last active {{ daysAgo(row.last_login_at) }}
              </p>
            </div>
            <AppBadge v-if="(row.overdue_recommendations ?? 0) > 0" tone="late">
              {{ count(row.overdue_recommendations) }} late
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
