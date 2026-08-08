<script setup lang="ts">
/**
 * Every rep vs their aggregate current-year goal (public.v_rep_goal_dashboard):
 * shipped (invoiced) YTD and sold (orders written) YTD, each against the same
 * goal. "Behind pace" is the number a sales manager is scanning for, so a
 * rep whose shipped % trails the elapsed year gets the ember badge —
 * everything else stays quiet, same posture as the Execution tab.
 */
import { computed, ref } from 'vue'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { useRepGoals, type RepGoalRow } from '@/composables/useAdmin'
import { count, money } from '@/lib/format'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import type { ColumnDef } from '@tanstack/vue-table'

const goals = useRepGoals()

const search = ref('')
const visibleRows = ref<RepGoalRow[]>([])

const rows = computed(() => goals.data.value ?? [])
const periodYear = computed(() => rows.value[0]?.period_year ?? new Date().getFullYear())

/** How far through the calendar year we are, 0–100 — the pace yardstick. */
const yearElapsedPct = computed(() => {
  const now = new Date()
  const start = new Date(now.getFullYear(), 0, 1)
  const end = new Date(now.getFullYear() + 1, 0, 1)
  return ((now.getTime() - start.getTime()) / (end.getTime() - start.getTime())) * 100
})

const totals = computed(() => {
  const sum = (f: (r: RepGoalRow) => number) => rows.value.reduce((a, r) => a + f(r), 0)
  const goal = sum((r) => r.goal_total)
  const shipped = sum((r) => r.shipped_ytd)
  const booked = sum((r) => r.booked_ytd)
  return {
    goal,
    shipped,
    booked,
    shippedPct: goal > 0 ? (shipped / goal) * 100 : null,
    bookedPct: goal > 0 ? (booked / goal) * 100 : null,
  }
})

function pct(value: number | null): string {
  if (value == null || !Number.isFinite(value)) return '—'
  return `${Math.round(value)}%`
}

function behindPace(row: RepGoalRow): boolean {
  return row.shipped_pct != null && row.shipped_pct < yearElapsedPct.value
}

const tilesReady = computed(() => !goals.error.value && !goals.isPending.value)
const dash = '—'

const columns: ColumnDef<RepGoalRow, any>[] = [
  { id: 'full_name', accessorFn: (row) => row.full_name ?? '', header: 'Rep' },
  {
    id: 'assigned_accounts',
    accessorFn: (row) => row.assigned_accounts ?? 0,
    header: 'Accounts',
  },
  { id: 'goal_total', accessorFn: (row) => row.goal_total ?? 0, header: 'Goal' },
  { id: 'shipped_ytd', accessorFn: (row) => row.shipped_ytd ?? 0, header: 'Shipped YTD' },
  {
    id: 'shipped_pct',
    // No-goal reps sort to the bottom either way instead of masquerading as 0%.
    accessorFn: (row) => row.shipped_pct ?? -1,
    header: 'Shipped %',
  },
  { id: 'booked_ytd', accessorFn: (row) => row.booked_ytd ?? 0, header: 'Sold YTD' },
  {
    id: 'booked_pct',
    accessorFn: (row) => row.booked_pct ?? -1,
    header: 'Sold %',
  },
]

function rowId(row: RepGoalRow) {
  return row.user_id
}

