<script setup lang="ts">
import { computed } from 'vue'
import { format } from 'date-fns'
import { useSessionStore } from '@/stores/session'
import { useNeedsAttention } from '@/composables/useRecommendations'
import { useAccountNames } from '@/composables/useAccounts'
import RecommendationCard from '@/components/RecommendationCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { daysUntilDue } from '@/lib/format'

const session = useSessionStore()
const { data, isPending, error, refetch } = useNeedsAttention()

const items = computed(() => data.value ?? [])
const keys = computed(() => items.value.map((r) => r.customer_key))
const { data: names } = useAccountNames(keys)

const overdue = computed(
  () =>
    items.value.filter((r) => {
      const d = daysUntilDue(r.due_date)
      return d != null && d < 0
    }).length,
)
const awaitingOutcome = computed(
  () => items.value.filter((r) => r.status === 'acted').length,
)

const firstName = computed(() => session.displayName.split(' ')[0])
</script>

<template>
  <div class="space-y-6">
    <header>
      <p class="text-sm text-zinc-500">
        {{ format(new Date(), 'EEEE, MMMM d') }}
      </p>
      <h1 class="text-2xl font-semibold tracking-tight text-zinc-900">
        Good morning, {{ firstName }}
      </h1>
    </header>

    <div class="grid grid-cols-3 gap-3">
      <StatTile label="To do" :value="items.length" />
      <StatTile
        label="Overdue"
        :value="overdue"
        :tone="overdue > 0 ? 'alert' : 'default'"
      />
      <StatTile label="Need outcome" :value="awaitingOutcome" />
    </div>

    <section class="space-y-3">
      <h2 class="text-sm font-semibold tracking-wide text-zinc-500 uppercase">
        Needs attention
      </h2>

      <AsyncState
        :loading="isPending"
        :error="error"
        :empty="items.length === 0"
        empty-title="You're all caught up"
        empty-body="Nothing needs attention right now. New recommendations land overnight."
        @retry="refetch()"
      >
        <div class="space-y-3">
          <RecommendationCard
            v-for="rec in items"
            :key="rec.id"
            :rec="rec"
            :account-name="names?.[rec.customer_key]"
          />
        </div>
      </AsyncState>
    </section>
  </div>
</template>
