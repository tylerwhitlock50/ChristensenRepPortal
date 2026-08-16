<script setup lang="ts">
import { computed } from 'vue'
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
import { money } from '@/lib/format'
import { yoyPct, type ChannelRow } from '@/composables/useAdminReports'

/**
 * Revenue by channel — this year to date against the same days last year,
 * as horizontal grouped bars.
 *
 * Horizontal because the categories are phrases ("Direct to Consumer",
 * "Special Programs"): vertical bars would either rotate those labels 45° or
 * truncate them. One shared x-axis, both series in USD — no second scale.
 *
 * The parent passes rows already rolled up to channel grain and already
 * sorted, so what is drawn is exactly what the table above it lists, in the
 * same order. This component sums nothing.
 */
const props = defineProps<{ rows: ChannelRow[] }>()

// Only the controllers this chart draws — same reasoning as
// AccountRevenueChart.vue: `registerables` would pull in every chart type.
ChartJS.register(BarController, BarElement, CategoryScale, LinearScale, Tooltip)

// The same two-series pairing the account revenue chart uses: brand green for
// the current period, warm gray for the prior one. Validated for separation
// (ΔE 28 under protanopia, 30 normal) and both clear 3:1 on white. Here both
// series are bars, so the legend and the fixed left-to-right order inside each
// group carry identity alongside the hue.
const CURRENT_COLOR = '#1f3a2e' // --color-brand
const PRIOR_COLOR = '#8a857a'
const GRID_COLOR = '#e6e3dc'
const TICK_COLOR = '#6e6a61' // --color-muted

const CURRENT_LABEL = 'This year to date'
const PRIOR_LABEL = 'Same days last year'

const compactMoney = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  notation: 'compact',
  maximumFractionDigits: 1,
})

const labels = computed(() => props.rows.map((r) => r.channel))

/** Two bars per channel need room; 12 channels must not squash into 90px. */
const chartHeight = computed(() => Math.max(200, props.rows.length * 46 + 24))

const chartData = computed<ChartData<'bar', number[], string>>(() => ({
  labels: labels.value,
  datasets: [
    {
      label: CURRENT_LABEL,
      data: props.rows.map((r) => r.revenue_ytd),
      backgroundColor: CURRENT_COLOR,
      borderRadius: 2,
      categoryPercentage: 0.74,
      barPercentage: 0.9,
    },
    {
      label: PRIOR_LABEL,
      data: props.rows.map((r) => r.revenue_prior_ytd),
      backgroundColor: PRIOR_COLOR,
      borderRadius: 2,
      categoryPercentage: 0.74,
      barPercentage: 0.9,
    },
  ],
}))

const chartOptions = computed<ChartOptions<'bar'>>(() => ({
  indexAxis: 'y',
  responsive: true,
  maintainAspectRatio: false,
  animation: { duration: 220 },
  // Whole-row hit target: a thumb anywhere on the channel gets both of its
  // numbers instead of having to land on one 9px bar.
  interaction: { mode: 'index', intersect: false },
  plugins: {
    // HTML legend below the canvas — wraps at 390px, stays selectable.
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
      callbacks: {
        label: (ctx: TooltipItem<'bar'>) =>
          ` ${ctx.dataset.label ?? ''}: ${money(ctx.parsed.x)}`,
        // The comparison is the point of the chart, so the tooltip closes
        // with it rather than making the reader subtract two bars by eye.
        afterBody: (items: TooltipItem<'bar'>[]) => {
          const row = props.rows[items[0]?.dataIndex ?? 0]
          if (!row) return ''
          const pct = yoyPct(row.revenue_ytd, row.revenue_prior_ytd)
          if (pct == null) return 'No sales in this channel last year'
          const sign = pct >= 0 ? '+' : ''
          return `${sign}${pct.toFixed(1)}% year over year`
        },
      },
    },
  },
  scales: {
    x: {
      beginAtZero: true,
      border: { display: false },
      grid: { color: GRID_COLOR },
      ticks: {
        color: TICK_COLOR,
        font: { size: 11 },
        maxTicksLimit: 4,
        callback: (value: string | number) => compactMoney.format(Number(value)),
      },
    },
    y: {
      grid: { display: false },
      border: { color: GRID_COLOR },
      ticks: { color: TICK_COLOR, font: { size: 12 }, autoSkip: false },
    },
  },
}))

/** Same cast-at-the-boundary reasoning as AccountRevenueChart.vue. */
const dataProp = computed(() => chartData.value as unknown as ChartProps['data'])
const optionsProp = computed(
  () => chartOptions.value as unknown as ChartProps['options'],
)

/** What a screen reader gets in place of the canvas. The grid below the
 *  chart is the table view, so this only has to orient. */
const chartAriaLabel = computed(() => {
  const top = props.rows[0]
  const head = top
    ? `Largest is ${top.channel} at ${money(top.revenue_ytd)}, versus ${money(top.revenue_prior_ytd)} a year earlier. `
    : ''
  return (
    `Horizontal bar chart of invoiced revenue year to date by channel, ${props.rows.length} channels. ` +
    head +
    'The same figures follow in the table below.'
  )
})
</script>

<template>
  <div>
    <ul class="mb-3 flex flex-wrap items-center gap-x-5 gap-y-1 text-[13px]">
      <li class="flex items-center gap-2">
        <span
          class="inline-block h-2.5 w-2.5 shrink-0"
          :style="{ backgroundColor: CURRENT_COLOR }"
          aria-hidden="true"
        />
        <span class="text-ink-2">{{ CURRENT_LABEL }}</span>
      </li>
      <li class="flex items-center gap-2">
        <span
          class="inline-block h-2.5 w-2.5 shrink-0"
          :style="{ backgroundColor: PRIOR_COLOR }"
          aria-hidden="true"
        />
        <span class="text-ink-2">{{ PRIOR_LABEL }}</span>
      </li>
    </ul>

    <div :style="{ height: `${chartHeight}px` }">
      <Chart
        type="bar"
        :data="dataProp"
        :options="optionsProp"
        :aria-label="chartAriaLabel"
        role="img"
      />
    </div>
  </div>
</template>
