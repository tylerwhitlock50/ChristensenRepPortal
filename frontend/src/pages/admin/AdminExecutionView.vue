<script setup lang="ts">
import { computed } from 'vue'
import { useCoverage } from '@/composables/useAdmin'
import CoverageGrid from '@/components/CoverageGrid.vue'
import RepExecutionGrid from '@/components/RepExecutionGrid.vue'
import RepGoalGrid from '@/components/RepGoalGrid.vue'
import StatTile from '@/components/ui/StatTile.vue'

/**
 * The headline numbers stay here; the tables are RepExecutionGrid,
 * RepGoalGrid and CoverageGrid, which bring their own AppCard, AsyncState,
 * sorting, filtering and CSV export (PRD acceptance criterion #4).
 *
 * This page calls useCoverage() and so do the coverage grids — TanStack Query
 * dedupes on the key, so that is one request, not three. RepGoalGrid runs its
 * own query against the goal views (023) and shares nothing with them.
 */
const coverage = useCoverage()

const rows = computed(() => coverage.data.value ?? [])
const contacted = computed(() => rows.value.filter((r) => r.contacted_last_30d).length)
const coveragePct = computed(() =>
  rows.value.length ? Math.round((contacted.value / rows.value.length) * 100) : 0,
)
const untouched = computed(() => rows.value.filter((r) => !r.contacted_last_30d))

/**
 * A failed coverage query must not render as "0% coverage, 0 untouched" — that
 * reads like good news. Show dashes and say why; the grids below carry the
 * retry button.
 */
const tilesReady = computed(() => !coverage.error.value && !coverage.isPending.value)
const dash = '—'
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Execution
      </p>
      <h1 class="u-display mt-1 text-4xl">Who's working the list</h1>
      <p class="text-muted mt-2 text-[15px]">
        Coverage and follow-through across the field, rolling 30 days.
      </p>
    </header>

    <div class="bg-line border-line grid grid-cols-3 gap-px border">
      <StatTile
        label="Coverage"
        :value="tilesReady ? `${coveragePct}%` : dash"
        sub="contacted in 30d"
      />
      <StatTile label="Accounts" :value="tilesReady ? rows.length : dash" />
      <StatTile
        label="Untouched"
        :value="tilesReady ? untouched.length : dash"
        :tone="tilesReady && untouched.length > 0 ? 'alert' : 'default'"
      />
    </div>

    <p v-if="coverage.error.value" class="text-muted text-sm">
      Coverage numbers are unavailable — see the error below.
    </p>

    <RepExecutionGrid />
    <RepGoalGrid />
    <CoverageGrid />
  </div>
</template>
