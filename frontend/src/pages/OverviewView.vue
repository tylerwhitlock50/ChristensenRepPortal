<script lang="ts">
/**
 * Module scope on purpose — this block runs once per page load, while
 * `<script setup>` below re-runs on every mount. See the Sales Brief note
 * there for why the auto-generate guard has to outlive the component.
 */
let lastAutoBrief: string | null = null
</script>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { format, isBefore, startOfDay } from 'date-fns'
import { useSessionStore } from '@/stores/session'
import {
  largestMovers,
  territoryTotals,
  useTerritoryAccounts,
  useTerritoryRecentOrders,
  worthInvestigating,
} from '@/composables/useOverview'
import { useAiBrief, useGenerateAiBrief } from '@/composables/useAiBrief'
import { deltaLabel } from '@/composables/useAccountMetrics'
import SalesBriefCard from '@/components/SalesBriefCard.vue'
import FreshnessStamp from '@/components/FreshnessStamp.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { daysAgo, money } from '@/lib/format'

/**
 * The morning briefing (data-first restructure). Canonical flow, top to
 * bottom: Data → Metrics → AI Interpretation → Observations → Drill into
 * Account. A rep should answer "how is my territory doing, what changed,
 * who deserves attention" in 20 seconds without leaving this page.
 */

const session = useSessionStore()

const accountsQuery = useTerritoryAccounts()
const recentQuery = useTerritoryRecentOrders()

const rows = computed(() => accountsQuery.data.value ?? [])
const totals = computed(() => territoryTotals(rows.value))
const movers = computed(() => largestMovers(rows.value))
const observations = computed(() => worthInvestigating(rows.value))

/**
 * `largestMovers` returns up and down separately and the card used to
 * concatenate them into one list, leaving a sign and a colour as the only
 * thing telling a riser from a faller. "Who is up, who is down" is the
 * question the card exists to answer, so it gets two labelled groups.
 * Empty sides drop out rather than render a heading over nothing.
 */
const moverGroups = computed(() =>
  [
    { key: 'up', label: 'Up the most', rows: movers.value.up },
    { key: 'down', label: 'Down the most', rows: movers.value.down },
  ].filter((g) => g.rows.length > 0),
)
const recent = computed(() => recentQuery.data.value ?? [])

/* ---- Sales Brief --------------------------------------------------------
   Auto-generates ONCE A DAY when there is no brief or it predates today; the
   Edge Function's context hash makes a same-data regenerate a free cached
   return, so "every morning" costs one real generation per actual data
   change. Manual Regenerate stays available.

   The guard is module-scoped, and that is the point. As a ref inside setup it
   reset on every mount, so a rep bouncing Overview → Account → Overview fired
   a generation each time — and when generation came back insufficient_data or
   errored, the stored brief stayed stale, so it fired again on the next visit
   and the one after that, forever. Module scope makes it once per page load
   instead of once per navigation; a hard reload re-arming it is fine.
------------------------------------------------------------------------- */
const briefQuery = useAiBrief('territory.brief')
const generate = useGenerateAiBrief()
const briefNotice = ref('')
const briefError = ref('')

async function runBrief() {
  briefNotice.value = ''
  briefError.value = ''
  try {
    const result = await generate.mutateAsync({ action: 'territory.brief' })
    if (result.status === 'cached') {
      briefNotice.value = 'Nothing has changed since the last brief.'
    } else if (result.status === 'cooldown') {
      const mins = Math.max(1, Math.ceil((result.retry_after_seconds ?? 60) / 60))
      briefNotice.value = `Just refreshed. You can regenerate in about ${mins} min.`
    } else if (result.status === 'insufficient_data') {
      briefNotice.value =
        result.message ?? 'Not enough territory activity to brief yet.'
    }
  } catch (e) {
    briefError.value = (e as Error).message
  }
}

watch(
  () => briefQuery.isSuccess.value,
  (ready) => {
    if (!ready) return
    const today = format(new Date(), 'yyyy-MM-dd')
    if (lastAutoBrief === today) return
    const generatedAt = briefQuery.brief.value?.generated_at
    const staleBrief =
      !generatedAt || isBefore(new Date(generatedAt), startOfDay(new Date()))
    if (!staleBrief) return
    // Claimed before the await, not after: a generation that fails must not
    // re-fire on the next navigation. Regenerate is one tap away.
    lastAutoBrief = today
    void runBrief()
  },
  { immediate: true },
)

/* ---- header -------------------------------------------------------------- */
const firstName = computed(() => session.displayName.split('@')[0].split(' ')[0])
const greeting = computed(() => {
  const h = new Date().getHours()
  if (h < 12) return 'Morning'
  if (h < 17) return 'Afternoon'
  return 'Evening'
})

