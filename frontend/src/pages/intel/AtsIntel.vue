<script setup lang="ts">
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import { useAtsList, type AtsRow } from '@/composables/useIntel'
import { isViewMissing } from '@/composables/useOverview'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import { count, shortDate } from '@/lib/format'

/**
 * ATS — what the company can actually sell right now, straight from the
 * ERP's certified calculation (erp.fact_ats). Until the bi.vw_FactATS feed
 * lands, the view exists but is empty (or missing pre-022) — both get a
 * plain-English state instead of an error.
 */
const search = ref('')
const query = useAtsList()

/**
 * "On the shelf" is the number reps keep asking for: physically in the
 * building AND not spoken for (on hand minus committed). ats_qty stays the
 * ERP's certified promise-able number — it can lean on inbound supply, so
 * the two are shown side by side, never merged.
 */
type ShelfRow = AtsRow & {
  shelf_qty: number
  availability: 'shelf' | 'inbound' | 'none'
}

const rows = computed<ShelfRow[]>(() =>
  (query.data.value ?? []).map((r) => {
    const shelf_qty = Math.max(0, r.on_hand_qty - r.committed_qty)
    return {
      ...r,
      shelf_qty,
      availability: shelf_qty > 0 ? 'shelf' : r.inbound_qty > 0 ? 'inbound' : 'none',
    }
  }),
)

/** Feed-not-landed reads differently from a real failure. */
const feedMissing = computed(() => isViewMissing(query.error.value))

const totals = computed(() => {
  const r = rows.value
  return {
    onShelf: r.filter((x) => x.availability === 'shelf').length,
    shelfUnits: r.reduce((a, x) => a + x.shelf_qty, 0),
    inboundOnly: r.filter((x) => x.availability === 'inbound').length,
    none: r.filter((x) => x.availability === 'none').length,
  }
})

const availabilityLabel = {
  shelf: 'On shelf',
  inbound: 'Inbound only',
  none: 'None',
} as const
const availabilityTone = { shelf: 'good', inbound: 'neutral', none: 'late' } as const

const columns: ColumnDef<ShelfRow, any>[] = [
  { id: 'part_id', header: 'SKU', accessorKey: 'part_id' },
  { id: 'part_description', header: 'Description', accessorKey: 'part_description' },
  { id: 'product_family', header: 'Family', accessorKey: 'product_family' },
  { id: 'chambering', header: 'Chambering', accessorKey: 'chambering' },
  {
    id: 'availability',
    header: 'Availability',
    accessorFn: (r) => availabilityLabel[r.availability],
  },
  { id: 'shelf_qty', header: 'On shelf', accessorKey: 'shelf_qty' },
  { id: 'ats_qty', header: 'ATS', accessorKey: 'ats_qty' },
  { id: 'inbound_qty', header: 'Inbound', accessorKey: 'inbound_qty' },
  { id: 'next_avail_date', header: 'Next avail', accessorKey: 'next_avail_date' },
]

const visible = ref<ShelfRow[]>([])
const csvColumns: CsvColumn<ShelfRow>[] = [
  { key: 'part_id', header: 'SKU' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  { key: 'chambering', header: 'Chambering' },
  { key: 'barrel_length', header: 'Barrel' },
  { key: 'upc', header: 'UPC' },
  { key: 'availability', header: 'Availability', format: (r) => availabilityLabel[r.availability] },
  { key: 'shelf_qty', header: 'On shelf (uncommitted)' },
  { key: 'ats_qty', header: 'ATS qty' },
  { key: 'on_hand_qty', header: 'On hand' },
  { key: 'committed_qty', header: 'Committed' },
  { key: 'backlog_qty', header: 'Backlog' },
  { key: 'inbound_qty', header: 'Inbound' },
  { key: 'next_avail_date', header: 'Next available' },
]
</script>

<template>
  <div class="space-y-4">
    <!-- The feed is a separate deployment step (ERP view + ETL entry); say
         so instead of erroring while it's on the way. -->
    <AppCard v-if="feedMissing" title="ATS list">
      <p class="text-ink-2 text-[15px] leading-relaxed">
        The ATS feed hasn't landed yet. Once the ERP-side view
        (<code>bi.vw_FactATS</code>) ships and the nightly load runs, this
        page fills in on its own.
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
      <div class="border-line bg-line grid grid-cols-2 gap-px border md:grid-cols-4">
        <StatTile label="On the shelf" :value="count(totals.onShelf)" sub="SKUs in stock, not spoken for" />
        <StatTile label="Shelf units" :value="count(totals.shelfUnits)" sub="ready to ship today" />
        <StatTile label="Inbound only" :value="count(totals.inboundOnly)" sub="planned — nothing on the shelf" />
        <StatTile
          label="Nothing available"
          :value="count(totals.none)"
          sub="no stock, no inbound"
          :tone="totals.none > 0 ? 'alert' : 'default'"
        />
      </div>

      <p class="text-muted mt-3 text-xs leading-relaxed">
        <span class="text-ink-2 font-semibold">On shelf</span> = on hand minus
        committed: physically in the building and not spoken for.
        <span class="text-ink-2 font-semibold">ATS</span> is the ERP's certified
        promise-able number and can count on inbound supply that hasn't arrived.
      </p>

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
          :initial-sorting="[{ id: 'shelf_qty', desc: true }]"
          searchable
          search-placeholder="Filter by SKU, description, chambering…"
          v-model:global-filter="search"
          :get-row-id="(r: ShelfRow) => r.part_key"
          class="p-3"
          @rows-change="visible = $event"
        >
          <template #cell-availability="{ row }">
            <AppBadge :tone="availabilityTone[row.availability]">
              {{ availabilityLabel[row.availability] }}
            </AppBadge>
          </template>
          <template #cell-shelf_qty="{ row }">
            <span
              class="font-semibold tabular-nums"
              :class="row.shelf_qty <= 0 ? 'text-accent' : 'text-ink'"
            >
              {{ count(row.shelf_qty) }}
            </span>
          </template>
          <template #cell-ats_qty="{ row }">
            <span class="text-ink-2 tabular-nums">{{ count(row.ats_qty) }}</span>
          </template>
          <template #cell-inbound_qty="{ row }">
            <span class="tabular-nums">{{ count(row.inbound_qty) }}</span>
          </template>
          <template #cell-next_avail_date="{ row }">
            {{ row.availability === 'shelf' ? '—' : shortDate(row.next_avail_date) }}
          </template>
          <template #card="{ row }">
            <div class="px-1">
              <div class="flex items-start justify-between gap-2">
                <p class="text-ink text-[15px] font-semibold">
                  {{ row.part_id }} · {{ row.part_description }}
                </p>
                <AppBadge :tone="availabilityTone[row.availability]">
                  {{ availabilityLabel[row.availability] }}
                </AppBadge>
              </div>
              <p class="text-muted mt-0.5 text-xs">
                {{ row.product_family }} · {{ row.chambering }}
              </p>
              <p class="mt-1 text-sm tabular-nums" :class="row.shelf_qty <= 0 ? 'text-accent' : 'text-ink-2'">
                On shelf {{ count(row.shelf_qty) }} · ATS {{ count(row.ats_qty) }}
                <template v-if="row.availability !== 'shelf' && row.next_avail_date">
                  · next {{ shortDate(row.next_avail_date) }}
                </template>
              </p>
            </div>
          </template>
        </DataGrid>
      </AppCard>
    </AsyncState>
  </div>
</template>
