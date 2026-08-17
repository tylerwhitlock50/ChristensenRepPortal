<script setup lang="ts">
/**
 * Admin → Reports. Two questions the rest of the admin section could not
 * answer: how is each CHANNEL doing, and how is each REP GROUP doing.
 *
 * Execution answers "who is working the list" and Goals answers "how is each
 * person tracking". Neither rolls the book up the two ways a principal thinks
 * about it — by where the revenue comes from, and by which agency is
 * producing it. Both cards read the rollups added in 20260816120000.
 *
 * The headline tiles here are the company total, so the two tables below can
 * be read as shares of a number that is on screen rather than one the reader
 * has to hold in their head. They come from the channel query — the two views
 * carry the same active/external scope, so either would total the same.
 */
import { computed } from 'vue'
import ChannelPerformanceCard from '@/components/ChannelPerformanceCard.vue'
import RepGroupPerformanceCard from '@/components/RepGroupPerformanceCard.vue'
import FreshnessStamp from '@/components/FreshnessStamp.vue'
import StatTile from '@/components/ui/StatTile.vue'
import {
  totalChannels,
  useChannelPerformance,
  yoyPct,
} from '@/composables/useAdminReports'
import { count, money } from '@/lib/format'

/**
 * The same query ChannelPerformanceCard runs. TanStack Query dedupes on the
 * key, so this is one request, not two.
 */
const channels = useChannelPerformance()

const total = computed(() => totalChannels(channels.data.value ?? []))

/**
 * A failed query must not render as "$0, 0 accounts" — that reads like a
 * catastrophic year rather than a broken request. Dashes until the numbers
 * are real; the cards below carry the error and the retry button.
 */
const ready = computed(() => !channels.error.value && !channels.isPending.value)
const dash = '—'

const yoyLabel = computed(() => {
  const pct = yoyPct(total.value.revenue_ytd, total.value.revenue_prior_ytd)
  if (pct == null) return 'no prior year'
  return `${pct >= 0 ? '+' : '−'}${Math.abs(pct).toFixed(1)}% vs last year`
})
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Reports
      </p>
      <h1 class="u-display mt-1 text-4xl">Where the year is coming from</h1>
      <p class="text-muted mt-2 text-[15px]">
        The book cut two ways — by channel, and by rep group. Active external
        accounts only.
      </p>
      <FreshnessStamp class="mt-1" />
    </header>

    <div class="bg-line border-line grid grid-cols-2 gap-px border sm:grid-cols-4">
      <StatTile
        label="Revenue YTD"
        :value="ready ? money(total.revenue_ytd) : dash"
        :sub="ready ? yoyLabel : undefined"
      />
      <StatTile
        label="Booked YTD"
        :value="ready ? money(total.bookings_ytd) : dash"
        sub="orders written"
      />
      <StatTile
        label="Buying accounts"
        :value="ready ? count(total.buying_accounts) : dash"
        :sub="ready ? `of ${count(total.accounts)} active` : undefined"
      />
      <StatTile
        label="Lapsed"
        :value="ready ? count(total.lapsed_accounts) : dash"
        sub="bought last year, not this"
        :tone="ready && total.lapsed_accounts > 0 ? 'alert' : 'default'"
      />
    </div>

    <ChannelPerformanceCard />
    <RepGroupPerformanceCard />
  </div>
</template>
