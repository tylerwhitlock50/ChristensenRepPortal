<script setup lang="ts">
import AppCard from '@/components/ui/AppCard.vue'
import { QC_RESULT_LABELS } from '@/types/domain'
import { money, shortDate } from '@/lib/format'
import type { QcResultRow } from '@/composables/useOrders'

/**
 * The ERP-vs-portal findings, in plain language. Shown identically to the
 * rep, the entry queue, and the admin — everyone reads the same facts, only
 * the actions around this card differ by role.
 */
defineProps<{ qc: QcResultRow[]; checkedAt?: string | null }>()

function line(row: QcResultRow): string {
  switch (row.result) {
    case 'price_mismatch':
      return `Portal has ${money(row.app_unit_price)}, the ERP has ${money(row.erp_unit_price)}.`
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
