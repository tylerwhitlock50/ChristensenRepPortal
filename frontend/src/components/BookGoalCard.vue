<script setup lang="ts">
import { computed } from 'vue'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import { currentGoalYear, useGoalRollup } from '@/composables/useAccountGoals'
import { money } from '@/lib/format'

/**
 * How the whole book is tracking against the goals the rep set — the one
 * number a rep would otherwise open twelve account pages to add up.
 *
 * Totals are summed in Postgres (public.v_my_goal_rollup), scoped by RLS, so
 * a rep sees their book and an admin sees the company.
 *
 * Renders NOTHING until at least one goal exists. Today is the screen a rep
 * opens to be told what to do; an empty "0 of $0" strip on it would be a
 * standing advertisement for a feature they have not opted into. Discovery
 * lives on the account page, next to the revenue the goal is about.
 */
const year = currentGoalYear()
const query = useGoalRollup(year)
const rollup = computed(() => query.data.value ?? null)

const show = computed(() => (rollup.value?.accounts_with_goal ?? 0) > 0)

const attainment = computed(() => Math.round(rollup.value?.attainment_pct ?? 0))
const expected = computed(() => Math.round(rollup.value?.expected_pct ?? 0))

const behindPoints = computed(() => attainment.value - expected.value)
const isBehind = computed(() => behindPoints.value < 0)

const paceLine = computed(() => {
  if (behindPoints.value === 0) return 'on pace'
  return isBehind.value
    ? `${Math.abs(behindPoints.value)}% behind pace`
    : `${behindPoints.value}% ahead of pace`
})
</script>

<template>
  <section v-if="show && rollup" class="border-line bg-surface border p-4">
    <div class="flex items-baseline justify-between gap-3">
      <h2 class="u-label text-ink">Book goal · {{ year }}</h2>
      <RouterLink
        v-if="rollup.accounts_behind > 0"
        :to="{ name: 'accounts', query: { goal: 'behind' } }"
        class="tap-target text-ink-2 inline-flex shrink-0 items-center px-1 text-[13px] font-semibold underline underline-offset-2"
      >
        {{ rollup.accounts_behind }} behind
      </RouterLink>
    </div>

    <p class="u-display text-ink mt-1 text-3xl tabular-nums">
      {{ money(rollup.revenue_total) }}
      <span class="text-muted text-xl">of {{ money(rollup.target_total) }}</span>
    </p>

    <GoalProgressBar
      class="mt-2"
      :attainment-pct="rollup.attainment_pct ?? 0"
      :expected-pct="rollup.expected_pct ?? 0"
      :on-track="!isBehind"
      :label="`Book goal progress for ${year}`"
    />

    <p class="text-ink-2 mt-2 text-[15px]">
      {{ attainment }}% of goal
      <span :class="isBehind ? 'text-accent font-semibold' : 'text-muted'">
        · {{ paceLine }}
      </span>
      <span class="text-muted">
        ·
        {{ rollup.accounts_with_goal }}
        {{ rollup.accounts_with_goal === 1 ? 'account' : 'accounts' }}
      </span>
    </p>
  </section>
</template>
