<script setup lang="ts">
/**
 * PRD acceptance criterion #4: "for a chosen date range, every assigned account
 * with contacted-yes/no, and the untouched list exports/filters cleanly."
 *
 * Source is `public.account_coverage` via the existing `useCoverage()` — the
 * view is security_invoker, so an admin sees the whole field and nobody else
 * sees anything they shouldn't. No client-side owner filter (that would be
 * security theatre; RLS is the boundary).
 *
 * Window handling: the view ships `contacted_last_30d` and `contacted_last_90d`
 * as real columns. There is no 60-day column, so 60 is derived from
 * `last_contact_date` rather than invented.
 */
import { computed, ref } from 'vue'
import { differenceInCalendarDays, parseISO } from 'date-fns'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { useCoverage, type Coverage } from '@/composables/useAdmin'
import { daysAgo, shortDate } from '@/lib/format'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import type { ColumnDef } from '@tanstack/vue-table'

const COVERAGE_WINDOWS = [30, 60, 90] as const
type CoverageWindow = (typeof COVERAGE_WINDOWS)[number]

type CoverageRow = Coverage & {
  /** Contacted inside the selected window. */
  contacted: boolean
  /** Null when there is no logged contact at all. */
  days_since: number | null
}

const coverage = useCoverage()

const windowDays = ref<CoverageWindow>(30)
const repFilter = ref('')
const untouchedOnly = ref(false)
const search = ref('')

function daysSince(value: string | null): number | null {
  if (!value) return null
  const parsed = parseISO(value)
  if (Number.isNaN(parsed.getTime())) return null
  return differenceInCalendarDays(new Date(), parsed)
}

const allRows = computed<CoverageRow[]>(() =>
  (coverage.data.value ?? []).map((row) => {
    const days = daysSince(row.last_contact_date)
    const contacted =
      windowDays.value === 30
        ? row.contacted_last_30d === true
        : windowDays.value === 90
          ? row.contacted_last_90d === true
          : // 60 days: no such column on the view, so derive it from the date.
            days != null && days <= 60
    return { ...row, contacted, days_since: days }
  }),
)

const repNames = computed(() =>
  [
    ...new Set(allRows.value.map((r) => r.rep_name).filter((n): n is string => !!n)),
  ].sort((a, b) => a.localeCompare(b)),
)

/** Everything the page-level controls keep; the grid then applies its search. */
const filteredRows = computed(() =>
  allRows.value.filter((row) => {
    if (repFilter.value && row.rep_name !== repFilter.value) return false
    if (untouchedOnly.value && row.contacted) return false
    return true
  }),
)

const contactedCount = computed(
  () => filteredRows.value.filter((r) => r.contacted).length,
)
const coveragePct = computed(() =>
  filteredRows.value.length
    ? Math.round((contactedCount.value / filteredRows.value.length) * 100)
    : 0,
)

/**
 * What the grid is actually showing, after its own global filter and sort.
 * Export writes this, so the CSV always matches the screen.
 */
const visibleRows = ref<CoverageRow[]>([])

/** An account can appear once per rep who can see it, so key on both. */
function rowId(row: CoverageRow) {
  return `${row.customer_key}-${row.user_id}`
}

const columns: ColumnDef<CoverageRow, any>[] = [
  { id: 'customer_key', accessorKey: 'customer_key', header: 'Account' },
  { id: 'rep_name', accessorKey: 'rep_name', header: 'Rep' },
  {
    id: 'last_contact_date',
    accessorKey: 'last_contact_date',
    header: 'Last contact',
    // "Never" has to sort as the oldest thing there is — it is the whole point
    // of the untouched list, so it must not fall to the bottom.
    sortingFn: (a, b) => {
      const av = a.original.last_contact_date
      const bv = b.original.last_contact_date
      if (av === bv) return 0
      if (!av) return -1
      if (!bv) return 1
      return av < bv ? -1 : 1
    },
  },
  { id: 'contacted', accessorKey: 'contacted', header: 'Contacted' },
]

function onExport() {
  const csvColumns: CsvColumn<CoverageRow>[] = [
    { key: 'customer_key', header: 'Customer Key' },
    { key: 'rep_name', header: 'Rep' },
    { key: 'last_contact_date', header: 'Last Contact Date' },
    { key: 'days_since', header: 'Days Since Contact' },
    {
      key: 'contacted',
      header: `Contacted In ${windowDays.value} Days`,
      format: (row) => (row.contacted ? 'Yes' : 'No'),
    },
  ]
  exportCsv('coverage', visibleRows.value, csvColumns)
}