function onExport() {
  const csvColumns: CsvColumn<RepGoalRow>[] = [
    { key: 'full_name', header: 'Rep' },
    { key: 'assigned_accounts', header: 'Assigned Accounts' },
    { key: 'accounts_with_goal', header: 'Accounts With Goal' },
    { key: 'goal_total', header: 'Goal' },
    { key: 'crm_goal_total', header: 'Goal (CRM-entered)' },
    { key: 'erp_goal_total', header: 'Goal (ERP fallback)' },
    { key: 'shipped_ytd', header: 'Shipped YTD' },
    { key: 'shipped_pct', header: 'Shipped % of Goal' },
    { key: 'booked_ytd', header: 'Sold YTD' },
    { key: 'booked_pct', header: 'Sold % of Goal' },
    { key: 'active', header: 'Active', format: (row) => (row.active ? 'Yes' : 'No') },
  ]
  exportCsv(`rep-goals-${periodYear.value}`, visibleRows.value, csvColumns)
}
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Goals
      </p>
      <h1 class="u-display mt-1 text-4xl">Reps vs goal, {{ periodYear }}</h1>
      <p class="text-muted mt-2 text-[15px]">
        Shipped and sold this year against each rep's aggregate account goal.
        {{ Math.round(yearElapsedPct) }}% of the year is gone — that's the pace to beat.
      </p>
    </header>

    <div class="bg-line border-line grid grid-cols-3 gap-px border">
      <StatTile label="Company goal" :value="tilesReady ? money(totals.goal) : dash" sub="all reps" />
      <StatTile
        label="Shipped YTD"
        :value="tilesReady ? money(totals.shipped) : dash"
        :sub="tilesReady && totals.shippedPct != null ? `${pct(totals.shippedPct)} of goal` : undefined"
      />
      <StatTile
        label="Sold YTD"
        :value="tilesReady ? money(totals.booked) : dash"
        :sub="tilesReady && totals.bookedPct != null ? `${pct(totals.bookedPct)} of goal` : undefined"
      />
    </div>

    <AppCard>
      <template #header>
        <div>
          <h2 class="u-label text-ink">By rep</h2>
          <p class="text-muted mt-1 text-[13px]">
            {{ visibleRows.length }} {{ visibleRows.length === 1 ? 'rep' : 'reps' }} ·
            goal is the CRM target where one exists, else the ERP yearly goal
          </p>
        </div>
        <AppButton variant="ghost" :disabled="!visibleRows.length" @click="onExport">
          Export CSV
        </AppButton>
      </template>

      <AsyncState
        :loading="goals.isPending.value"
        :error="goals.error.value"
        :empty="rows.length === 0"
        empty-title="No reps yet"
        empty-body="Create users in Supabase Auth, then set their sales_rep_key on the profile."
        @retry="goals.refetch()"
      >
        <DataGrid
          v-model:globalFilter="search"
          :columns="columns"
          :data="rows"
          :initial-sorting="[{ id: 'goal_total', desc: true }]"
          searchable
          search-label="Search reps"
          search-placeholder="Search reps…"
          :get-row-id="rowId"
          min-width="56rem"
          @rows-change="visibleRows = $event"
        >
          <template #cell-full_name="{ row }">
            <span class="text-ink font-semibold">{{ row.full_name ?? '—' }}</span>
            <span v-if="!row.active" class="text-muted ml-1 text-[13px]">
              (inactive)
            </span>
          </template>

          <template #cell-assigned_accounts="{ row }">
            <span class="text-ink tabular-nums">{{ count(row.assigned_accounts) }}</span>
            <span v-if="row.accounts_with_goal < row.assigned_accounts" class="text-muted ml-1 text-[13px]">
              ({{ count(row.accounts_with_goal) }} w/ goal)
            </span>
          </template>

          <template #cell-goal_total="{ row }">
            <span v-if="row.goal_total > 0" class="text-ink tabular-nums">
              {{ money(row.goal_total) }}
            </span>
            <span v-else class="text-muted">no goal</span>
          </template>

          <template #cell-shipped_ytd="{ row }">
            <span class="text-ink tabular-nums">{{ money(row.shipped_ytd) }}</span>
          </template>

          <template #cell-shipped_pct="{ row }">
            <AppBadge v-if="behindPace(row)" tone="late">
              {{ pct(row.shipped_pct) }}
            </AppBadge>
            <span v-else class="text-ink tabular-nums">{{ pct(row.shipped_pct) }}</span>
          </template>

          <template #cell-booked_ytd="{ row }">
            <span class="text-ink tabular-nums">{{ money(row.booked_ytd) }}</span>
          </template>

          <template #cell-booked_pct="{ row }">
            <span class="text-ink tabular-nums">{{ pct(row.booked_pct) }}</span>
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
                  Goal {{ row.goal_total > 0 ? money(row.goal_total) : '—' }} ·
                  {{ count(row.assigned_accounts) }} accounts
                </p>
                <p class="text-muted mt-0.5 text-[13px]">
                  Shipped {{ money(row.shipped_ytd) }} ({{ pct(row.shipped_pct) }}) ·
                  Sold {{ money(row.booked_ytd) }} ({{ pct(row.booked_pct) }})
                </p>
              </div>
              <AppBadge v-if="behindPace(row)" tone="late">behind</AppBadge>
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
  </div>
</template>
