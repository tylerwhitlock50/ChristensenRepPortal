<script setup lang="ts">
import { computed } from 'vue'
import { useAccountBacklog } from '@/composables/useIntel'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count, money, shortDate } from '@/lib/format'

/**
 * What this account is still owed, by SKU — the "when is my stuff coming"
 * conversation, answered before the buyer asks it.
 */
const props = defineProps<{ customerKey: string }>()
const key = computed(() => props.customerKey)

const query = useAccountBacklog(key)
const rows = computed(() => query.data.value ?? [])
const total = computed(() => rows.value.reduce((a, r) => a + r.backlog_amount, 0))
</script>

<template>
  <AppCard
    title="On backorder"
    :hint="rows.length ? money(total) : undefined"
    :padded="false"
  >
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && rows.length === 0"
      empty-title="Nothing on backorder"
      empty-body="Every open line for this account has shipped or been allocated."
      :rows="2"
      @retry="query.refetch()"
    >
      <ul class="divide-line divide-y">
        <li v-for="r in rows" :key="r.part_key" class="px-4 py-2.5">
          <p class="text-ink text-[15px] font-semibold">
            {{ r.part_id }}
            <span class="text-ink-2 font-normal"> · {{ r.part_description }}</span>
          </p>
          <p class="text-muted mt-0.5 text-xs tabular-nums">
            {{ count(r.backlog_qty) }} units · {{ money(r.backlog_amount) }}
            <template v-if="r.earliest_promise_date">
              · promised {{ shortDate(r.earliest_promise_date) }}
            </template>
          </p>
        </li>
      </ul>
    </AsyncState>
  </AppCard>
</template>