const goalSub = computed(() => {
  const t = totals.value
  if (t.goalPct == null) return undefined
  return `${Math.round(t.goalPct)}% of ${money(t.goal)}`
})
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.16em] uppercase">
        {{ format(new Date(), 'EEEE, MMMM d') }}
      </p>
      <h1 class="u-display text-ink mt-1 text-3xl">
        {{ greeting }}, {{ firstName }}
      </h1>
      <FreshnessStamp class="mt-1" />
    </header>

    <AsyncState
      :loading="accountsQuery.isPending.value"
      :error="accountsQuery.error.value"
      :empty="!accountsQuery.isPending.value && rows.length === 0"
      empty-title="No accounts yet"
      empty-body="Your book is empty. If that seems wrong, ask your admin to check your rep assignment."
      :rows="4"
      @retry="accountsQuery.refetch()"
    >
      <!-- 1 · Territory Health -->
      <section aria-label="Territory health">
        <div class="border-line bg-line grid grid-cols-2 gap-px border md:grid-cols-4">
          <StatTile
            label="Revenue YTD"
            :value="money(totals.revenueYtd)"
            :sub="`${deltaLabel(totals.deltaPct)} vs last year (${money(totals.revenuePriorYtd)})`"
          />
          <StatTile
            label="Goal"
            :value="totals.goal > 0 ? money(totals.goal) : '—'"
            :sub="goalSub"
          />
          <StatTile label="Open Orders" :value="money(totals.openOrderValue)" />
          <StatTile
            label="Backorders"
            :value="money(totals.backlogAmount)"
            :tone="totals.backlogAmount > 0 ? 'alert' : 'default'"
          />
        </div>
      </section>

      <!-- 2 · The analyst's read, above the fold -->
      <SalesBriefCard
        class="mt-5"
        :brief="briefQuery.brief.value"
        :generating="generate.isPending.value"
        :notice="briefNotice"
        :error="briefError"
        @regenerate="runBrief"
      />

      <!-- 3 · Largest movers -->
      <div class="mt-5 grid gap-5 lg:grid-cols-2">
        <AppCard title="Largest movers" :padded="false">
          <div v-if="moverGroups.length === 0" class="p-4">
            <p class="text-muted text-[15px]">No year-over-year movement yet.</p>
          </div>
          <!-- template wrapper so v-else isn't sharing an element with v-for -->
          <template v-else>
            <section
              v-for="(group, i) in moverGroups"
              :key="group.key"
              :class="i > 0 ? 'border-line border-t' : ''"
            >
              <h3 class="u-label bg-canvas border-line border-b px-4 py-2">
                {{ group.label }}
              </h3>
              <ul class="divide-line divide-y">
                <li v-for="m in group.rows" :key="m.customer_key">
                  <RouterLink
                    :to="{ name: 'account', params: { customerKey: m.customer_key } }"
                    class="hover:bg-canvas flex items-center justify-between gap-3 px-4 py-3"
                  >
                    <span class="min-w-0">
                      <span class="text-ink block truncate text-[15px] font-semibold">
                        {{ m.customer_name || m.customer_key }}
                      </span>
                      <span class="text-muted block text-xs">
                        {{ money(m.revenue_ytd) }} YTD · was
                        {{ money(m.revenue_prior_ytd) }}
                      </span>
                    </span>
                    <!-- money(), not money().slice(1): the dollar sign came off
                         to save width, which left "+12,400" sitting in a column
                         of "$45,200" and reading like a unit-less count. -->
                    <span
                      class="shrink-0 text-[15px] font-bold tabular-nums"
                      :class="m.delta > 0 ? 'text-brand' : 'text-accent'"
                    >
                      {{ m.delta > 0 ? '+' : '−' }}{{ money(Math.abs(m.delta)) }}
                    </span>
                  </RouterLink>
                </li>
              </ul>
            </section>
          </template>
        </AppCard>

        <!-- 4 · Worth investigating — observations, never assignments. -->
        <AppCard title="Worth investigating" :padded="false">
          <div v-if="observations.length === 0" class="p-4">
            <p class="text-muted text-[15px]">
              Nothing stands out right now — no dormant accounts, sharp
              declines, or large backorder positions.
            </p>
          </div>
          <ul v-else class="divide-line divide-y">
            <li v-for="o in observations" :key="`${o.kind}-${o.customer_key}`">
              <RouterLink
                :to="{ name: 'account', params: { customerKey: o.customer_key } }"
                class="hover:bg-canvas block px-4 py-3"
              >
                <span class="text-ink block truncate text-[15px] font-semibold">
                  {{ o.customer_name }}
                </span>
                <span class="text-ink-2 block text-sm">{{ o.note }}</span>
              </RouterLink>
            </li>
          </ul>
        </AppCard>
      </div>

      <!-- 5 · Recent activity -->
      <AppCard
        class="mt-5"
        title="Recent activity"
        hint="Orders, last 14 days"
        :padded="false"
      >
        <AsyncState
          :loading="recentQuery.isPending.value"
          :error="recentQuery.error.value"
          :empty="!recentQuery.isPending.value && recent.length === 0"
          empty-title="No orders in the last two weeks"
          :rows="2"
          @retry="recentQuery.refetch()"
        >
          <ul class="divide-line divide-y">
            <li v-for="o in recent" :key="`${o.customer_key}-${o.order_id}`">
              <RouterLink
                :to="{ name: 'account', params: { customerKey: o.customer_key } }"
                class="hover:bg-canvas flex items-center justify-between gap-3 px-4 py-3"
              >
                <span class="min-w-0">
                  <span class="text-ink block truncate text-[15px] font-semibold">
                    {{ o.customer_name || o.customer_key }}
                  </span>
                  <span class="text-muted block text-xs">
                    Order {{ o.order_id }} · {{ daysAgo(o.order_date) }}
                    <template v-if="o.has_backlog"> · has backorder lines</template>
                  </span>
                </span>
                <span class="text-ink shrink-0 text-[15px] font-semibold tabular-nums">
                  {{ money(o.order_amount) }}
                </span>
              </RouterLink>
            </li>
          </ul>
        </AsyncState>
      </AppCard>
    </AsyncState>
  </div>
</template>
