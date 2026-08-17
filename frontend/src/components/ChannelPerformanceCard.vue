<script setup lang="ts">
/**
 * How each channel is doing — the governed reporting hierarchy on
 * erp.dim_customer (Big Box, Distribution, Buy Group, Dealer, Direct to
 * Consumer, Special Programs, …), summed over active external accounts.
 *
 * One query, two grains. `public.v_channel_performance` returns sub-channel
 * rows; the Channel view sums them here. That is safe because the view emits
 * raw sums and nothing derived — every ratio on this screen (YoY, share,
 * attainment) is computed from those sums, never averaged from row-level
 * percentages.
 *
 * The chart draws exactly the rows the table lists, in the table's order, so
 * a manager reading top-to-bottom sees the same story twice rather than two.
 */
import { computed, ref } from 'vue'
import DataGrid from '@/components/DataGrid.vue'
import ChannelMixChart from '@/components/ChannelMixChart.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import {
  attainmentPct,
  rollUpChannels,
  shareOf,
  totalChannels,
  useChannelPerformance,
  yoyPct,
  type ChannelRow,
} from '@/composables/useAdminReports'
import { count, money, share, shortDate } from '@/lib/format'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import type { ColumnDef } from '@tanstack/vue-table'

const GRAINS = [
  { key: 'channel', label: 'Channel' },
  { key: 'sub_channel', label: 'Sub-channel' },
] as const
type Grain = (typeof GRAINS)[number]['key']

const query = useChannelPerformance()

const grain = ref<Grain>('channel')
const search = ref('')
const visibleRows = ref<ChannelRow[]>([])

const subChannelRows = computed(() => query.data.value ?? [])

const rows = computed(() =>
  grain.value === 'channel'
    ? rollUpChannels(subChannelRows.value)
    : subChannelRows.value,
)

/**
 * The denominator for every share. Always the whole book, never the filtered
 * subset — "18% of revenue" has to mean 18% of the company, not 18% of
 * whatever the search box left on screen.
 */
const bookTotal = computed(() => totalChannels(subChannelRows.value))

/** Channel-grain, biggest first — what the chart draws. */
const chartRows = computed(() =>
  [...rollUpChannels(subChannelRows.value)]
    .sort((a, b) => b.revenue_ytd - a.revenue_ytd)
    .filter((r) => r.revenue_ytd > 0 || r.revenue_prior_ytd > 0),
)

function label(row: ChannelRow): string {
  return grain.value === 'channel' ? row.channel : (row.sub_channel ?? row.channel)
}

function rowId(row: ChannelRow) {
  return `${row.channel}::${row.sub_channel ?? ''}`
}

function yoy(row: ChannelRow) {
  return yoyPct(row.revenue_ytd, row.revenue_prior_ytd)
}

/** "+12.4%" / "−8.0%" / "new" when there is no prior-year base. */
function yoyLabel(row: ChannelRow): string {
  const pct = yoy(row)
  if (pct == null) return row.revenue_ytd > 0 ? 'new' : '—'
  return `${pct >= 0 ? '+' : '−'}${Math.abs(pct).toFixed(1)}%`
}

function yoyTone(row: ChannelRow): string {
  const pct = yoy(row)
  if (pct == null) return 'text-muted'
  if (pct <= -10) return 'text-danger'
  if (pct >= 10) return 'text-brand'
  return 'text-ink-2'
}

function attainment(row: ChannelRow) {
  return attainmentPct(row.revenue_ytd, row.goal_total)
}

const columns = computed<ColumnDef<ChannelRow, any>[]>(() => [
  {
    id: 'label',
    // At sub-channel grain the parent name is in the accessor as well as the
    // slot, so searching "Dealer" turns up its sub-channels instead of
    // nothing. Sorting still leads with the sub-channel, which is the label.
    accessorFn: (row: ChannelRow) =>
      grain.value === 'channel' ? row.channel : `${label(row)} ${row.channel}`,
    header: grain.value === 'channel' ? 'Channel' : 'Sub-channel',
  },
  { id: 'accounts', accessorFn: (row: ChannelRow) => row.accounts, header: 'Accounts' },
  {
    id: 'revenue_ytd',
    accessorFn: (row: ChannelRow) => row.revenue_ytd,
    header: 'Revenue YTD',
  },
  {
    id: 'yoy',
    accessorFn: (row: ChannelRow) => yoy(row) ?? Number.NEGATIVE_INFINITY,
    header: 'YoY',
  },
  {
    id: 'bookings_ytd',
    accessorFn: (row: ChannelRow) => row.bookings_ytd,
    header: 'Booked YTD',
  },
  {
    id: 'backlog_amount',
    accessorFn: (row: ChannelRow) => row.backlog_amount,
    header: 'Backlog',
  },
  {
    id: 'attainment',
    accessorFn: (row: ChannelRow) => attainment(row) ?? -1,
    header: '% of goal',
  },
  {
    id: 'lapsed_accounts',
    accessorFn: (row: ChannelRow) => row.lapsed_accounts,
    header: 'Lapsed',
  },
])

