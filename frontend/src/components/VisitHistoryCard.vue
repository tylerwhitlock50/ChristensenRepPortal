<script setup lang="ts">
/**
 * Read-only history of structured surveys for one account — the "what did we
 * find last time?" answer a rep wants before walking in the door.
 *
 * Deliberately dense: type, date, inventory and the three 1–5 scales on one
 * row each, so a season of visits fits on a phone screen without a tap.
 */
import { computed } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { useAccountVisits, type Visit } from '@/composables/useVisits'
import {
  competitorPromoLabel,
  inventoryLevelLabel,
  storeTrafficLabel,
  visitTypeLabel,
} from '@/lib/visitSchema'
import { daysAgo, shortDate } from '@/lib/format'

const props = withDefaults(
  defineProps<{
    customerKey: string
    /** How many surveys to pull. Read once, on mount. */
    limit?: number
  }>(),
  { limit: 20 },
)

const key = computed(() => props.customerKey)
const { data, isPending, error, refetch } = useAccountVisits(key, {
  limit: props.limit,
})

const visits = computed<Visit[]>(() => data.value ?? [])

/** Mirrors AppBadge's `tone` prop — those four fills are the whole vocabulary. */
type Tone = 'late' | 'high' | 'good' | 'neutral'

/** Empty shelves are the thing to notice from across the room. */
function inventoryTone(level: string | null): Tone {
  switch (level) {
    case 'empty':
      return 'late'
    case 'low':
      return 'high'
    case 'good':
      return 'good'
    case 'overstock':
      return 'neutral'
    default:
      return 'neutral'
  }
}

interface Rating {
  label: string
  value: number
}

function ratings(visit: Visit): Rating[] {
  const out: Rating[] = []
  if (visit.store_condition != null)
    out.push({ label: 'Condition', value: visit.store_condition })
  if (visit.display_quality != null)
    out.push({ label: 'Display', value: visit.display_quality })
  if (visit.staff_knowledge != null)
    out.push({ label: 'Staff', value: visit.staff_knowledge })
  return out
}
</script>

<template>
  <AppCard
    title="Visit surveys"
    :hint="visits.length ? `${visits.length} logged` : undefined"
  >
    <AsyncState
      :loading="isPending"
      :error="error"
      :empty="visits.length === 0"
      empty-title="No surveys yet"
      empty-body="Log one on your next stop — it takes under a minute."
      @retry="refetch()"
    >
      <ul class="divide-y divide-line">
        <li
          v-for="visit in visits"
          :key="visit.id"
          class="py-3 first:pt-0 last:pb-0"
        >
          <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span class="text-sm font-semibold text-ink">
              {{ visitTypeLabel(visit.visit_type) }}
            </span>
            <span class="text-sm text-muted">
              {{ shortDate(visit.visit_date) }} · {{ daysAgo(visit.visit_date) }}
            </span>
            <AppBadge
              v-if="visit.inventory_level"
              :tone="inventoryTone(visit.inventory_level)"
            >
              {{ inventoryLevelLabel(visit.inventory_level) }} stock
            </AppBadge>
          </div>

          <div
            v-if="
              ratings(visit).length ||
              visit.store_traffic ||
              visit.competitor_promos
            "
            class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-ink-2"
          >
            <span v-for="r in ratings(visit)" :key="r.label">
              {{ r.label }}
              <span class="font-semibold text-ink">{{ r.value }}</span>
              <span class="text-muted">/5</span>
            </span>
            <span v-if="visit.store_traffic">
              Traffic
              <span class="font-semibold text-ink">
                {{ storeTrafficLabel(visit.store_traffic) }}
              </span>
            </span>
            <span v-if="visit.competitor_promos">
              Promos
              <span class="font-semibold text-ink">
                {{ competitorPromoLabel(visit.competitor_promos) }}
              </span>
            </span>
          </div>

          <p
            v-if="visit.competition_seen.length"
            class="mt-1 text-xs text-ink-2"
          >
            Saw: {{ visit.competition_seen.join(', ') }}
          </p>

          <p v-if="visit.comments" class="mt-1 text-sm text-ink-2">
            {{ visit.comments }}
          </p>
        </li>
      </ul>
    </AsyncState>
  </AppCard>
</template>