/** Selected/unselected for the segmented controls. */
function toggleClass(on: boolean) {
  return on
    ? 'btn bg-ink text-canvas border-ink border-[1.5px]'
    : 'btn border-line-2 text-ink hover:border-ink border-[1.5px]'
}
</script>

<template>
  <AppCard :padded="true">
    <template #header>
      <div>
        <h2 class="u-label text-ink">Coverage</h2>
        <p class="text-muted mt-1 text-[13px]">
          {{ contactedCount }} of {{ filteredRows.length }} contacted in
          {{ windowDays }} days · {{ coveragePct }}%
        </p>
      </div>
      <AppButton variant="ghost" :disabled="!visibleRows.length" @click="onExport">
        Export CSV
      </AppButton>
    </template>

    <div class="space-y-4">
      <fieldset>
        <legend class="u-label mb-2">Window</legend>
        <div class="flex flex-wrap gap-2">
          <button
            v-for="w in COVERAGE_WINDOWS"
            :key="w"
            type="button"
            :class="toggleClass(windowDays === w)"
            :aria-pressed="windowDays === w"
            @click="windowDays = w"
          >
            {{ w }} days
          </button>
        </div>
      </fieldset>

      <div class="flex flex-wrap items-end gap-2">
        <label class="min-w-0 flex-1 sm:max-w-64">
          <span class="u-label mb-2 block">Rep</span>
          <select v-model="repFilter" class="field">
            <option value="">All reps</option>
            <option v-for="name in repNames" :key="name" :value="name">
              {{ name }}
            </option>
          </select>
        </label>

        <button
          type="button"
          :class="toggleClass(untouchedOnly)"
          :aria-pressed="untouchedOnly"
          @click="untouchedOnly = !untouchedOnly"
        >
          Untouched only
        </button>
      </div>

      <AsyncState
        :loading="coverage.isPending.value"
        :error="coverage.error.value"
        :empty="allRows.length === 0"
        empty-title="No assigned accounts"
        empty-body="Coverage fills in once profiles carry a sales_rep_key and the ETL has run."
        @retry="coverage.refetch()"
      >
        <DataGrid
          v-model:globalFilter="search"
          :columns="columns"
          :data="filteredRows"
          :initial-sorting="[{ id: 'last_contact_date', desc: false }]"
          searchable
          search-label="Search accounts"
          search-placeholder="Search account or rep…"
          :get-row-id="rowId"
          min-width="38rem"
          @rows-change="visibleRows = $event"
        >
          <template #cell-customer_key="{ row }">
            <RouterLink
              v-if="row.customer_key"
              :to="{ name: 'account', params: { customerKey: row.customer_key } }"
              class="text-ink font-semibold underline underline-offset-2"
            >
              {{ row.customer_key }}
            </RouterLink>
            <span v-else class="text-muted">—</span>
          </template>

          <template #cell-rep_name="{ row }">
            <span class="text-ink-2">{{ row.rep_name ?? '—' }}</span>
          </template>

          <template #cell-last_contact_date="{ row }">
            <span class="text-ink block whitespace-nowrap">
              {{ shortDate(row.last_contact_date) }}
            </span>
            <span class="text-muted block text-[13px]">
              {{ daysAgo(row.last_contact_date) }}
            </span>
          </template>

          <template #cell-contacted="{ row }">
            <AppBadge :tone="row.contacted ? 'good' : 'late'">
              {{ row.contacted ? 'Yes' : 'No' }}
            </AppBadge>
          </template>

          <!-- Phone layout: the admin is a real user with a phone in a warehouse -->
          <template #card="{ row }">
            <RouterLink
              v-if="row.customer_key"
              :to="{ name: 'account', params: { customerKey: row.customer_key } }"
              class="tap-target flex items-center justify-between gap-3"
            >
              <span class="min-w-0">
                <span class="text-ink block truncate font-semibold">
                  {{ row.customer_key }}
                </span>
                <span class="text-muted block truncate text-[15px]">
                  {{ row.rep_name ?? 'Unassigned' }} ·
                  {{ daysAgo(row.last_contact_date) }}
                </span>
              </span>
              <AppBadge :tone="row.contacted ? 'good' : 'late'">
                {{ row.contacted ? 'Yes' : 'No' }}
              </AppBadge>
            </RouterLink>
          </template>

          <template #empty>
            <p class="text-muted py-10 text-center text-[15px]">
              {{
                untouchedOnly
                  ? `Every account here was contacted in the last ${windowDays} days.`
                  : 'No accounts match these filters.'
              }}
            </p>
          </template>
        </DataGrid>
      </AsyncState>
    </div>
  </AppCard>
</template>
