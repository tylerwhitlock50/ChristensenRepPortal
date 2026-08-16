<script setup lang="ts">
/**
 * How each rep group is doing overall.
 *
 * A rep group is the agency an ERP sales rep bills through
 * (erp.dim_sales_rep.vendor_id) — the same key profiles.rep_group_vendor_id
 * points at, so a group's number here is exactly the book its principal signs
 * in and sees. That is what makes this a different report from the per-rep
 * Goals tab: this one holds a whole agency to one total, whether it has one
 * portal login or five.
 *
 * Accounts whose assigned rep has no vendor land in "(No rep group)" rather
 * than being dropped, so these rows still add to the company total.
 */
import { computed, ref } from 'vue'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import {
  attainmentPct,
  useRepGroupPerformance,
  yearElapsedPct,
  yoyPct,
  type RepGroupRow,
} from '@/composables/useAdminReports'
import { count, money, shortDate } from '@/lib/format'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import type { ColumnDef } from '@tanstack/vue-table'

const query = useRepGroupPerformance()

const search = ref('')
const visibleRows = ref<RepGroupRow[]>([])

const rows = computed(() => query.data.value ?? [])

/** Where a group should be by today — the pace marker on every bar. */
const expectedPct = computed(() => yearElapsedPct())

function rowId(row: RepGroupRow) {
  return row.rep_group_id
}

function yoy(row: RepGroupRow) {
  return yoyPct(row.revenue_ytd, row.revenue_prior_ytd)
}

function yoyLabel(row: RepGroupRow): string {
  const pct = yoy(row)
  if (pct == null) return row.revenue_ytd > 0 ? 'new' : '—'
  return `${pct >= 0 ? '+' : '−'}${Math.abs(pct).toFixed(1)}%`
}

function yoyTone(row: RepGroupRow): string {
  const pct = yoy(row)
  if (pct == null) return 'text-muted'
  if (pct <= -10) return 'text-danger'
  if (pct >= 10) return 'text-brand'
  return 'text-ink-2'
}

function attainment(row: RepGroupRow) {
  return attainmentPct(row.revenue_ytd, row.goal_total)
}

/** Accounts touched in the last 30 days, as a whole percent. */
function coveragePct(row: RepGroupRow): number | null {
  if (row.accounts <= 0) return null
  return (row.contacted_30d / row.accounts) * 100
}

/** "Sports Inc · 3 reps" — who this row actually is. */
function whoLabel(row: RepGroupRow): string {
  const parts = [`${count(row.rep_count)} ${row.rep_count === 1 ? 'rep' : 'reps'}`]
  if (row.portal_users > 0) {
    parts.push(`${count(row.portal_users)} signed up`)
  }
  return parts.join(' · ')
}

const columns: ColumnDef<RepGroupRow, any>[] = [
  {
    id: 'rep_group_id',
    // Names are in the accessor, not just the slot, so the grid's global
    // filter finds a group by the rep or the login an admin remembers —
    // "Sports Inc" is not what anyone types. Sorting still leads with the id.
    accessorFn: (row) =>
      [row.rep_group_id, row.rep_names, row.portal_user_names]
        .filter(Boolean)
        .join(' '),
    header: 'Rep group',
  },
  { id: 'accounts', accessorFn: (row) => row.accounts, header: 'Accounts' },
  { id: 'revenue_ytd', accessorFn: (row) => row.revenue_ytd, header: 'Revenue YTD' },
  {
    id: 'yoy',
    accessorFn: (row) => yoy(row) ?? Number.NEGATIVE_INFINITY,
    header: 'YoY',
  },
  { id: 'bookings_ytd', accessorFn: (row) => row.bookings_ytd, header: 'Booked YTD' },
  {
    id: 'attainment',
    accessorFn: (row) => attainment(row) ?? -1,
    header: '% of goal',
  },
  {
    id: 'coverage',
    accessorFn: (row) => coveragePct(row) ?? -1,
    header: 'Contacted 30d',
  },
  { id: 'lapsed_accounts', accessorFn: (row) => row.lapsed_accounts, header: 'Lapsed' },
]

function onExport() {
  const csvColumns: CsvColumn<RepGroupRow>[] = [
    { key: 'rep_group_id', header: 'Rep Group' },
    { key: 'rep_count', header: 'ERP Reps' },
    { key: 'rep_names', header: 'Rep Names' },
    { key: 'portal_users', header: 'Portal Users' },
    { key: 'portal_user_names', header: 'Portal User Names' },
    { key: 'accounts', header: 'Accounts' },
    { key: 'buying_accounts', header: 'Accounts With Revenue YTD' },
    { key: 'lapsed_accounts', header: 'Lapsed Accounts' },
    { key: 'revenue_ytd', header: 'Revenue YTD' },
    { key: 'revenue_prior_ytd', header: 'Revenue Prior YTD' },
    {
      key: 'yoy_pct',
      header: 'Revenue YoY Percent',
      format: (row) => yoy(row)?.toFixed(1) ?? '',
    },
    { key: 'revenue_trailing_12m', header: 'Revenue Trailing 12m' },
    { key: 'bookings_ytd', header: 'Booked YTD' },
    { key: 'open_order_value', header: 'Open Order Value' },
    { key: 'backlog_amount', header: 'Backlog Amount' },
    { key: 'goal_total', header: 'Goal Total' },
    {
      key: 'attainment_pct',
      header: 'Percent Of Goal',
      format: (row) => attainment(row)?.toFixed(1) ?? '',
    },
    { key: 'contacted_30d', header: 'Accounts Contacted In 30 Days' },
    { key: 'contacted_90d', header: 'Accounts Contacted In 90 Days' },
    { key: 'last_invoice_date', header: 'Last Invoice Date' },
  ]
  exportCsv('rep-group-performance', visibleRows.value, csvColumns)
}
</script>

