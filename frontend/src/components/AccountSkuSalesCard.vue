<script setup lang="ts">
import { computed, ref, toRef, watch } from 'vue'
import { pivotSkuYears, useSkuSalesByAccount, type SkuPivotRow } from '@/composables/useIntel'
import { useAccount } from '@/composables/useAccounts'
import AppCollapsibleCard from '@/components/ui/AppCollapsibleCard.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import { cardHintState } from '@/components/ui/cardHint'
import { count, money } from '@/lib/format'
import type { ExportColumn } from '@/lib/xlsx'

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

/* ---- download ------------------------------------------------------------
   Every SKU in the list, not the 8-row preview: "Show all" only decides how
   much the phone draws, and a rep downloading wants the whole history. Same
   columns as the Sales by SKU page's "By account" sheet.
------------------------------------------------------------------------- */

/* The account's NAME for the sheet title — the page header's query
   (vue-query dedupes it). The key stands in until it arrives. */
const account = useAccount(toRef(props, 'customerKey'))
const accountName = computed(() => account.data.value?.customer_name || props.customerKey)
const accountLine = computed(() => {
  const id = account.data.value?.customer_id
  return id && id !== accountName.value
    ? `Account: ${id} — ${accountName.value}`
    : `Account: ${accountName.value}`
})

/* Product line only when the data carries it (null before 20261027090500). */
const hasProductLine = computed(() => pivoted.value.some((p) => p.product_code))
const exportColumns = computed<ExportColumn<SkuPivotRow>[]>(() => [
  { key: 'part_id', header: 'SKU', type: 'text' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  ...(hasProductLine.value
    ? [{ key: 'product_code', header: 'Product line' } as ExportColumn<SkuPivotRow>]
    : []),
  { key: 'chambering', header: 'Chambering' },
  { key: 'upc', header: 'UPC', type: 'text' },
  { key: 'qtyThisYear', header: `Units ${yearNow} to date`, type: 'number' },
  { key: 'revenueThisYear', header: `Revenue ${yearNow} to date`, type: 'money' },
  { key: 'qtyLastYear', header: `Units all of ${yearNow - 1}`, type: 'number' },
  { key: 'revenueLastYear', header: `Revenue all of ${yearNow - 1}`, type: 'money' },
  { key: 'lastInvoiceDate', header: 'Last invoice', type: 'date' },
])
const EXPORT_DESCRIPTION =
  `Invoiced units and revenue by SKU, top sellers first. ${yearNow} is year to ` +
  `date; ${yearNow - 1} is the whole calendar year, not the same period.`
const exportDetails = computed(() => [
  accountLine.value,
  'SKUs invoiced to this account in the last four years',
  !expanded.value &&
    pivoted.value.length > PREVIEW &&
    `All ${count(pivoted.value.length)} SKUs (the card previews the top ${PREVIEW})`,
])
</script>

<template>
  <AppCollapsibleCard ref="card" title="Sales by SKU" :hint="hint" :padded="false">
    <template #actions>
      <ExportMenu
        :rows="pivoted"
        :columns="exportColumns"
        :title="`Sales by SKU — ${accountName}`"
        :filename="`sku-sales-${customerKey}`"
        :description="EXPORT_DESCRIPTION"
        :details="exportDetails"
        sheet-name="Sales by SKU"
      />
    </template>
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
