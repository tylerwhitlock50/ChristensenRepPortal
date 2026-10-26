<script setup lang="ts">
/**
 * The Agency page: a rep-group principal's agency, cut by rep.
 *
 * The Overview answers "how is my book doing" and reads it as one
 * territory. A principal also runs people, and nothing answered the
 * questions they ask about them: which rep is carrying the year, who is
 * behind on goal, who has stopped signing in, whose store just placed the
 * big order. Top to bottom: the agency's year in six numbers → every rep
 * (sales, goal, coverage, portal use) → month over month against last year
 * → the largest recent orders → channel mix, each one filterable to a rep.
 *
 * Two doors, one page:
 *   /agency            a principal; their book IS the agency, so every read
 *                      is unfiltered and RLS is the scope (useAgency.ts).
 *   /admin/agencies    an admin picks any agency (?vendor=) and sees exactly
 *                      what its principal would.
 */
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import type { ColumnDef } from '@tanstack/vue-table'
import { useSessionStore } from '@/stores/session'
import {
  activeWithin,
  agencyTotals,
  buildRepLines,
  monthlySeriesRows,
  rollUpAgencyChannels,
  useAgencyActivity,
  useAgencyLargeOrders,
  useAgencyRepPerformance,
  useAgencySalesByMonth,
  type AgencyRepLine,
} from '@/composables/useAgency'
import {
  attainmentPct,
  shareOf,
  useRepGroupPerformance,
  yearElapsedPct,
  yoyPct,
} from '@/composables/useAdminReports'
import { buildCalendarYearSeries, deltaLabel } from '@/composables/useAccountMetrics'
import DataGrid from '@/components/DataGrid.vue'
import FreshnessStamp from '@/components/FreshnessStamp.vue'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import RevenueYearChart from '@/components/RevenueYearChart.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import { count, daysAgo, money, share, shortDate } from '@/lib/format'

const session = useSessionStore()
const route = useRoute()
const router = useRouter()

/* ---- whose agency --------------------------------------------------------
   Decided once per mount: the two routes are different records, so moving
   between them remounts this page. */
const adminView = route.name === 'admin-agencies'

const vendor = computed(() => {
  if (!adminView) return ''
  const q = route.query.vendor
  return typeof q === 'string' ? q.trim() : ''
})
/** A principal always has theirs; an admin has nothing until they pick. */
const ready = computed(() => (adminView ? vendor.value !== '' : true))
const agencyName = computed(() =>
  adminView ? vendor.value : (session.repGroupVendorId ?? ''),
)

/* The admin's picker: the Reports tab's rep-group rollup, which already
   names every agency with its reps. Never read for a principal. */
const groups = adminView ? useRepGroupPerformance() : null
const groupOptions = computed(() =>
  (groups?.data.value ?? [])
    .filter((g) => g.rep_group_id !== '(No rep group)')
    .sort((a, b) => b.revenue_ytd - a.revenue_ytd || a.rep_group_id.localeCompare(b.rep_group_id)),
)

function pickAgency(next: string) {
  void router.replace({ query: next ? { vendor: next } : {} })
}

/* ---- the reads ----------------------------------------------------------- */
const perf = useAgencyRepPerformance(vendor, ready)
const activity = useAgencyActivity(vendor, ready)
const months = useAgencySalesByMonth(vendor, ready)

const perfRows = computed(() => perf.data.value ?? [])
const totals = computed(() => agencyTotals(perfRows.value))
const lines = computed(() => buildRepLines(perfRows.value, activity.data.value ?? []))

const loaded = computed(() => perf.data.value !== undefined)
const dash = '—'

/* ---- headline ------------------------------------------------------------ */
const expectedPct = computed(() => yearElapsedPct())

function signedPct(pct: number | null): string {
  if (pct == null) return ''
  return `${pct >= 0 ? '+' : '−'}${Math.abs(pct).toFixed(1)}%`
}

const revenueSub = computed(() => {
  const t = totals.value
  const pct = yoyPct(t.revenue_ytd, t.revenue_prior_ytd)
  return pct == null
    ? 'no sales this time last year'
    : `${signedPct(pct)} vs last year (${money(t.revenue_prior_ytd)})`
})

const goalPct = computed(() => attainmentPct(totals.value.revenue_ytd, totals.value.goal_total))

