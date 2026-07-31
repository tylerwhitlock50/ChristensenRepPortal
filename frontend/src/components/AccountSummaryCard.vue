<script setup lang="ts">
import { computed, toRef } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { count, daysAgo, money, shortDate } from '@/lib/format'
import {
  deltaLabel,
  percentChange,
  useAccountSummary,
} from '@/composables/useAccountMetrics'

/**
 * The four numbers a rep needs before walking into a dealer: how the year is
 * going, how it went last year, the rolling twelve, and what is still owed to
 * them.
 *
 * Every figure comes pre-aggregated from public.v_account_summary — see
 * useAccountMetrics.ts. Nothing here sums a fact table.
 */
const props = defineProps<{ customerKey: string }>()

const query = useAccountSummary(toRef(props, 'customerKey'))
const summary = computed(() => query.data.value ?? null)

const deltaPct = computed(() =>
  summary.value
    ? percentChange(summary.value.revenue_ytd, summary.value.revenue_prior_ytd)
    : null,
)

/**
 * Red at −30% or worse, matching the `revenue_down_yoy` threshold the
 * recommendation engine ships with (rule_settings, 005). The tile turning red
 * and a recommendation appearing overnight should mean the same thing — if
 * the admin retunes the rule, retune this with it.
 */
const ytdTone = computed<'default' | 'alert'>(() =>
  deltaPct.value != null && deltaPct.value <= -30 ? 'alert' : 'default',
)

const ytdSub = computed(() => {
  const s = summary.value
  if (!s) return ''
  if (!s.revenue_prior_ytd) return 'No revenue this time last year'
  return `${deltaLabel(deltaPct.value)} vs ${money(s.revenue_prior_ytd)} last year`
})

const openOrdersSub = computed(() => {
  const s = summary.value
  if (!s || !s.open_order_count) return 'Nothing on backlog'
  const qty = s.backlog_qty ? ` · ${count(Math.round(s.backlog_qty))} units` : ''
  return `${money(s.open_order_value)} open${qty}`
})
</script>

<template>
  <AppCard title="Performance">
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && !query.error.value && !summary"
      empty-title="No ERP history"
      empty-body="This account has no invoice or order lines in the ERP yet."
      :rows="2"
      @retry="query.refetch()"
    >
      <div v-if="summary" class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <StatTile
          label="Revenue YTD"
          :value="money(summary.revenue_ytd)"
          :sub="ytdSub"
          :tone="ytdTone"
        />
        <StatTile
          label="Prior YTD"
          :value="money(summary.revenue_prior_ytd)"
          sub="Same days last year"
        />
        <StatTile
          label="Trailing 12 mo"
          :value="money(summary.revenue_trailing_12m)"
          sub="Rolling, to today"
        />
        <StatTile
          label="Open orders"
          :value="count(summary.open_order_count)"
          :sub="openOrdersSub"
        />
      </div>

      <!-- Recency in plain English first; persona #1 reads "23 days ago"
           faster than a date, and the date is right there for the one rep who
           wants it. -->
      <dl
        v-if="summary"
        class="border-line mt-4 grid grid-cols-1 gap-2 border-t pt-3 text-[13px] sm:grid-cols-2"
      >
        <div class="flex items-baseline gap-2">
          <dt class="text-muted">Last order</dt>
          <dd class="text-ink font-medium">
            {{ daysAgo(summary.last_order_date) }}
            <span v-if="summary.last_order_date" class="text-muted font-normal">
              ({{ shortDate(summary.last_order_date) }})
            </span>
          </dd>
        </div>
        <div class="flex items-baseline gap-2">
          <dt class="text-muted">Last invoice</dt>
          <dd class="text-ink font-medium">
            {{ daysAgo(summary.last_invoice_date) }}
            <span v-if="summary.last_invoice_date" class="text-muted font-normal">
              ({{ shortDate(summary.last_invoice_date) }})
            </span>
          </dd>
        </div>
      </dl>
    </AsyncState>
  </AppCard>
</template>