function onExport() {
  const csvColumns: CsvColumn<ChannelRow>[] = [
    { key: 'channel', header: 'Channel' },
    ...(grain.value === 'sub_channel'
      ? [{ key: 'sub_channel', header: 'Sub-channel' } as CsvColumn<ChannelRow>]
      : []),
    { key: 'accounts', header: 'Accounts' },
    { key: 'buying_accounts', header: 'Accounts With Revenue YTD' },
    { key: 'lapsed_accounts', header: 'Lapsed Accounts' },
    { key: 'new_accounts', header: 'Accounts Opened This Year' },
    { key: 'revenue_ytd', header: 'Revenue YTD' },
    { key: 'revenue_prior_ytd', header: 'Revenue Prior YTD' },
    {
      key: 'yoy_pct',
      header: 'Revenue YoY Percent',
      format: (row) => yoy(row)?.toFixed(1) ?? '',
    },
    {
      key: 'share_of_revenue',
      header: 'Share Of Company Revenue YTD',
      format: (row) => {
        const s = shareOf(row.revenue_ytd, bookTotal.value.revenue_ytd)
        return s == null ? '' : (s * 100).toFixed(1)
      },
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
    { key: 'last_invoice_date', header: 'Last Invoice Date' },
  ]
  exportCsv(`channel-performance-${grain.value}`, visibleRows.value, csvColumns)
}

/** Same segmented-control styling as CoverageGrid. */
function toggleClass(on: boolean) {
  return on
    ? 'btn bg-ink text-canvas border-ink border-[1.5px]'
    : 'btn border-line-2 text-ink hover:border-ink border-[1.5px]'
}
</script>

<template>
  <AppCard>
    <template #header>
      <div>
        <h2 class="u-label text-ink">Channels</h2>
        <p class="text-muted mt-1 text-[13px]">
          Active external accounts by reporting group · year to date
        </p>
      </div>
      <AppButton variant="ghost" :disabled="!visibleRows.length" @click="onExport">
        Export CSV
      </AppButton>
    </template>

    <div class="space-y-4">
      <fieldset>
        <legend class="u-label mb-2">Grain</legend>
        <div class="flex flex-wrap gap-2">
          <button
            v-for="g in GRAINS"
            :key="g.key"
            type="button"
            :class="toggleClass(grain === g.key)"
            :aria-pressed="grain === g.key"
            @click="grain = g.key"
          >
            {{ g.label }}
          </button>
        </div>
      </fieldset>

      <AsyncState
        :loading="query.isPending.value"
        :error="query.error.value"
        :empty="subChannelRows.length === 0"
        empty-title="No channel data"
        empty-body="Channels fill in once the ETL has landed the customer reporting hierarchy."
        :rows="4"
        @retry="query.refetch()"
      >
        <ChannelMixChart v-if="chartRows.length" :rows="chartRows" class="mb-5" />

        <DataGrid
          v-model:globalFilter="search"
          :columns="columns"
          :data="rows"
          :initial-sorting="[{ id: 'revenue_ytd', desc: true }]"
          searchable
          search-label="Search channels"
          search-placeholder="Search channels…"
          :get-row-id="rowId"
          min-width="52rem"
          @rows-change="visibleRows = $event"
        >
          <template #cell-label="{ row }">
            <span class="text-ink font-semibold">{{ label(row) }}</span>
            <span
              v-if="grain === 'sub_channel'"
              class="text-muted block text-[13px]"
            >
              {{ row.channel }}
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
              {{ share(shareOf(row.revenue_ytd, bookTotal.revenue_ytd)) }} of book
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
          </template>

          <template #cell-backlog_amount="{ row }">
            <span class="text-ink tabular-nums">{{ money(row.backlog_amount) }}</span>
          </template>

          <!-- A goal total only exists where accounts carry goals, so the
               denominator is spelled out rather than implied. -->
          <template #cell-attainment="{ row }">
            <template v-if="attainment(row) != null">
              <span class="text-ink tabular-nums">
                {{ Math.round(attainment(row) ?? 0) }}%
              </span>
              <span class="text-muted block text-[13px] tabular-nums">
                of {{ money(row.goal_total) }}
              </span>
            </template>
            <span v-else class="text-muted">no goals set</span>
          </template>

          <template #cell-lapsed_accounts="{ row }">
            <span class="tabular-nums" :class="row.lapsed_accounts ? 'text-ink' : 'text-muted'">
              {{ count(row.lapsed_accounts) }}
            </span>
          </template>

          <!-- Phone layout -->
          <template #card="{ row }">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0 flex-1">
                <p class="text-ink truncate font-semibold">{{ label(row) }}</p>
                <p class="text-muted mt-0.5 text-[15px] tabular-nums">
                  {{ money(row.revenue_ytd) }} ·
                  {{ share(shareOf(row.revenue_ytd, bookTotal.revenue_ytd)) }} of book
                </p>
                <p class="text-muted mt-0.5 text-[15px] tabular-nums">
                  {{ count(row.buying_accounts) }} of {{ count(row.accounts) }} accounts
                  buying · {{ count(row.lapsed_accounts) }} lapsed
                </p>
                <p
                  v-if="row.last_invoice_date"
                  class="text-muted mt-0.5 text-[13px]"
                >
                  Last invoice {{ shortDate(row.last_invoice_date) }}
                </p>
              </div>
              <span class="shrink-0 tabular-nums" :class="yoyTone(row)">
                {{ yoyLabel(row) }}
              </span>
            </div>
          </template>

          <template #empty>
            <p class="text-muted py-10 text-center text-[15px]">
              No channels match that search.
            </p>
          </template>
        </DataGrid>
      </AsyncState>
    </div>
  </AppCard>
</template>