<template>
  <AppCard>
    <template #header>
      <div>
        <h2 class="u-label text-ink">Rep groups</h2>
        <p class="text-muted mt-1 text-[13px]">
          Whole-agency totals · year to date, pace marker at
          {{ Math.round(expectedPct) }}% of the year
        </p>
      </div>
      <AppButton variant="ghost" :disabled="!visibleRows.length" @click="onExport">
        Export CSV
      </AppButton>
    </template>

    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="rows.length === 0"
      empty-title="No rep groups"
      empty-body="Groups fill in once the ETL has landed sales reps with a vendor id."
      :rows="4"
      @retry="query.refetch()"
    >
      <DataGrid
        v-model:globalFilter="search"
        :columns="columns"
        :data="rows"
        :initial-sorting="[{ id: 'revenue_ytd', desc: true }]"
        searchable
        search-label="Search rep groups"
        search-placeholder="Search group, rep or user…"
        :get-row-id="rowId"
        min-width="56rem"
        @rows-change="visibleRows = $event"
      >
        <template #cell-rep_group_id="{ row }">
          <span class="text-ink font-semibold">{{ row.rep_group_id }}</span>
          <span class="text-muted block text-[13px]">{{ whoLabel(row) }}</span>
          <!-- Who signs in for this group. A group with revenue and nobody
               signed up is the row an admin needs to notice. -->
          <span
            v-if="row.portal_user_names"
            class="text-muted block truncate text-[13px]"
            :title="row.portal_user_names"
          >
            {{ row.portal_user_names }}
          </span>
        </template>

        <template #cell-accounts="{ row }">
          <span class="text-ink tabular-nums">{{ count(row.accounts) }}</span>
          <span class="text-muted block text-[13px] tabular-nums">
            {{ count(row.buying_accounts) }} buying
          </span>
        </template>

        <template #cell-revenue_ytd="{ row }">
          <span class="text-ink tabular-nums">{{ money(row.revenue_ytd) }}</span>
          <span class="text-muted block text-[13px] tabular-nums">
            {{ money(row.revenue_trailing_12m) }} trailing 12m
          </span>
        </template>

        <template #cell-yoy="{ row }">
          <span class="tabular-nums" :class="yoyTone(row)">{{ yoyLabel(row) }}</span>
          <span class="text-muted block text-[13px] tabular-nums">
            from {{ money(row.revenue_prior_ytd) }}
          </span>
        </template>

        <template #cell-bookings_ytd="{ row }">
          <span class="text-ink tabular-nums">{{ money(row.bookings_ytd) }}</span>
          <span class="text-muted block text-[13px] tabular-nums">
            {{ money(row.backlog_amount) }} backlog
          </span>
        </template>

        <template #cell-attainment="{ row }">
          <div v-if="attainment(row) != null" class="min-w-28">
            <span class="text-ink tabular-nums">
              {{ Math.round(attainment(row) ?? 0) }}%
            </span>
            <GoalProgressBar
              height="sm"
              class="mt-1"
              :attainment-pct="attainment(row) ?? 0"
              :expected-pct="expectedPct"
              :on-track="(attainment(row) ?? 0) >= expectedPct"
              :label="`${row.rep_group_id} goal attainment`"
            />
            <span class="text-muted block text-[13px] tabular-nums">
              of {{ money(row.goal_total) }}
            </span>
          </div>
          <span v-else class="text-muted">no goals set</span>
        </template>

        <template #cell-coverage="{ row }">
          <span class="text-ink tabular-nums">
            {{ coveragePct(row) == null ? '—' : `${Math.round(coveragePct(row) ?? 0)}%` }}
          </span>
          <span class="text-muted block text-[13px] tabular-nums">
            {{ count(row.contacted_30d) }} of {{ count(row.accounts) }}
          </span>
        </template>

        <template #cell-lapsed_accounts="{ row }">
          <AppBadge v-if="row.lapsed_accounts > 0" tone="late">
            {{ count(row.lapsed_accounts) }}
          </AppBadge>
          <span v-else class="text-muted tabular-nums">0</span>
        </template>

        <!-- Phone layout -->
        <template #card="{ row }">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0 flex-1">
              <p class="text-ink truncate font-semibold">{{ row.rep_group_id }}</p>
              <p class="text-muted mt-0.5 text-[15px]">{{ whoLabel(row) }}</p>
              <p class="text-muted mt-0.5 text-[15px] tabular-nums">
                {{ money(row.revenue_ytd) }} ·
                <span :class="yoyTone(row)">{{ yoyLabel(row) }}</span>
              </p>
              <template v-if="attainment(row) != null">
                <p class="text-muted mt-0.5 text-[15px] tabular-nums">
                  {{ Math.round(attainment(row) ?? 0) }}% of
                  {{ money(row.goal_total) }}
                </p>
                <GoalProgressBar
                  height="sm"
                  class="mt-1"
                  :attainment-pct="attainment(row) ?? 0"
                  :expected-pct="expectedPct"
                  :on-track="(attainment(row) ?? 0) >= expectedPct"
                  :label="`${row.rep_group_id} goal attainment`"
                />
              </template>
              <p v-if="row.last_invoice_date" class="text-muted mt-0.5 text-[13px]">
                Last invoice {{ shortDate(row.last_invoice_date) }}
              </p>
            </div>
            <AppBadge v-if="row.lapsed_accounts > 0" tone="late">
              {{ count(row.lapsed_accounts) }} lapsed
            </AppBadge>
          </div>
        </template>

        <template #empty>
          <p class="text-muted py-10 text-center text-[15px]">
            No rep groups match that search.
          </p>
        </template>
      </DataGrid>
    </AsyncState>
  </AppCard>
</template>
