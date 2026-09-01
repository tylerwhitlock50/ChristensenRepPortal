<script setup lang="ts">
import { computed, toRef } from 'vue'
import {
  BarController,
  BarElement,
  CategoryScale,
  Chart as ChartJS,
  LinearScale,
  Tooltip,
  type ChartData,
  type ChartOptions,
  type TooltipItem,
} from 'chart.js'
import { Chart } from 'vue-chartjs'
import type { ChartProps } from 'vue-chartjs'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { money } from '@/lib/format'
import {
  buildCalendarYearSeries,
  deltaLabel,
  useAccountRevenueMonthly,
} from '@/composables/useAccountMetrics'

/**
 * Revenue by month, Jan–Dec: two bars per month — this calendar year next to
 * the same month last year. Rep feedback asked for exactly this shape; the
 * old view was trailing-12 bars with a dashed prior-year line, and reading
 * "how is March doing vs last March" took a tooltip.
 *
 * Months that haven't happened yet draw NOTHING for the current year (null,
 * not 0) — a zero-height November in September is a story that isn't there.
 * There is deliberately no trend line and no second y-axis: both series are
 * the same measure (invoiced revenue, USD) on one scale.
 *
 * Everything drawn here was summed in Postgres by
 * public.v_account_revenue_monthly. This component only aligns 24 rows into
 * two 12-month arrays.
 */
const props = defineProps<{ customerKey: string }>()

// Only what this chart draws. Importing `registerables` would pull every
// controller in chart.js into the bundle for a chart that uses one.
ChartJS.register(BarController, BarElement, CategoryScale, LinearScale, Tooltip)

// Current = the one brand green. Prior = a warm gray. Position carries the
// identity too (prior always left, current right), so the pairs stay
// separable for a red-green colorblind rep and on a phone in direct
// sunlight. Both clear 3:1 against white.
const CURRENT_COLOR = '#1f3a2e' // --color-brand
const PRIOR_COLOR = '#8a857a'
const GRID_COLOR = '#e6e3dc'
const TICK_COLOR = '#6e6a61' // --color-muted

const compactMoney = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  notation: 'compact',
  maximumFractionDigits: 1,
})

const query = useAccountRevenueMonthly(toRef(props, 'customerKey'))
const series = computed(() => buildCalendarYearSeries(query.data.value ?? []))

const currentLabel = computed(() => String(series.value.currentYear))
const priorLabel = computed(() => String(series.value.priorYear))

const chartData = computed<ChartData<'bar', (number | null)[], string>>(() => ({
  labels: series.value.labels,
  datasets: [
    {
      label: priorLabel.value,
      data: series.value.prior,
      backgroundColor: PRIOR_COLOR,
      borderRadius: 2,
      categoryPercentage: 0.72,
      barPercentage: 0.9,
    },
    {
      label: currentLabel.value,
      data: series.value.current,
      backgroundColor: CURRENT_COLOR,
      // 2px, like every other corner in the design system. borderSkipped is
      // left at its default so only the far end of the bar is rounded and
      // the baseline stays square.
      borderRadius: 2,
      categoryPercentage: 0.72,
      barPercentage: 0.9,
    },
  ],
}))

const chartOptions = computed<ChartOptions<'bar'>>(() => ({
  responsive: true,
  // The wrapper owns the height; a fixed aspect ratio would leave this ~100px
  // tall on a 390px phone.
  maintainAspectRatio: false,
  animation: { duration: 220 },
  layout: { padding: { top: 4 } },
  // Whole-column hit target: a thumb anywhere in the month gets both bars
  // instead of having to land on a 6px-wide one.
  interaction: { mode: 'index', intersect: false },
  plugins: {
    // The legend is HTML below the canvas — it wraps properly at 390px, stays
    // selectable, and keeps chart.js's Legend plugin out of the bundle.
    legend: { display: false },
    tooltip: {
      backgroundColor: '#12130f',
      padding: 10,
      cornerRadius: 2,
      displayColors: true,
      boxWidth: 8,
      boxHeight: 8,
      titleFont: { size: 13, weight: 600 },
      bodyFont: { size: 13 },
      // Current year first, even though it draws second.
      itemSort: (a: TooltipItem<'bar'>, b: TooltipItem<'bar'>) =>
        b.datasetIndex - a.datasetIndex,
      callbacks: {
        title: (items: TooltipItem<'bar'>[]) =>
          series.value.labels[items[0]?.dataIndex ?? 0] ?? '',
        label: (ctx: TooltipItem<'bar'>) =>
          ` ${ctx.dataset.label ?? ''}: ${money(ctx.parsed.y)}`,
      },
    },
  },
  scales: {
    x: {
      grid: { display: false },
      border: { color: GRID_COLOR },
      ticks: {
        color: TICK_COLOR,
        font: { size: 11 },
        maxRotation: 0,
        autoSkipPadding: 6,
      },
    },
    y: {
      beginAtZero: true,
      border: { display: false },
      grid: { color: GRID_COLOR },
      ticks: {
        color: TICK_COLOR,
        font: { size: 11 },
        // Four gridlines is enough to read a magnitude; more is noise.
        maxTicksLimit: 4,
        callback: (value: string | number) => compactMoney.format(Number(value)),
      },
    },
  },
}))

