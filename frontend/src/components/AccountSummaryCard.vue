<script setup lang="ts">
import { computed, toRef } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import AccountGoalPanel from '@/components/AccountGoalPanel.vue'
import { format, isThisYear, parseISO } from 'date-fns'
import { daysAgo, money } from '@/lib/format'
import {
  deltaLabel,
  percentChange,
  useAccountSummary,
} from '@/composables/useAccountMetrics'

/**
 * How the year is going: this year, the same days last year, the rolling
 * twelve, and when they were last invoiced — then the goal all of that is
 * measured against.
 *
 * Every figure comes pre-aggregated from public.v_account_summary — see
 * useAccountMetrics.ts. Nothing here sums a fact table.
 *
 * The open-orders tile, "Last order" and the ordering-rhythm sentence used
 * to live here as well, and the page printed each of them two or three
 * times. They are pre-call facts, so they now live once, in the Before you
 * call card under the header.
 *
 * AccountGoalPanel sits OUTSIDE the AsyncState below on purpose: it owns its
 * own query and its own empty state, and an account with no ERP history yet
 * is exactly the kind a rep wants to put a goal on.
 */
const props = defineProps<{ customerKey: string }>()

/* "Last invoice" is a door to the shipments card: AccountView catches this
   and expands/scrolls it. StatTile itself stays a dumb display block — the
   button wrapper lives here. */
const emit = defineEmits<{ (e: 'show-last-invoice'): void }>()

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

/** "Oct 1", or "Mar 2024" when it was not this year — short enough for a
    tile at half a phone's width, where "11 days ago" wrapped. */
function tileDate(value: string): string {
  const d = parseISO(value)
  return format(d, isThisYear(d) ? 'MMM d' : 'MMM yyyy')
}

const ytdSub = computed(() => {
  const s = summary.value
  if (!s) return ''
  if (!s.revenue_prior_ytd) return 'No revenue this time last year'
  return `${deltaLabel(deltaPct.value)} vs ${money(s.revenue_prior_ytd)} last year`
})
</script>

<template>
  <AppCard title="Performance">
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :has-data="query.data.value !== undefined"
      :updated-at="query.dataUpdatedAt.value"
      :empty="!query.isPending.value && !summary"
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
        <!-- The date big and short, the plain-English recency right under
             it — persona #1 reads "23 days ago" faster than a date. h-full on
             both button and tile: the button is the grid item, and a
             content-height tile inside it would leave a bare band of the gap
             color under this cell only. Hover goes on the tile — its opaque
             bg-surface would paint over a button hover. Plain text when
             there is no invoice to show. -->
        <button
          v-if="summary.last_invoice_date"
          type="button"
          class="block h-full w-full text-left"
          title="Show recent shipments"
          @click="emit('show-last-invoice')"
        >
          <StatTile
            class="h-full transition-colors hover:bg-canvas"
            label="Last invoice"
            :value="tileDate(summary.last_invoice_date)"
            :sub="daysAgo(summary.last_invoice_date)"
          />
        </button>
        <StatTile v-else label="Last invoice" value="never" sub="Nothing invoiced yet" />
      </div>
    </AsyncState>

    <AccountGoalPanel :customer-key="customerKey" class="mt-4" />
  </AppCard>
</template>