const bookedSub = computed(() => {
  const t = totals.value
  const pct = yoyPct(t.bookings_ytd, t.bookings_prior_ytd)
  return pct == null ? 'orders written' : `${signedPct(pct)} vs last year`
})

/** Reps (not principals) with a portal login, and how many used it this week. */
const portalReps = computed(() => lines.value.filter((l) => l.portal && !l.is_principal))
const activeThisWeek = computed(
  () => portalReps.value.filter((l) => activeWithin(l.portal, 7)).length,
)
const withoutLogin = computed(
  () => lines.value.filter((l) => l.sales_rep_key && !l.portal).length,
)

/* ---- reps table ---------------------------------------------------------- */
const search = ref('')
const visibleLines = ref<AgencyRepLine[]>([])

function yoy(row: AgencyRepLine) {
  return yoyPct(row.revenue_ytd, row.revenue_prior_ytd)
}

function yoyLabel(row: AgencyRepLine): string {
  const pct = yoy(row)
  if (pct == null) return row.revenue_ytd > 0 ? 'new' : '—'
  return signedPct(pct)
}

function yoyTone(pct: number | null): string {
  if (pct == null) return 'text-muted'
  if (pct <= -10) return 'text-danger'
  if (pct >= 10) return 'text-brand'
  return 'text-ink-2'
}

function attainment(row: AgencyRepLine) {
  return attainmentPct(row.revenue_ytd, row.goal_total)
}

function coveragePct(row: AgencyRepLine): number | null {
  if (row.accounts <= 0) return null
  return (row.contacted_30d / row.accounts) * 100
}

/** What the "Last active" column says about a rep's login. */
function portalLabel(row: AgencyRepLine): string {
  if (!row.portal) return row.sales_rep_key ? 'No portal login' : '—'
  if (!row.portal.active) return 'Login deactivated'
  if (!row.portal.last_login_at) return 'Never signed in'
  return daysAgo(row.portal.last_login_at)
}

/** The same, as a sentence for the phone card. */
function portalSentence(row: AgencyRepLine): string {
  const label = portalLabel(row)
  return row.portal?.active && row.portal.last_login_at ? `Last active ${label}` : label
}

/** A login with no accounts of its own (the principal, a rep not yet
 *  assigned any): its sales columns would be a row of $0. */
function noBook(row: AgencyRepLine): boolean {
  return row.accounts === 0 && row.revenue_prior_ytd === 0 && row.revenue_ytd === 0
}

const columns: ColumnDef<AgencyRepLine, any>[] = [
  {
    id: 'name',
    accessorFn: (row) => [row.name, row.sales_rep_key, row.portal?.full_name].filter(Boolean).join(' '),
    header: 'Rep',
  },
  { id: 'revenue_ytd', accessorFn: (row) => row.revenue_ytd, header: 'Revenue YTD' },
  { id: 'yoy', accessorFn: (row) => yoy(row) ?? Number.NEGATIVE_INFINITY, header: 'YoY' },
  { id: 'attainment', accessorFn: (row) => attainment(row) ?? -1, header: '% of goal' },
  { id: 'bookings_ytd', accessorFn: (row) => row.bookings_ytd, header: 'Booked YTD' },
  { id: 'accounts', accessorFn: (row) => row.accounts, header: 'Accounts' },
  { id: 'coverage', accessorFn: (row) => coveragePct(row) ?? -1, header: 'Contacted 30d' },
  {
    id: 'last_login_at',
    // Never-signed-in sorts first ascending: the row worth chasing.
    accessorFn: (row) => row.portal?.last_login_at ?? '',
    header: 'Last active',
  },
  { id: 'actions_30d', accessorFn: (row) => row.portal?.actions_30d ?? -1, header: 'Logged 30d' },
]

