<script setup lang="ts">
import { computed } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import { QC_RESULT_LABELS } from '@/types/domain'
import { moneyCents, shortDate } from '@/lib/format'
import type { QcResultRow } from '@/composables/useOrders'

/**
 * The ERP-vs-portal findings, in plain language. Shown identically to the
 * rep, the entry queue, and the admin — everyone reads the same facts, only
 * the actions around this card differ by role.
 *
 * run_order_qc() compares by part, with a quantity-weighted price on each
 * side. A hand-priced order can carry one part on two lines (10 paid, 1
 * free), and then the portal's price is an average that is on no line, so
 * it is called one. `lines` is the order's lines, for that count.
 */
const props = defineProps<{
  qc: QcResultRow[]
  checkedAt?: string | null
  lines?: readonly { part_id: string }[]
}>()

const linesPerPart = computed(() => {
  const n = new Map<string, number>()
  for (const l of props.lines ?? []) n.set(l.part_id, (n.get(l.part_id) ?? 0) + 1)
  return n
})

function line(row: QcResultRow): string {
  switch (row.result) {
    case 'price_mismatch': {
      const onLines = row.part_id ? (linesPerPart.value.get(row.part_id) ?? 0) : 0
      return onLines > 1
        ? `The average portal price over its ${onLines} lines is ${moneyCents(row.app_unit_price)}, the ERP has ${moneyCents(row.erp_unit_price)}.`
        : `Portal has ${moneyCents(row.app_unit_price)}, the ERP has ${moneyCents(row.erp_unit_price)}.`
    }
    case 'qty_mismatch':
      return `Portal has ${row.app_qty ?? '—'} units, the ERP has ${row.erp_qty ?? '—'}.`
    default:
      return row.detail ?? ''
  }
}
</script>

<template>
  <AppCard
    v-if="qc.length"
    title="Discrepancies vs ERP"
    :hint="checkedAt ? `checked ${shortDate(checkedAt)}` : undefined"
  >
    <ul class="space-y-3">
      <li
        v-for="row in qc"
        :key="row.id"
        class="border-line border-l-accent border border-l-[3px] p-3"
      >
        <p class="text-ink text-[15px] font-semibold">
          <template v-if="row.part_id">{{ row.part_id }} — </template>
          {{ QC_RESULT_LABELS[row.result] }}
        </p>
        <p class="text-ink-2 mt-0.5 text-[14px] leading-relaxed">{{ line(row) }}</p>
      </li>
    </ul>
  </AppCard>
</template>
