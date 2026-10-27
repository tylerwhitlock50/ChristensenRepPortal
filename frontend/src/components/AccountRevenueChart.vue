<script setup lang="ts">
import { computed, toRef } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import RevenueYearChart from '@/components/RevenueYearChart.vue'
import {
  buildCalendarYearSeries,
  deltaLabel,
  useAccountRevenueMonthly,
} from '@/composables/useAccountMetrics'

/**
 * One account's revenue by month, this calendar year next to last — the
 * chart itself (and why it is shaped this way) is RevenueYearChart.
 *
 * Everything drawn here was summed in Postgres by
 * public.v_account_revenue_monthly. This component only aligns 24 rows into
 * two 12-month arrays.
 */
const props = defineProps<{ customerKey: string }>()

const query = useAccountRevenueMonthly(toRef(props, 'customerKey'))
const series = computed(() => buildCalendarYearSeries(query.data.value ?? []))
</script>

<template>
  <AppCard title="Revenue by month" :hint="deltaLabel(series.deltaPct)">
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :has-data="query.data.value !== undefined"
      :updated-at="query.dataUpdatedAt.value"
      :empty="!query.isPending.value && !series.hasData"
      empty-title="No invoiced revenue"
      empty-body="Nothing has been invoiced to this account in the last 24 months."
      :rows="2"
      @retry="query.refetch()"
    >
      <RevenueYearChart :series="series" />
    </AsyncState>
  </AppCard>
</template>