function onExport() {
  const csvColumns: CsvColumn<AgencyRepLine>[] = [
    { key: 'name', header: 'Rep' },
    { key: 'sales_rep_key', header: 'Rep Code' },
    { key: 'is_principal', header: 'Principal', format: (r) => (r.is_principal ? 'Yes' : '') },
    { key: 'accounts', header: 'Accounts' },
    { key: 'buying_accounts', header: 'Accounts With Revenue YTD' },
    { key: 'lapsed_accounts', header: 'Lapsed Accounts' },
    { key: 'new_accounts', header: 'New Accounts This Year' },
    { key: 'revenue_ytd', header: 'Revenue YTD' },
    { key: 'revenue_prior_ytd', header: 'Revenue Prior YTD' },
    { key: 'yoy_pct', header: 'Revenue YoY Percent', format: (r) => yoy(r)?.toFixed(1) ?? '' },
    { key: 'revenue_trailing_12m', header: 'Revenue Trailing 12m' },
    { key: 'bookings_ytd', header: 'Booked YTD' },
    { key: 'open_order_value', header: 'Open Order Value' },
    { key: 'backlog_amount', header: 'Past Promise Amount' },
    { key: 'goal_total', header: 'Goal Total' },
    {
      key: 'attainment_pct',
      header: 'Percent Of Goal',
      format: (r) => attainment(r)?.toFixed(1) ?? '',
    },
    { key: 'contacted_30d', header: 'Accounts Contacted In 30 Days' },
    { key: 'last_login', header: 'Last Active', format: (r) => r.portal?.last_login_at },
    { key: 'logins_30d', header: 'App Opens 30 Days', format: (r) => r.portal?.logins_30d },
    { key: 'active_days_30d', header: 'Active Days 30 Days', format: (r) => r.portal?.active_days_30d },
    { key: 'actions_30d', header: 'Actions Logged 30 Days', format: (r) => r.portal?.actions_30d },
    { key: 'visits_30d', header: 'Visits Logged 30 Days', format: (r) => r.portal?.visits_30d },
  ]
  exportCsv(`agency-reps-${agencyName.value || 'agency'}`, visibleLines.value, csvColumns)
}

/* ---- one rep or the whole agency, for the chart and the channel mix ------ */
/** '' = the whole agency; otherwise a line id from buildRepLines(). */
const chartRep = ref('')
const channelRep = ref('')

/** Reps with a book to draw — the logins with no accounts have nothing here. */
const repChoices = computed(() =>
  lines.value.filter((l) => l.id.startsWith('rep:')).map((l) => ({ id: l.id, name: l.name })),
)

/** A pick that names nobody on this agency (the agency changed) resets. */
watch(repChoices, (choices) => {
  const ids = new Set(choices.map((c) => c.id))
  if (chartRep.value && !ids.has(chartRep.value)) chartRep.value = ''
  if (channelRep.value && !ids.has(channelRep.value)) channelRep.value = ''
})

/** Line id → the rep key the rows carry (undefined = everyone). */
function repKeyOf(id: string): string | null | undefined {
  if (!id) return undefined
  const line = lines.value.find((l) => l.id === id)
  return line ? line.sales_rep_key : undefined
}

function repName(id: string): string {
  return lines.value.find((l) => l.id === id)?.name ?? ''
}

const series = computed(() =>
  buildCalendarYearSeries(monthlySeriesRows(months.data.value ?? [], repKeyOf(chartRep.value))),
)
const chartSubject = computed(() =>
  chartRep.value
    ? `Monthly invoiced revenue for ${repName(chartRep.value)}`
    : 'Monthly invoiced revenue for the agency',
)

const channels = computed(() => rollUpAgencyChannels(perfRows.value, repKeyOf(channelRep.value)))
const channelTotal = computed(() => agencyTotals(channels.value).revenue_ytd)

/* ---- large orders -------------------------------------------------------- */
const WINDOWS = [7, 30, 90] as const
const orderDays = ref<number>(30)
const largeOrders = useAgencyLargeOrders(vendor, orderDays, ready)

/* ---- empty states -------------------------------------------------------- */
const emptyBody = computed(() =>
  adminView
    ? `No active accounts are assigned to a rep billing through ${vendor.value}.`
    : `Your agency's accounts come from the ERP reps who bill through ${agencyName.value}. ` +
      'If that seems wrong, ask your admin to check the rep group vendor on your profile.',
)
</script>

