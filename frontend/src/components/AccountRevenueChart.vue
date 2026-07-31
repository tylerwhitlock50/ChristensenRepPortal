<script setup lang="ts">
import { computed, toRef } from 'vue'
import {
  BarController,
  BarElement,
  CategoryScale,
  Chart as ChartJS,
  LineController,
  LineElement,
  LinearScale,
  PointElement,
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
  buildRevenueSeries,
  deltaLabel,
  useAccountRevenueMonthly,
} from '@/composables/useAccountMetrics'

/**
 * Revenue by month — the last 12 months as bars, the same 12 months a year
 * earlier as a dashed line, on one axis.
 *
 * Both series are the same measure (invoiced revenue, USD) on one scale.
 * There is deliberately no second y-axis: two scales on one chart is the
 * fastest way to make a rep read a crossing as a story that isn't there.
 *
 * Everything drawn here was summed in Postgres by
 * public.v_account_revenue_monthly. This component only aligns 24 rows into
 * two 12-month arrays.
 */
const props = defineProps<{ customerKey: string }>()

// Only what this chart draws. Importing `registerables` would pull every
// controller in chart.js into the bundle for a chart that uses two.
ChartJS.register(
  BarController,
  BarElement,
  LineController,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Tooltip,
)

// Current = the one brand green. Prior = a warm gray, dashed. Shape (bar vs
// line) and dash pattern carry the identity as well as color does, so the
// two series stay separable for a red-green colorblind rep and on a phone in
// direct sunlight. Both clear 3:1 against white.
const CURRENT_COLOR = '#1f3a2e' // --color-brand
const PRIOR_COLOR = '#8a857a'
const GRID_COLOR = '#e6e3dc'
const TICK_COLOR = '#6e6a61' // --color-muted

const CURRENT_LABEL = 'Last 12 months'
const PRIOR_LABEL = 'Prior year'

const compactMoney = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  notation: 'compact',
  maximumFractionDigits: 1,
})

const query = useAccountRevenueMonthly(toRef(props, 'customerKey'))
const series = computed(() => buildRevenueSeries(query.data.value ?? []))

const chartData = computed<ChartData<'bar' | 'line', number[], string>>(() => ({
  labels: series.value.labels,
  datasets: [
    {
      type: 'bar',
      label: CURRENT_LABEL,
      data: series.value.current,
      backgroundColor: CURRENT_COLOR,
      // 2px, like every other corner in the design system. borderSkipped is
      // left at its default so only the far end of the bar is rounded and
      // the baseline stays square.
      borderRadius: 2,
      categoryPercentage: 0.78,
      barPercentage: 0.92,
      order: 1,
    },
    {
      type: 'line',
      label: PRIOR_LABEL,
      data: series.value.prior,
      borderColor: PRIOR_COLOR,
      backgroundColor: PRIOR_COLOR,
      borderWidth: 2,
      borderDash: [5, 4],
      tension: 0.3,
      pointRadius: 0,
      pointHoverRadius: 5,
      pointBackgroundColor: PRIOR_COLOR,
      pointBorderColor: '#ffffff',
      pointBorderWidth: 2,
      // Lower order draws last, i.e. on top of the bars.
      order: 0,
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
  // Whole-column hit target: a thumb anywhere in the month gets that month
  // instead of having to land on a 6px-wide bar.
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
      // Current year first, whichever dataset happens to draw on top.
      itemSort: (a: TooltipItem<'bar'>, b: TooltipItem<'bar'>) =>
        a.datasetIndex - b.datasetIndex,
      callbacks: {
        title: (items: TooltipItem<'bar'>[]) =>
          series.value.monthLabels[items[0]?.dataIndex ?? 0] ?? '',
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
  return (
    'Bar and line chart of monthly invoiced revenue. ' +
    `${s.monthLabels[0]} through ${s.monthLabels[11]} totals ${money(s.currentTotal)}, ` +
    `versus ${money(s.priorTotal)} in the same months a year earlier ` +
    `(${deltaLabel(s.deltaPct)}). The same figures follow as a table.`
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
      <!-- HTML legend: wraps at 390px, no canvas hit-testing involved -->
      <ul class="mb-3 flex flex-wrap items-center gap-x-5 gap-y-1 text-[13px]">
        <li class="flex items-center gap-2">
          <span
            class="inline-block h-2.5 w-2.5 rounded-[1px]"
            :style="{ backgroundColor: CURRENT_COLOR }"
            aria-hidden="true"
          />
          <span class="text-ink">{{ CURRENT_LABEL }}</span>
          <span class="text-muted tabular-nums">{{ money(series.currentTotal) }}</span>
        </li>
        <li class="flex items-center gap-2">
          <span
            class="inline-block h-0.5 w-4"
            :style="{
              backgroundImage: `repeating-linear-gradient(to right, ${PRIOR_COLOR} 0 5px, transparent 5px 9px)`,
            }"
            aria-hidden="true"
          />
          <span class="text-ink">{{ PRIOR_LABEL }}</span>
          <span class="text-muted tabular-nums">{{ money(series.priorTotal) }}</span>
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

      <p class="text-muted mt-3 text-[13px] leading-relaxed">
        <span class="text-ink font-semibold tabular-nums">{{
          money(series.currentTotal)
        }}</span>
        over the last 12 months, versus
        <span class="text-ink font-semibold tabular-nums">{{
          money(series.priorTotal)
        }}</span>
        the year before —
        <span :class="deltaTone" class="font-semibold">{{
          deltaLabel(series.deltaPct)
        }}</span>
      </p>

      <!--
        A canvas is invisible to a screen reader beyond its label, so the same
        numbers exist as a real table. Visually hidden rather than hidden
        behind a toggle: it costs nothing and cannot drift out of sync with
        the chart.
      -->
      <table class="sr-only">
        <caption>
          Monthly invoiced revenue, last 12 months versus the same months a
          year earlier
        </caption>
        <thead>
          <tr>
            <th scope="col">Month</th>
            <th scope="col">{{ CURRENT_LABEL }}</th>
            <th scope="col">{{ PRIOR_LABEL }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="(label, i) in series.monthLabels" :key="label">
            <th scope="row">{{ label }}</th>
            <td>{{ money(series.current[i]) }}</td>
            <td>{{ series.priorMonthLabels[i] }}: {{ money(series.prior[i]) }}</td>
          </tr>
        </tbody>
        <tfoot>
          <tr>
            <th scope="row">Total</th>
            <td>{{ money(series.currentTotal) }}</td>
            <td>{{ money(series.priorTotal) }}</td>
          </tr>
        </tfoot>
      </table>
    </AsyncState>
  </AppCard>
</template>
