<script setup lang="ts">
import { computed, ref } from 'vue'
import { pivotSkuYears, useSkuSalesByAccount } from '@/composables/useIntel'
import AppCard from '@/components/ui/AppCard.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count, money } from '@/lib/format'

/**
 * What this account buys, by SKU — this year against last, top sellers
 * first. The preview keeps the page scannable on a phone; "Show all"
 * expands in place (no navigation — the rep is standing in the store).
 */
const props = defineProps<{ customerKey: string }>()
const key = computed(() => props.customerKey)

const query = useSkuSalesByAccount(key)
const yearNow = new Date().getFullYear()
const pivoted = computed(() => pivotSkuYears(query.data.value ?? [], yearNow))

const PREVIEW = 8
const expanded = ref(false)
const shown = computed(() =>
  expanded.value ? pivoted.value : pivoted.value.slice(0, PREVIEW),
)
</script>

<template>
  <AppCard
    title="Sales by SKU"
    :hint="`${yearNow} vs ${yearNow - 1}`"
    :padded="false"
  >
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && pivoted.length === 0"
      empty-title="No SKU history"
      empty-body="Nothing invoiced to this account in the last four years."
      :rows="2"
      @retry="query.refetch()"
    >
      <ul class="divide-line divide-y">
        <li v-for="p in shown" :key="p.part_key" class="px-4 py-2.5">
          <p class="text-ink text-[15px] font-semibold">
            {{ p.part_id }}
            <span class="text-ink-2 font-normal"> · {{ p.part_description }}</span>
          </p>
          <p class="text-muted mt-0.5 text-xs tabular-nums">
            {{ yearNow }}: {{ count(p.qtyThisYear) }} units,
            {{ money(p.revenueThisYear) }}
            · {{ yearNow - 1 }}: {{ count(p.qtyLastYear) }} units,
            {{ money(p.revenueLastYear) }}
          </p>
        </li>
      </ul>
      <div v-if="pivoted.length > PREVIEW" class="border-line border-t p-3">
        <AppButton variant="ghost" block @click="expanded = !expanded">
          {{ expanded ? 'Show fewer' : `Show all ${pivoted.length} SKUs` }}
        </AppButton>
      </div>
    </AsyncState>
  </AppCard>
</template>
