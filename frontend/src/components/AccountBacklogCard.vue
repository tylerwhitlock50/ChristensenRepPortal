<script setup lang="ts">
import { computed, ref, toRef, watch } from 'vue'
import { useAccountBacklog, type BacklogSkuRow } from '@/composables/useIntel'
import { useAccountSummary } from '@/composables/useAccountMetrics'
import { useAccount } from '@/composables/useAccounts'
import AppCollapsibleCard from '@/components/ui/AppCollapsibleCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import { cardHintState } from '@/components/ui/cardHint'
import { count, money, shortDate } from '@/lib/format'
import type { ExportColumn } from '@/lib/xlsx'

/**
 * What this account is still owed, by SKU — the "when is my stuff coming"
 * conversation, answered before the buyer asks it.
 *
 * Collapsed on arrival, but the dollars owed stay in the header: that number
 * is the whole reason to open it, and "None" says the conversation is moot
 * without costing a tap.
 *
 * The rows are fetched on first open (or already sit in the cache, when the
 * Before you call card read them for its promise dates). Until then the
 * header reads the same dollars and units from v_account_summary, which the
 * page has loaded anyway: open_order_value is the sum this view rolls up.
 */
const props = defineProps<{ customerKey: string }>()

const card = ref<InstanceType<typeof AppCollapsibleCard> | null>(null)
/* Latched on first open, re-armed per account — see AccountSkuSalesCard. */
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
/* An empty key keeps useAccountBacklog disabled. */
const key = computed(() => (wanted.value ? props.customerKey : ''))

const query = useAccountBacklog(key)
const summary = useAccountSummary(computed(() => props.customerKey))
const rows = computed(() => query.data.value ?? [])
const total = computed(() => rows.value.reduce((a, r) => a + r.backlog_amount, 0))

const summaryHint = computed(() => {
  const s = summary.data.value
  if (!s) return undefined
  if (s.open_order_count <= 0) return 'None'
  return `${count(Math.round(s.backlog_qty))} units · ${money(s.open_order_value)}`
})

const hint = computed(() =>
  !wanted.value
    ? summaryHint.value
    : (cardHintState(query, rows.value.length) ??
      `${rows.value.length} · ${money(total.value)}`),
)

/* ---- download ------------------------------------------------------------
   The list as shown, oldest promise first. Same columns as the Backlog by
   SKU page's sheet, minus the account and rep: every row is this account.
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
const hasProductLine = computed(() => rows.value.some((r) => r.product_code))
const exportColumns = computed<ExportColumn<BacklogSkuRow>[]>(() => [
  { key: 'part_id', header: 'SKU', type: 'text' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  ...(hasProductLine.value
    ? [{ key: 'product_code', header: 'Product line' } as ExportColumn<BacklogSkuRow>]
    : []),
  { key: 'chambering', header: 'Chambering' },
  { key: 'backlog_qty', header: 'Backlog qty', type: 'number' },
  { key: 'backlog_amount', header: 'Backlog value', type: 'money' },
  { key: 'earliest_promise_date', header: 'Earliest promise', type: 'date' },
  { key: 'earliest_desired_ship_date', header: 'Est. production date', type: 'date' },
  { key: 'open_line_count', header: 'Open lines', type: 'integer' },
  { key: 'latest_order_date', header: 'Latest order', type: 'date' },
])
const EXPORT_DESCRIPTION =
  "Every open order line's unshipped quantity and value (Firmed and Hold included), " +
  'by SKU: what this account is still owed, not yet shipped or invoiced.'
const exportDetails = computed(() => [accountLine.value])
</script>

<template>
  <AppCollapsibleCard ref="card" title="On backorder" :hint="hint" :padded="false">
    <template #actions>
      <ExportMenu
        :rows="rows"
        :columns="exportColumns"
        :title="`On backorder — ${accountName}`"
        :filename="`backlog-${customerKey}`"
        :description="EXPORT_DESCRIPTION"
        :details="exportDetails"
        sheet-name="On backorder"
      />
    </template>
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :has-data="query.data.value !== undefined"
      :updated-at="query.dataUpdatedAt.value"
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
  </AppCollapsibleCard>
</template>
