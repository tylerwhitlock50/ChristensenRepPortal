<script setup lang="ts">
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import {
  rollupBy,
  useGlobalProductSales,
  type GlobalSkuRow,
} from '@/composables/useIntel'
import DataGrid from '@/components/DataGrid.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import { count, money } from '@/lib/format'

/**
 * Global intel — company-wide best sellers, top chamberings, family mix.
 * Aggregates only, by design and by construction: the definer RPC (021)
 * returns part-grain sums plus an account COUNT and nothing account-shaped.
 */
const months = ref(12)
const search = ref('')
const query = useGlobalProductSales(months)
const rows = computed(() => query.data.value ?? [])

const chamberings = computed(() => rollupBy(rows.value, 'chambering').slice(0, 10))
const families = computed(() => rollupBy(rows.value, 'product_family').slice(0, 10))

const totals = computed(() => ({
  revenue: rows.value.reduce((a, r) => a + r.revenue, 0),
  qty: rows.value.reduce((a, r) => a + r.qty, 0),
}))

const columns: ColumnDef<GlobalSkuRow, any>[] = [
  { id: 'part_id', header: 'SKU', accessorKey: 'part_id' },
  { id: 'part_description', header: 'Description', accessorKey: 'part_description' },
  { id: 'product_family', header: 'Family', accessorKey: 'product_family' },
  { id: 'chambering', header: 'Chambering', accessorKey: 'chambering' },
  { id: 'qty', header: 'Units', accessorKey: 'qty' },
  { id: 'revenue', header: 'Revenue', accessorKey: 'revenue' },
  { id: 'account_count', header: 'Dealers', accessorKey: 'account_count' },
]

const visible = ref<GlobalSkuRow[]>([])
const csvColumns: CsvColumn<GlobalSkuRow>[] = [
  { key: 'part_id', header: 'SKU' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_code', header: 'Product code' },
  { key: 'product_family', header: 'Family' },
  { key: 'chambering', header: 'Chambering' },
  { key: 'qty', header: 'Units' },
  { key: 'revenue', header: 'Revenue' },
  { key: 'account_count', header: 'Dealer count' },
]
</script>

<template>
  <div class="space-y-4">
    <div class="flex flex-wrap items-center gap-2">
      <p class="text-muted text-sm">
        Company-wide numbers — every territory, aggregated. No account detail.
      </p>
      <label class="ml-auto">
        <span class="sr-only">Window</span>
        <select v-model.number="months" class="field">
          <option :value="3">Last 3 months</option>
          <option :value="6">Last 6 months</option>
          <option :value="12">Last 12 months</option>
        </select>
      </label>
    </div>

    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && rows.length === 0"
      empty-title="Nothing sold in this window"
      :rows="4"
      @retry="query.refetch()"
    >
      <div class="border-line bg-line grid grid-cols-2 gap-px border">
        <StatTile
          label="Company revenue"
          :value="money(totals.revenue)"
          :sub="`last ${months} months`"
        />
        <StatTile label="Units" :value="count(totals.qty)" />
      </div>

      <div class="mt-4 grid gap-4 lg:grid-cols-2">
        <AppCard title="Top chamberings" :padded="false">
          <ul class="divide-line divide-y">
            <li
              v-for="c in chamberings"
              :key="c.label"
              class="flex items-center justify-between gap-3 px-4 py-2.5"
            >
              <span class="text-ink min-w-0 truncate text-[15px] font-semibold">
                {{ c.label }}
              </span>
              <span class="text-ink-2 shrink-0 text-sm tabular-nums">
                {{ count(c.qty) }} units · {{ money(c.revenue) }}
              </span>
            </li>
          </ul>
        </AppCard>
        <AppCard title="Top families" :padded="false">
          <ul class="divide-line divide-y">
            <li
              v-for="f in families"
              :key="f.label"
              class="flex items-center justify-between gap-3 px-4 py-2.5"
            >
              <span class="text-ink min-w-0 truncate text-[15px] font-semibold">
                {{ f.label }}
              </span>
              <span class="text-ink-2 shrink-0 text-sm tabular-nums">
                {{ count(f.qty) }} units · {{ money(f.revenue) }}
              </span>
            </li>
          </ul>
        </AppCard>
      </div>

      <AppCard :padded="false" class="mt-4">
        <template #header>
          <h2 class="u-label text-ink">Best sellers</h2>
          <AppButton
            variant="ghost"
            :disabled="visible.length === 0"
            @click="exportCsv('global-best-sellers', visible, csvColumns)"
          >
            Export CSV
          </AppButton>
        </template>
        <DataGrid
          :columns="columns"
          :data="rows"
          :initial-sorting="[{ id: 'revenue', desc: true }]"
          searchable
          search-placeholder="Filter by SKU, description, chambering…"
          v-model:global-filter="search"
          :get-row-id="(r: GlobalSkuRow) => r.part_key"
          class="p-3"
          @rows-change="visible = $event"
        >
          <template #cell-revenue="{ row }">
            <span class="tabular-nums">{{ money(row.revenue) }}</span>
          </template>
          <template #cell-qty="{ row }">
            <span class="tabular-nums">{{ count(row.qty) }}</span>
          </template>
          <template #cell-account_count="{ row }">
            <span class="tabular-nums">{{ count(row.account_count) }}</span>
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
                {{ count(row.qty) }} units · {{ money(row.revenue) }} ·
                {{ count(row.account_count) }} dealers
              </p>
            </div>
          </template>
        </DataGrid>
      </AppCard>
    </AsyncState>
  </div>
</template>
