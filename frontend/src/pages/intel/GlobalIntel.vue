<script setup lang="ts">
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import {
  BEST_SELLER_MIN_DEALERS,
  isBroadlyStocked,
  isGunRow,
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
import { count, share } from '@/lib/format'

/**
 * Global intel — company-wide best sellers, top chamberings, family mix.
 * Aggregates only, by design and by construction: the definer RPC (033)
 * returns part-grain sums plus an account COUNT and nothing account-shaped.
 * Units and mix proportions only — no dollars. Reps may see what sells
 * company-wide, never company-level revenue.
 */
const months = ref(12)
const search = ref('')
/** Reps sell guns; component SKUs (OEM barrels etc.) dominate raw units and
 *  drown the mix, so the page defaults to firearms only. The toggle is the
 *  escape hatch for anyone who does want the whole catalog. */
const gunsOnly = ref(true)
/** SMUs (dealer-exclusive runs) reach so few dealers they're noise on a
 *  best-sellers list; default them out. Grid-only — the mix cards and tiles
 *  keep every sale, and the toggle shows the full list on demand. */
const excludeSmus = ref(true)
const query = useGlobalProductSales(months)
const allRows = computed(() => query.data.value ?? [])
const rows = computed(() =>
  gunsOnly.value ? allRows.value.filter(isGunRow) : allRows.value,
)
const bestSellerRows = computed(() =>
  excludeSmus.value ? rows.value.filter(isBroadlyStocked) : rows.value,
)

const chamberings = computed(() => rollupBy(rows.value, 'chambering').slice(0, 10))
const families = computed(() => rollupBy(rows.value, 'product_family').slice(0, 10))

const totals = computed(() => ({
  qty: rows.value.reduce((a, r) => a + r.qty, 0),
  skus: rows.value.length,
}))

/** A row's (or rollup's) share of all units in the window. */
function unitShare(qty: number): number | null {
  return totals.value.qty > 0 ? qty / totals.value.qty : null
}

const columns: ColumnDef<GlobalSkuRow, any>[] = [
  { id: 'part_id', header: 'SKU', accessorKey: 'part_id' },
  { id: 'part_description', header: 'Description', accessorKey: 'part_description' },
  { id: 'product_family', header: 'Family', accessorKey: 'product_family' },
  { id: 'chambering', header: 'Chambering', accessorKey: 'chambering' },
  { id: 'qty', header: 'Units', accessorKey: 'qty' },
  // Share of units — sorts identically to qty, so reuse it as the accessor.
  { id: 'mix', header: 'Mix', accessorKey: 'qty' },
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
  {
    key: 'unit_share_pct',
    header: 'Unit share %',
    format: (r) => {
      const s = unitShare(r.qty)
      return s == null ? null : Number((s * 100).toFixed(2))
    },
  },
  { key: 'account_count', header: 'Dealer count' },
]
</script>

<template>
  <div class="space-y-4">
    <div class="flex flex-wrap items-center gap-2">
      <p class="text-muted text-sm">
        Company-wide units and mix — every territory, aggregated. No dollars,
        no account detail.
      </p>
      <label class="tap-target ml-auto flex items-center gap-2">
        <input
          v-model="gunsOnly"
          type="checkbox"
          class="size-5 shrink-0 rounded border-line-2"
        />
        <span class="text-ink-2 text-sm font-medium">Guns only</span>
      </label>
      <label>
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
          label="Company units"
          :value="count(totals.qty)"
          :sub="`last ${months} months`"
        />
        <StatTile label="SKUs sold" :value="count(totals.skus)" />
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
                {{ count(c.qty) }} units · {{ share(unitShare(c.qty)) }} of mix
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
                {{ count(f.qty) }} units · {{ share(unitShare(f.qty)) }} of mix
              </span>
            </li>
          </ul>
        </AppCard>
      </div>

      <AppCard :padded="false" class="mt-4">
        <template #header>
          <h2 class="u-label text-ink">Best sellers</h2>
          <label
            class="tap-target ml-auto flex items-center gap-2"
            :title="`Hide SKUs bought by fewer than ${BEST_SELLER_MIN_DEALERS} dealers (SMUs / dealer exclusives)`"
          >
            <input
              v-model="excludeSmus"
              type="checkbox"
              class="size-5 shrink-0 rounded border-line-2"
            />
            <span class="text-ink-2 text-sm font-medium">
              {{ BEST_SELLER_MIN_DEALERS }}+ dealers
            </span>
          </label>
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
          :data="bestSellerRows"
          :initial-sorting="[{ id: 'qty', desc: true }]"
          searchable
          search-placeholder="Filter by SKU, description, chambering…"
          v-model:global-filter="search"
          :get-row-id="(r: GlobalSkuRow) => r.part_key"
          class="p-3"
          @rows-change="visible = $event"
        >
          <template #cell-qty="{ row }">
            <span class="tabular-nums">{{ count(row.qty) }}</span>
          </template>
          <template #cell-mix="{ row }">
            <span class="tabular-nums">{{ share(unitShare(row.qty)) }}</span>
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
                {{ count(row.qty) }} units · {{ share(unitShare(row.qty)) }} of mix ·
                {{ count(row.account_count) }} dealers
              </p>
            </div>
          </template>
        </DataGrid>
      </AppCard>
    </AsyncState>
  </div>
</template>
