<script setup lang="ts">
/**
 * "How are my reps doing" on a principal's Overview, in five rows: the reps
 * carrying the most this year, each with how they compare with last year
 * and when they last opened the portal. The whole story is one tap away on
 * the Agency tab.
 *
 * Same queries (and query keys) as the Agency page, so opening the tab
 * after the Overview costs nothing.
 */
import { computed } from 'vue'
import {
  activeWithin,
  buildRepLines,
  useAgencyActivity,
  useAgencyRepPerformance,
  type AgencyRepLine,
} from '@/composables/useAgency'
import { yoyPct } from '@/composables/useAdminReports'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { daysAgo, money } from '@/lib/format'

const SHOWN = 5

// '' = the principal's own agency: their book, RLS-scoped.
const perf = useAgencyRepPerformance('')
const activity = useAgencyActivity('')

const lines = computed(() => buildRepLines(perf.data.value ?? [], activity.data.value ?? []))
/** Rep codes with accounts in the agency. Login-only rows (the principal's
 *  own, a rep with no accounts yet) have no book to rank. */
const reps = computed(() =>
  lines.value.filter((l) => l.id.startsWith('rep:') && l.sales_rep_key),
)
const top = computed(() => reps.value.slice(0, SHOWN))

const quiet = computed(
  () => reps.value.filter((l) => l.portal && !l.is_principal && !activeWithin(l.portal, 7)).length,
)

function yoyLabel(row: AgencyRepLine): string {
  const pct = yoyPct(row.revenue_ytd, row.revenue_prior_ytd)
  if (pct == null) return row.revenue_ytd > 0 ? 'new this year' : 'nothing yet'
  const rounded = Math.round(pct)
  if (rounded === 0) return 'flat vs last year'
  return `${rounded > 0 ? '+' : '−'}${Math.abs(rounded)}% vs last year`
}

function yoyTone(row: AgencyRepLine): string {
  const pct = yoyPct(row.revenue_ytd, row.revenue_prior_ytd)
  if (pct == null) return 'text-muted'
  if (pct <= -10) return 'text-danger'
  if (pct >= 10) return 'text-brand'
  return 'text-muted'
}

function lastActive(row: AgencyRepLine): string {
  if (!row.portal) return 'no portal login'
  return `active ${daysAgo(row.portal.last_login_at)}`
}
</script>

<template>
  <AppCard :padded="false">
    <template #header>
      <div>
        <h2 class="u-label text-ink">Your reps</h2>
        <p class="text-muted mt-1 text-[13px]">
          {{ reps.length }} {{ reps.length === 1 ? 'rep' : 'reps' }} in your agency<template
            v-if="quiet"
          > · {{ quiet }} not on the portal this week</template>
        </p>
      </div>
      <RouterLink
        :to="{ name: 'agency' }"
        class="tap-target font-label text-ink flex shrink-0 items-center text-[13px] font-semibold tracking-[0.12em] whitespace-nowrap uppercase underline-offset-2 hover:underline"
      >
        See all →
      </RouterLink>
    </template>

    <div :class="top.length ? '' : 'p-4'">
      <AsyncState
        :loading="perf.isPending.value"
        :error="perf.error.value"
        :has-data="perf.data.value !== undefined"
        :updated-at="perf.dataUpdatedAt.value"
        :empty="top.length === 0"
        empty-title="No reps with accounts yet"
        empty-body="Reps appear here once the ERP assigns them accounts in your agency."
        :rows="2"
        @retry="perf.refetch()"
      >
        <ul class="divide-line divide-y">
          <li v-for="r in top" :key="r.id">
            <RouterLink
              :to="{ name: 'agency' }"
              class="hover:bg-canvas flex items-center justify-between gap-3 px-4 py-3"
            >
              <span class="min-w-0">
                <span class="text-ink block truncate text-[15px] font-semibold">{{ r.name }}</span>
                <span class="text-muted block text-xs">
                  <span :class="yoyTone(r)">{{ yoyLabel(r) }}</span> · {{ lastActive(r) }}
                </span>
              </span>
              <span class="text-ink shrink-0 text-[15px] font-bold tabular-nums">
                {{ money(r.revenue_ytd) }}
              </span>
            </RouterLink>
          </li>
        </ul>
      </AsyncState>
    </div>
  </AppCard>
</template>
