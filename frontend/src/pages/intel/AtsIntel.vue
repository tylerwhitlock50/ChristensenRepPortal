<script setup lang="ts">
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import { useAtsList, type AtsRow } from '@/composables/useIntel'
import { isViewMissing } from '@/composables/useOverview'
import DataGrid from '@/components/DataGrid.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import { count } from '@/lib/format'

/**
 * ATS — what the company can actually sell right now, straight from the
 * ERP's certified calculation (erp.fact_available_to_sell, landed from
 * bi.vw_FactAvailableToSell). On hand is the SHIPPING warehouse net of
 * staging; committed = allocated open orders; backlog = all open demand;
 * ATS is signed, so negatives mean oversold. The upstream model does not
 * (yet) certify inbound supply or a next-available date.
 */
const search = ref('')
const query = useAtsList()
const rows = computed(() => query.data.value ?? [])

/** Feed-not-landed reads differently from a real failure. */
const feedMissing = computed(() => isViewMissing(query.error.value))

const totals = computed(() => {
  const r = rows.value
  return {
    sellable: r.filter((x) => x.ats_qty > 0).length,
    units: r.reduce((a, x) => a + Math.max(0, x.ats_qty), 0),
    out: r.filter((x) => x.ats_qty <= 0).length,
  }
})

const columns: ColumnDef<AtsRow, any>[] = [
  { id: 'part_id', header: 'SKU', accessorKey: 'part_id' },
  { id: 'part_description', header: 'Description', accessorKey: 'part_description' },
  { id: 'product_family', header: 'Family', accessorKey: 'product_family' },
  { id: 'chambering', header: 'Chambering', accessorKey: 'chambering' },
  { id: 'ats_qty', header: 'ATS', accessorKey: 'ats_qty' },
  { id: 'on_hand_qty', header: 'On hand', accessorKey: 'on_hand_qty' },
  { id: 'committed_qty', header: 'Committed', accessorKey: 'committed_qty' },
  { id: 'backlog_qty', header: 'Backlog', accessorKey: 'backlog_qty' },
]

const visible = ref<AtsRow[]>([])
const csvColumns: CsvColumn<AtsRow>[] = [
  { key: 'part_id', header: 'SKU' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  { key: 'chambering', header: 'Chambering' },
  { key: 'barrel_length', header: 'Barrel' },
  { key: 'upc', header: 'UPC' },
  { key: 'ats_qty', header: 'ATS qty' },
  { key: 'on_hand_qty', header: 'On hand' },
  { key: 'committed_qty', header: 'Committed' },
  { key: 'backlog_qty', header: 'Backlog' },
]
</script>

<template>
  <div class="space-y-4">
    <!-- The feed is a separate deployment step (ERP view + ETL entry); say
         so instead of erroring while it's on the way. -->
    <AppCard v-if="feedMissing" title="ATS list">
      <p class="text-ink-2 text-[15px] leading-relaxed">
        The ATS feed hasn't landed yet. Once the ERP-side view
        (<code>bi.vw_FactAvailableToSell</code>) ships and the nightly load
        runs, this page fills in on its own.
      </p>
    </AppCard>

    <AsyncState
      v-else
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && rows.length === 0"
      empty-title="No ATS data yet"
      empty-body="The table exists but the nightly ERP load hasn't filled it. Check back after the next load."
      :rows="4"
      @retry="query.refetch()"
    >
      <div class="border-line bg-line grid grid-cols-3 gap-px border">
        <StatTile label="Sellable SKUs" :value="count(totals.sellable)" />
        <StatTile label="Units available" :value="count(totals.units)" />
        <StatTile
          label="Out of stock"
          :value="count(totals.out)"
          :tone="totals.out > 0 ? 'alert' : 'default'"
        />
      </div>

      <AppCard :padded="false" class="mt-4">
        <template #header>
          <h2 class="u-label text-ink">Available to sell</h2>
          <AppButton
            variant="ghost"
            :disabled="visible.length === 0"
            @click="exportCsv('ats-list', visible, csvColumns)"
          >
            Export CSV
          </AppButton>
        </template>
        <DataGrid
          :columns="columns"
          :data="rows"
          :initial-sorting="[{ id: 'ats_qty', desc: true }]"
          searchable
          search-placeholder="Filter by SKU, description, chambering…"
          v-model:global-filter="search"
          :get-row-id="(r: AtsRow) => r.part_key"
          class="p-3"
          @rows-change="visible = $event"
        >
          <template #cell-ats_qty="{ row }">
            <span
              class="font-semibold tabular-nums"
              :class="row.ats_qty <= 0 ? 'text-accent' : 'text-ink'"
            >
              {{ count(row.ats_qty) }}
            </span>
          </template>
          <template #cell-on_hand_qty="{ row }">
            <span class="tabular-nums">{{ count(row.on_hand_qty) }}</span>
          </template>
          <template #cell-committed_qty="{ row }">
            <span class="tabular-nums">{{ count(row.committed_qty) }}</span>
          </template>
          <template #cell-backlog_qty="{ row }">
            <span class="tabular-nums">{{ count(row.backlog_qty) }}</span>
          </template>
          <template #card="{ row }">
            <div class="px-1">
              <p class="text-ink text-[15px] font-semibold">
                {{ row.part_id }} · {{ row.part_description }}
              </p>
              <p class="text-muted mt-0.5 text-xs">
                {{ row.product_family }} · {{ row.chambering }}
              </p>
              <p class="mt-1 text-sm tabular-nums" :class="row.ats_qty <= 0 ? 'text-accent' : 'text-ink-2'">
                ATS {{ count(row.ats_qty) }} · on hand {{ count(row.on_hand_qty) }}
              </p>
            </div>
          </template>
        </DataGrid>
      </AppCard>
    </AsyncState>
  </div>
</template>
