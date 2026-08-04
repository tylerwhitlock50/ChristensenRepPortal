<script setup lang="ts">
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import {
  pivotSkuYears,
  useSkuSalesByAccount,
  useTerritorySkuSales,
  type SkuPivotRow,
} from '@/composables/useIntel'
import { useTerritoryAccounts } from '@/composables/useOverview'
import DataGrid from '@/components/DataGrid.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { deltaLabel, percentChange } from '@/composables/useAccountMetrics'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import { count, money, shortDate } from '@/lib/format'

/**
 * Sales by SKU — what was bought, by SKU, this year vs history. Two modes:
 * "My territory" (the whole book rolled up per SKU) and "By account"
 * (one account's SKU history, picker fed from the same territory rows the
 * Overview already cached).
 */
const mode = ref<'territory' | 'account'>('territory')
const accountKey = ref('')
const search = ref('')

const territory = useTerritorySkuSales()
const account = useSkuSalesByAccount(accountKey)
const picker = useTerritoryAccounts()

const active = computed(() => (mode.value === 'territory' ? territory : account))
const yearNow = new Date().getFullYear()

const pivoted = computed(() =>
  mode.value === 'account' && !accountKey.value
    ? []
    : pivotSkuYears(active.value.data.value ?? [], yearNow),
)

const totals = computed(() => {
  const rows = pivoted.value
  const rev = rows.reduce((a, r) => a + r.revenueThisYear, 0)
  const revLY = rows.reduce((a, r) => a + r.revenueLastYear, 0)
  const qty = rows.reduce((a, r) => a + r.qtyThisYear, 0)
  return { rev, revLY, qty, skus: rows.filter((r) => r.qtyThisYear > 0).length }
})

const accounts = computed(() =>
  [...(picker.data.value ?? [])].sort((a, b) =>
    (a.customer_name ?? a.customer_key).localeCompare(
      b.customer_name ?? b.customer_key,
    ),
  ),
)

const columns = computed<ColumnDef<SkuPivotRow, any>[]>(() => [
  { id: 'part_id', header: 'SKU', accessorKey: 'part_id' },
  { id: 'part_description', header: 'Description', accessorKey: 'part_description' },
  { id: 'product_family', header: 'Family', accessorKey: 'product_family' },
  { id: 'chambering', header: 'Chambering', accessorKey: 'chambering' },
  { id: 'qtyThisYear', header: `Qty ${yearNow}`, accessorKey: 'qtyThisYear' },
  { id: 'revenueThisYear', header: `Rev ${yearNow}`, accessorKey: 'revenueThisYear' },
  { id: 'qtyLastYear', header: `Qty ${yearNow - 1}`, accessorKey: 'qtyLastYear' },
  { id: 'revenueLastYear', header: `Rev ${yearNow - 1}`, accessorKey: 'revenueLastYear' },
  { id: 'lastInvoiceDate', header: 'Last invoice', accessorKey: 'lastInvoiceDate' },
])

