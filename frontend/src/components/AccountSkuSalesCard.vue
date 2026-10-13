<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { pivotSkuYears, useSkuSalesByAccount } from '@/composables/useIntel'
import AppCollapsibleCard from '@/components/ui/AppCollapsibleCard.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { cardHintState } from '@/components/ui/cardHint'
import { count, money } from '@/lib/format'

/**
 * What this account buys, by SKU — this year against last, top sellers
 * first. Collapsed on arrival like the rest of the history below the fold;
 * once open, the preview keeps it scannable on a phone and "Show all"
 * expands in place (no navigation — the rep is standing in the store).
 *
 * The year pair used to live in the header hint, but a collapsed card wants
 * to say how much there is to read; every row spells out both years anyway.
 *
 * Nothing is fetched until the card is first opened: a big dealer's SKU
 * history is two or more pages (LIPSEYS: 1,692 rows), and most account opens
 * never look. Until then the query runs against an empty key, which keeps it
 * disabled (useSkuSalesByAccount only runs with a key), and the hint says
 * what the card holds instead of counting it.
 */
const props = defineProps<{ customerKey: string }>()

const card = ref<InstanceType<typeof AppCollapsibleCard> | null>(null)
/* Latched: closing the card keeps the rows (and the count) it fetched.
   Re-armed per account, since the router reuses this component. */
const wanted = ref(false)
watch(
  () => card.value?.isOpen,
  (open) => {
    if (open) wanted.value = true
  },
)
watch(
  () => props.customerKey,
  () => {
    wanted.value = !!card.value?.isOpen
  },
)
const key = computed(() => (wanted.value ? props.customerKey : ''))

const query = useSkuSalesByAccount(key)
const yearNow = new Date().getFullYear()
const pivoted = computed(() => pivotSkuYears(query.data.value ?? [], yearNow))

const PREVIEW = 8
const expanded = ref(false)
const shown = computed(() =>
  expanded.value ? pivoted.value : pivoted.value.slice(0, PREVIEW),
)

const hint = computed(() =>
  !wanted.value
    ? 'This year vs last'
    : (cardHintState(query, pivoted.value.length) ?? `${pivoted.value.length} SKUs`),
)
</script>

<template>
  <AppCollapsibleCard ref="card" title="Sales by SKU" :hint="hint" :padded="false">
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :has-data="query.data.value !== undefined"
      :updated-at="query.dataUpdatedAt.value"
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
  </AppCollapsibleCard>
</template>