/**
 * vue-chartjs types the generic <Chart> against the whole ChartType union, so
 * its `data`/`options` props are the widened shapes. The objects above are
 * the narrow 'bar' versions — which is what makes `ctx.parsed.y` and the
 * scale options type-check at all — and TypeScript will not carry a narrowed
 * callback signature into a union-typed one. Cast at the boundary rather
 * than loosening the types where they do useful work.
 */
const dataProp = computed(() => chartData.value as unknown as ChartProps['data'])
const optionsProp = computed(
  () => chartOptions.value as unknown as ChartProps['options'],
)

/** What a screen reader gets in place of the canvas, before the table. */
const chartAriaLabel = computed(() => {
  const s = series.value
  const compare = s.completedThroughLabel
    ? `Through ${s.completedThroughLabel}: ${money(s.currentCompleted)} versus ` +
      `${money(s.priorCompleted)} in ${s.priorYear} (${deltaLabel(s.deltaPct)}). `
    : ''
  return (
    `Bar chart of monthly invoiced revenue, January through December, ` +
    `${s.currentYear} next to ${s.priorYear}. ` +
    `${money(s.currentTotal)} so far in ${s.currentYear}. ` +
    compare +
    `The same figures follow as a table.`
  )
})

const deltaTone = computed(() => {
  const pct = series.value.deltaPct
  if (pct == null) return 'text-muted'
  if (pct <= -10) return 'text-danger'
  if (pct >= 10) return 'text-brand'
  return 'text-muted'
})
</script>

<template>
  <AppCard title="Revenue by month" :hint="deltaLabel(series.deltaPct)">
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && !query.error.value && !series.hasData"
      empty-title="No invoiced revenue"
      empty-body="Nothing has been invoiced to this account in the last 24 months."
      :rows="2"
      @retry="query.refetch()"
    >
      <!-- HTML legend: wraps at 390px, no canvas hit-testing involved. The
           two totals cover different spans (YTD vs full year), and the words
           say so — comparing them raw would flatter every mid-year read. -->
      <ul class="mb-3 flex flex-wrap items-center gap-x-5 gap-y-1 text-[13px]">
        <li class="flex items-center gap-2">
          <span
            class="inline-block h-2.5 w-2.5 rounded-[1px]"
            :style="{ backgroundColor: CURRENT_COLOR }"
            aria-hidden="true"
          />
          <span class="text-ink">{{ currentLabel }}</span>
          <span class="text-muted tabular-nums">
            {{ money(series.currentTotal) }} YTD
          </span>
        </li>
        <li class="flex items-center gap-2">
          <span
            class="inline-block h-2.5 w-2.5 rounded-[1px]"
            :style="{ backgroundColor: PRIOR_COLOR }"
            aria-hidden="true"
          />
          <span class="text-ink">{{ priorLabel }}</span>
          <span class="text-muted tabular-nums">
            {{ money(series.priorTotalFull) }} full year
          </span>
        </li>
      </ul>

      <div class="relative h-56 sm:h-64">
        <Chart
          type="bar"
          :data="dataProp"
          :options="optionsProp"
          :aria-label="chartAriaLabel"
        />
      </div>

      <!-- The delta covers COMPLETE months only — the in-progress month
           would read as a collapse against last year's full month. In
           January there's nothing complete to compare, so just the total. -->
      <p class="text-muted mt-3 text-[13px] leading-relaxed">
        <span class="text-ink font-semibold tabular-nums">{{
          money(series.currentTotal)
        }}</span>
        so far in {{ series.currentYear
        }}<template v-if="series.completedThroughLabel">
          — through {{ series.completedThroughLabel }}:
          <span class="text-ink font-semibold tabular-nums">{{
            money(series.currentCompleted)
          }}</span>
          versus
          <span class="text-ink font-semibold tabular-nums">{{
            money(series.priorCompleted)
          }}</span>
          in {{ series.priorYear }} —
          <span :class="deltaTone" class="font-semibold">{{
            deltaLabel(series.deltaPct)
          }}</span></template>
      </p>

      <!--
        A canvas is invisible to a screen reader beyond its label, so the same
        numbers exist as a real table. Visually hidden rather than hidden
        behind a toggle: it costs nothing and cannot drift out of sync with
        the chart.
      -->
      <table class="sr-only">
        <caption>
          Monthly invoiced revenue, January through December,
          {{ series.currentYear }} versus {{ series.priorYear }}
        </caption>
        <thead>
          <tr>
            <th scope="col">Month</th>
            <th scope="col">{{ currentLabel }}</th>
            <th scope="col">{{ priorLabel }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="(label, i) in series.labels" :key="label">
            <th scope="row">{{ label }}</th>
            <td>
              {{ series.current[i] == null ? 'not yet' : money(series.current[i]) }}
            </td>
            <td>{{ money(series.prior[i]) }}</td>
          </tr>
        </tbody>
        <tfoot>
          <tr>
            <th scope="row">Total</th>
            <td>{{ money(series.currentTotal) }} (year to date)</td>
            <td>{{ money(series.priorTotalFull) }}</td>
          </tr>
        </tfoot>
      </table>
    </AsyncState>
  </AppCard>
</template>