<template>
  <div class="space-y-5">
    <header class="space-y-3">
      <div>
        <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
          {{ adminView ? 'Agencies' : 'Your agency' }}
        </p>
        <h1 class="u-display text-ink mt-1 text-3xl sm:text-4xl">
          {{ agencyName || 'Pick an agency' }}
        </h1>
        <p class="text-muted mt-2 text-[15px]">
          How each rep is tracking, who is using the portal, and the big
          orders. Active external accounts, year to date.
        </p>
        <FreshnessStamp class="mt-1" />
      </div>

      <!-- An admin sees any agency the way its principal does. -->
      <div v-if="adminView" class="max-w-md">
        <label for="agency-pick" class="u-label mb-1.5 block">Agency</label>
        <select
          id="agency-pick"
          class="field"
          :value="vendor"
          :disabled="groups?.isPending.value"
          @change="pickAgency(($event.target as HTMLSelectElement).value)"
        >
          <option value="">
            {{ groups?.isPending.value ? 'Loading agencies…' : 'Choose an agency…' }}
          </option>
          <!-- A deep link to a vendor not in the list still shows as picked. -->
          <option
            v-if="vendor && !groupOptions.some((g) => g.rep_group_id === vendor)"
            :value="vendor"
          >
            {{ vendor }}
          </option>
          <option v-for="g in groupOptions" :key="g.rep_group_id" :value="g.rep_group_id">
            {{ g.rep_group_id }} — {{ money(g.revenue_ytd) }} YTD
          </option>
        </select>
      </div>
    </header>

    <p v-if="!ready" class="text-muted text-[15px]">
      Pick an agency to see its reps, its year and its big orders, exactly as
      its principal sees them.
    </p>

    <AsyncState
      v-else
      :loading="perf.isPending.value"
      :error="perf.error.value"
      :has-data="loaded"
      :updated-at="perf.dataUpdatedAt.value"
      :empty="loaded && perfRows.length === 0 && lines.length === 0"
      empty-title="Nothing in this agency yet"
      :empty-body="emptyBody"
      :rows="4"
      @retry="perf.refetch()"
    >
      <!-- 1 · The year in six numbers -->
      <section aria-label="Agency year to date">
        <div class="border-line bg-line grid grid-cols-2 gap-px border md:grid-cols-3 xl:grid-cols-6">
          <StatTile label="Revenue YTD" :value="money(totals.revenue_ytd)" :sub="revenueSub" />
          <StatTile
            label="Goal"
            :value="goalPct == null ? dash : `${Math.round(goalPct)}%`"
            :sub="
              goalPct == null
                ? 'no goals set'
                : `of ${money(totals.goal_total)} · year ${Math.round(expectedPct)}% gone`
            "
          />
          <StatTile label="Booked YTD" :value="money(totals.bookings_ytd)" :sub="bookedSub" />
          <StatTile
            label="Open orders"
            :value="money(totals.open_order_value)"
            :sub="`${money(totals.backlog_amount)} past promise`"
            :tone="totals.backlog_amount > 0 ? 'alert' : 'default'"
          />
          <StatTile
            label="Buying accounts"
            :value="count(totals.buying_accounts)"
            :sub="`of ${count(totals.accounts)} · ${count(totals.lapsed_accounts)} lapsed · ${count(totals.new_accounts)} new`"
          />
          <StatTile
            label="Reps on the portal"
            :value="activity.data.value ? `${activeThisWeek} of ${portalReps.length}` : dash"
            :sub="
              activity.data.value
                ? `signed in this week${withoutLogin ? ` · ${withoutLogin} without a login` : ''}`
                : undefined
            "
          />
        </div>
      </section>

      <!-- 2 · Every rep -->
      <AppCard class="mt-5">
        <template #header>
          <div>
            <h2 class="u-label text-ink">{{ adminView ? 'Reps' : 'Your reps' }}</h2>
            <p class="text-muted mt-1 text-[13px]">
              Year to date · pace marker at {{ Math.round(expectedPct) }}% of the year ·
              portal use over 30 days
            </p>
          </div>
          <AppButton variant="ghost" :disabled="!visibleLines.length" @click="onExport">
            Export CSV
          </AppButton>
        </template>

        <p v-if="activity.error.value" role="alert" class="text-danger mb-3 text-sm">
          Portal activity didn't load — sales figures below are still current.
          <button type="button" class="underline" @click="activity.refetch()">Retry</button>
        </p>

        <DataGrid
          v-model:globalFilter="search"
          :columns="columns"
          :data="lines"
          :initial-sorting="[{ id: 'revenue_ytd', desc: true }]"
          searchable
          search-label="Search reps"
          search-placeholder="Search reps…"
          :get-row-id="(row: AgencyRepLine) => row.id"
          min-width="62rem"
          @rows-change="visibleLines = $event"
        >
          <template #cell-name="{ row }">
            <span class="text-ink font-semibold">{{ row.name }}</span>
            <AppBadge v-if="row.is_principal" class="ml-1.5" tone="neutral">Principal</AppBadge>
            <span v-if="row.sales_rep_key" class="text-muted block text-[13px]">
              {{ row.sales_rep_key }}
            </span>
          </template>

          <template #cell-revenue_ytd="{ row }">
            <span v-if="noBook(row)" class="text-muted whitespace-nowrap">No accounts</span>
            <template v-else>
              <span class="text-ink tabular-nums">{{ money(row.revenue_ytd) }}</span>
              <span class="text-muted block text-[13px] tabular-nums">
                {{ money(row.revenue_trailing_12m) }} trailing 12m
              </span>
            </template>
          </template>

          <template #cell-yoy="{ row }">
            <span v-if="noBook(row)" class="text-muted">—</span>
            <template v-else>
              <span class="tabular-nums" :class="yoyTone(yoy(row))">{{ yoyLabel(row) }}</span>
              <span class="text-muted block text-[13px] tabular-nums">
                from {{ money(row.revenue_prior_ytd) }}
              </span>
            </template>
          </template>

          <template #cell-attainment="{ row }">
            <div v-if="attainment(row) != null" class="min-w-28">
              <span class="text-ink tabular-nums">{{ Math.round(attainment(row) ?? 0) }}%</span>
              <GoalProgressBar
                height="sm"
                class="mt-1"
                :attainment-pct="attainment(row) ?? 0"
                :expected-pct="expectedPct"
                :on-track="(attainment(row) ?? 0) >= expectedPct"
                :label="`${row.name} goal attainment`"
              />
              <span class="text-muted block text-[13px] tabular-nums">
                of {{ money(row.goal_total) }}
              </span>
            </div>
            <span v-else class="text-muted">{{ row.accounts ? 'no goals set' : '—' }}</span>
          </template>

          <template #cell-bookings_ytd="{ row }">
            <span v-if="noBook(row)" class="text-muted">—</span>
            <template v-else>
              <span class="text-ink tabular-nums">{{ money(row.bookings_ytd) }}</span>
              <span class="text-muted block text-[13px] tabular-nums">
                {{ money(row.backlog_amount) }} past promise
              </span>
            </template>
          </template>

          <template #cell-accounts="{ row }">
            <span v-if="noBook(row)" class="text-muted">—</span>
            <template v-else>
              <span class="text-ink tabular-nums">{{ count(row.accounts) }}</span>
              <span class="text-muted block text-[13px] tabular-nums">
                {{ count(row.buying_accounts) }} buying<template v-if="row.lapsed_accounts">
                  · <span class="text-accent">{{ count(row.lapsed_accounts) }} lapsed</span></template>
              </span>
            </template>
          </template>

          <template #cell-coverage="{ row }">
            <span class="text-ink tabular-nums">
              {{ coveragePct(row) == null ? '—' : `${Math.round(coveragePct(row) ?? 0)}%` }}
            </span>
            <span v-if="row.accounts" class="text-muted block text-[13px] tabular-nums">
              {{ count(row.contacted_30d) }} of {{ count(row.accounts) }}
            </span>
          </template>

          <template #cell-last_login_at="{ row }">
            <span
              class="block whitespace-nowrap"
              :class="row.portal?.last_login_at ? 'text-ink' : 'text-muted'"
            >
              {{ portalLabel(row) }}
            </span>
            <span v-if="row.portal?.last_login_at" class="text-muted block text-[13px]">
              {{ count(row.portal.active_days_30d) }}
              {{ row.portal.active_days_30d === 1 ? 'day' : 'days' }} in 30
            </span>
          </template>

          <template #cell-actions_30d="{ row }">
            <template v-if="row.portal">
              <span class="text-ink tabular-nums">{{ count(row.portal.actions_30d) }}</span>
              <span class="text-muted block text-[13px] tabular-nums">
                {{ count(row.portal.visits_30d) }}
                {{ row.portal.visits_30d === 1 ? 'visit' : 'visits' }}
              </span>
            </template>
            <span v-else class="text-muted">—</span>
          </template>

          <!-- Phone layout -->
          <template #card="{ row }">
            <div class="min-w-0">
              <div class="flex items-start justify-between gap-3">
                <p class="text-ink min-w-0 truncate font-semibold">
                  {{ row.name }}
                  <AppBadge v-if="row.is_principal" class="ml-1" tone="neutral">
                    Principal
                  </AppBadge>
                </p>
                <span v-if="!noBook(row)" class="text-ink shrink-0 font-semibold tabular-nums">
                  {{ money(row.revenue_ytd) }}
                </span>
              </div>
              <p v-if="noBook(row)" class="text-muted mt-0.5 text-[15px]">
                No accounts of their own
              </p>
              <p v-else class="text-muted mt-0.5 text-[15px] tabular-nums">
                <span :class="yoyTone(yoy(row))">{{ yoyLabel(row) }}</span>
                vs last year · {{ count(row.accounts) }} accounts
                <template v-if="row.lapsed_accounts">
                  · <span class="text-accent">{{ count(row.lapsed_accounts) }} lapsed</span>
                </template>
              </p>
              <template v-if="attainment(row) != null">
                <p class="text-muted mt-0.5 text-[15px] tabular-nums">
                  {{ Math.round(attainment(row) ?? 0) }}% of {{ money(row.goal_total) }}
                </p>
                <GoalProgressBar
                  height="sm"
                  class="mt-1"
                  :attainment-pct="attainment(row) ?? 0"
                  :expected-pct="expectedPct"
                  :on-track="(attainment(row) ?? 0) >= expectedPct"
                  :label="`${row.name} goal attainment`"
                />
              </template>
              <p class="text-muted mt-1 text-[13px]">
                {{ portalSentence(row) }}
                <template v-if="row.portal">
                  · {{ count(row.portal.actions_30d) }} logged in 30 days
                </template>
              </p>
            </div>
          </template>

          <template #empty>
            <p class="text-muted py-10 text-center text-[15px]">No reps match that search.</p>
          </template>
        </DataGrid>
      </AppCard>

      <div class="mt-5 grid gap-5 lg:grid-cols-2 lg:items-start">
        <!-- 3 · Month over month, against last year -->
        <AppCard>
          <template #header>
            <div>
              <h2 class="u-label text-ink">Revenue by month</h2>
              <p class="text-muted mt-1 text-[13px]">
                {{
                  series.deltaPct == null
                    ? 'This year next to last'
                    : `${deltaLabel(series.deltaPct)} vs last year, complete months`
                }}
              </p>
            </div>
            <div>
              <label class="sr-only" for="chart-rep">Show one rep</label>
              <select id="chart-rep" v-model="chartRep" class="field max-w-48">
                <option value="">All reps</option>
                <option v-for="r in repChoices" :key="r.id" :value="r.id">{{ r.name }}</option>
              </select>
            </div>
          </template>
          <AsyncState
            :loading="months.isPending.value"
            :error="months.error.value"
            :has-data="months.data.value !== undefined"
            :updated-at="months.dataUpdatedAt.value"
            :empty="!months.isPending.value && !series.hasData"
            empty-title="No invoiced revenue"
            :empty-body="
              chartRep
                ? 'Nothing invoiced to this rep\'s accounts this year or last.'
                : 'Nothing invoiced to the agency this year or last.'
            "
            :rows="2"
            @retry="months.refetch()"
          >
            <RevenueYearChart :series="series" :subject="chartSubject" />
          </AsyncState>
        </AppCard>

        <!-- 4 · The big orders, and whose they are -->
        <AppCard :padded="false">
          <template #header>
            <div>
              <h2 class="u-label text-ink">Largest orders</h2>
              <p class="text-muted mt-1 text-[13px]">
                Biggest placed in the last {{ orderDays }} days, cancelled left out
              </p>
            </div>
            <div class="border-line flex border" role="group" aria-label="Order window">
              <button
                v-for="d in WINDOWS"
                :key="d"
                type="button"
                class="tap-target font-label min-w-11 px-3 text-[13px] font-semibold tracking-[0.12em] uppercase"
                :class="orderDays === d ? 'bg-ink text-canvas' : 'text-muted'"
                :aria-pressed="orderDays === d"
                @click="orderDays = d"
              >
                {{ d }}d
              </button>
            </div>
          </template>
          <div :class="largeOrders.data.value?.length ? '' : 'p-4'">
            <AsyncState
              :loading="largeOrders.isPending.value"
              :error="largeOrders.error.value"
              :has-data="largeOrders.data.value !== undefined"
              :updated-at="largeOrders.dataUpdatedAt.value"
              :empty="(largeOrders.data.value?.length ?? 0) === 0"
              empty-title="No orders in this window"
              empty-body="Nothing was ordered across the agency in that many days. Try a longer window."
              :rows="3"
              @retry="largeOrders.refetch()"
            >
              <ul class="divide-line divide-y">
                <li v-for="o in largeOrders.data.value" :key="`${o.customer_key}:${o.order_id}`">
                  <RouterLink
                    :to="{ name: 'account', params: { customerKey: o.customer_key } }"
                    class="hover:bg-canvas flex items-center justify-between gap-3 px-4 py-3"
                  >
                    <span class="min-w-0">
                      <span class="text-ink block truncate text-[15px] font-semibold">
                        {{ o.customer_name || o.customer_key }}
                      </span>
                      <span class="text-muted block text-xs">
                        {{ o.sales_rep_name || 'No rep assigned' }} ·
                        {{ shortDate(o.order_date) }} · #{{ o.order_id }}
                      </span>
                    </span>
                    <span class="flex shrink-0 flex-col items-end gap-1">
                      <span class="text-ink text-[15px] font-bold tabular-nums">
                        {{ money(o.amount) }}
                      </span>
                      <AppBadge v-if="o.has_open_lines" tone="neutral">Open lines</AppBadge>
                    </span>
                  </RouterLink>
                </li>
              </ul>
            </AsyncState>
          </div>
        </AppCard>
      </div>

      <!-- 5 · Channel mix, whole agency or one rep -->
      <AppCard class="mt-5" :padded="false">
        <template #header>
          <div>
            <h2 class="u-label text-ink">Channels</h2>
            <p class="text-muted mt-1 text-[13px]">
              Where {{ channelRep ? repName(channelRep) + '\'s' : 'the agency\'s' }} year
              is coming from
            </p>
          </div>
          <div>
            <label class="sr-only" for="channel-rep">Show one rep</label>
            <select id="channel-rep" v-model="channelRep" class="field max-w-48">
              <option value="">All reps</option>
              <option v-for="r in repChoices" :key="r.id" :value="r.id">{{ r.name }}</option>
            </select>
          </div>
        </template>
        <p v-if="channels.length === 0" class="text-muted p-4 text-[15px]">
          No active accounts for this rep.
        </p>
        <ul v-else class="divide-line divide-y">
          <li v-for="c in channels" :key="c.channel" class="px-4 py-3">
            <div class="flex items-baseline justify-between gap-3">
              <span class="min-w-0">
                <span class="text-ink block truncate text-[15px] font-semibold">{{ c.channel }}</span>
                <span class="text-muted block text-xs">
                  {{ count(c.buying_accounts) }} of {{ count(c.accounts) }} accounts buying
                  <template v-if="c.lapsed_accounts">· {{ count(c.lapsed_accounts) }} lapsed</template>
                </span>
              </span>
              <span class="shrink-0 text-right">
                <span class="text-ink block text-[15px] font-semibold tabular-nums">
                  {{ money(c.revenue_ytd) }}
                </span>
                <span
                  class="block text-xs tabular-nums"
                  :class="yoyTone(yoyPct(c.revenue_ytd, c.revenue_prior_ytd))"
                >
                  {{
                    yoyPct(c.revenue_ytd, c.revenue_prior_ytd) == null
                      ? c.revenue_ytd > 0
                        ? 'new'
                        : '—'
                      : signedPct(yoyPct(c.revenue_ytd, c.revenue_prior_ytd))
                  }}
                  · {{ share(shareOf(c.revenue_ytd, channelTotal)) }}
                </span>
              </span>
            </div>
            <!-- Share of the year, as a bar: structure, not decoration. -->
            <div class="border-line bg-canvas mt-2 h-1.5 border" aria-hidden="true">
              <div
                class="bg-ink h-full"
                :style="{ width: `${Math.max(0, Math.min(100, (shareOf(c.revenue_ytd, channelTotal) ?? 0) * 100))}%` }"
              />
            </div>
          </li>
        </ul>
      </AppCard>
    </AsyncState>
  </div>
</template>