/** What's on screen is what exports — DataGrid emits its visible rows. */
const visible = ref<SkuPivotRow[]>([])
const csvColumns: CsvColumn<SkuPivotRow>[] = [
  { key: 'part_id', header: 'SKU' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  { key: 'chambering', header: 'Chambering' },
  { key: 'upc', header: 'UPC' },
  { key: 'qtyThisYear', header: `Qty ${yearNow}` },
  { key: 'revenueThisYear', header: `Revenue ${yearNow}` },
  { key: 'qtyLastYear', header: `Qty ${yearNow - 1}` },
  { key: 'revenueLastYear', header: `Revenue ${yearNow - 1}` },
  { key: 'lastInvoiceDate', header: 'Last invoice' },
]
function onExport() {
  const prefix =
    mode.value === 'territory' ? 'sku-sales-territory' : `sku-sales-${accountKey.value}`
  exportCsv(prefix, visible.value, csvColumns)
}
</script>

<template>
  <div class="space-y-4">
    <!-- Mode + account picker -->
    <div class="flex flex-wrap items-center gap-2">
      <div class="border-line flex border" role="group" aria-label="Scope">
        <button
          type="button"
          class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
          :class="mode === 'territory' ? 'bg-ink text-canvas' : 'text-muted'"
          @click="mode = 'territory'"
        >
          My territory
        </button>
        <button
          type="button"
          class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
          :class="mode === 'account' ? 'bg-ink text-canvas' : 'text-muted'"
          @click="mode = 'account'"
        >
          By account
        </button>
      </div>

      <label v-if="mode === 'account'" class="min-w-0 flex-1 sm:max-w-sm">
        <span class="sr-only">Account</span>
        <select v-model="accountKey" class="field">
          <option value="">Choose an account…</option>
          <option v-for="a in accounts" :key="a.customer_key" :value="a.customer_key">
            {{ a.customer_name || a.customer_key }}
          </option>
        </select>
      </label>

      <AppButton
        variant="ghost"
        class="ml-auto"
        :disabled="visible.length === 0"
        @click="onExport"
      >
        Export CSV
      </AppButton>
    </div>

    <AsyncState
      :loading="active.isPending.value && !(mode === 'account' && !accountKey)"
      :error="active.error.value"
      :rows="4"
      @retry="active.refetch()"
    >
      <p v-if="mode === 'account' && !accountKey" class="text-muted text-[15px]">
        Pick an account to see what they bought, by SKU, this year and the
        three before it.
      </p>

      <template v-else>
        <!-- So-what tiles first; the grid is the detail. -->
        <div class="border-line bg-line grid grid-cols-2 gap-px border md:grid-cols-4">
          <StatTile
            :label="`Revenue ${yearNow}`"
            :value="money(totals.rev)"
            :sub="`${deltaLabel(percentChange(totals.rev, totals.revLY))} vs ${yearNow - 1} (${money(totals.revLY)})`"
          />
          <StatTile :label="`Units ${yearNow}`" :value="count(totals.qty)" />
          <StatTile label="SKUs bought" :value="count(totals.skus)" :sub="`in ${yearNow}`" />
          <StatTile label="SKUs all years" :value="count(pivoted.length)" />
        </div>

        <AppCard :padded="false" class="mt-4">
          <DataGrid
            :columns="columns"
            :data="pivoted"
            :initial-sorting="[{ id: 'revenueThisYear', desc: true }]"
            searchable
            search-placeholder="Filter by SKU, description, family, chambering…"
            v-model:global-filter="search"
            :get-row-id="(r: SkuPivotRow) => r.part_key"
            class="p-3"
            @rows-change="visible = $event"
          >
            <template #cell-revenueThisYear="{ row }">
              <span class="tabular-nums">{{ money(row.revenueThisYear) }}</span>
            </template>
            <template #cell-revenueLastYear="{ row }">
              <span class="tabular-nums">{{ money(row.revenueLastYear) }}</span>
            </template>
            <template #cell-qtyThisYear="{ row }">
              <span class="tabular-nums">{{ count(row.qtyThisYear) }}</span>
            </template>
            <template #cell-qtyLastYear="{ row }">
              <span class="tabular-nums">{{ count(row.qtyLastYear) }}</span>
            </template>
            <template #cell-lastInvoiceDate="{ row }">
              {{ shortDate(row.lastInvoiceDate) }}
            </template>
            <template #card="{ row }">
              <div class="px-1">
                <p class="text-ink text-[15px] font-semibold">
                  {{ row.part_id }} · {{ row.part_description }}
                </p>
                <p class="text-muted mt-0.5 text-xs">
                  {{ row.product_family }} · {{ row.chambering }}
                </p>
                <p class="text-ink-2 mt-1 text-sm tabular-nums">
                  {{ yearNow }}: {{ count(row.qtyThisYear) }} units,
                  {{ money(row.revenueThisYear) }} · {{ yearNow - 1 }}:
                  {{ count(row.qtyLastYear) }} units,
                  {{ money(row.revenueLastYear) }}
                </p>
              </div>
            </template>
          </DataGrid>
        </AppCard>
      </template>
    </AsyncState>
  </div>
</template>
