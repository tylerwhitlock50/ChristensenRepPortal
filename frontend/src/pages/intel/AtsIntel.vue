<script setup lang="ts">
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import { useAtsList, type AtsRow } from '@/composables/useIntel'
import { isViewMissing, useTerritoryAccounts } from '@/composables/useOverview'
import { useAccountSkuGaps } from '@/composables/useAccountGaps'
import AccountPicker from '@/components/AccountPicker.vue'
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
const allRows = computed(() => query.data.value ?? [])

/* ---- "show me the gaps for one dealer" ---------------------------------
   The catalog minus what the chosen account already buys. The account's
   history comes from the same RPC the account page's opportunity card uses
   (036), so the two screens can never disagree about what a dealer carries.

   The picker is fed from the territory rows the Overview already cached, so
   choosing an account costs one RPC and no book query.
------------------------------------------------------------------------- */
const gapAccountKey = ref('')
const gapsQuery = useAccountSkuGaps(gapAccountKey)
const accountsQuery = useTerritoryAccounts()

const accounts = computed(() =>
  [...(accountsQuery.data.value ?? [])].sort((a, b) =>
    (a.customer_name ?? a.customer_key).localeCompare(
      b.customer_name ?? b.customer_key,
    ),
  ),
)

const gapAccountName = computed(() => {
  const a = accounts.value.find((x) => x.customer_key === gapAccountKey.value)
  return a?.customer_name || gapAccountKey.value || 'this account'
})

/**
 * The RPC returns only what this dealer does NOT carry, so its part_keys are
 * exactly the filter. On error or while loading, fall through to the whole
 * catalog rather than showing an empty grid — a rep who picked an account
 * and got nothing would read that as "no stock", not "still loading".
 */
const gapKeys = computed(() => {
  if (!gapAccountKey.value) return null
  const rowsOut = gapsQuery.data.value
  if (!rowsOut) return null
  return new Set(rowsOut.filter((r) => !r.bought_before).map((r) => r.part_key))
})

const rows = computed(() =>
  gapKeys.value
    ? allRows.value.filter((r) => gapKeys.value!.has(r.part_key))
    : allRows.value,
)

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

      <!--
        "What can I sell THIS dealer?" — the catalog filtered to what the
        chosen account does not already carry. Same one-click shape as the
        account dropdown on BacklogIntel, but answering the opposite
        question. Without it this page is territory-agnostic: it can say what
        is in stock, but not who to put it in front of.
      -->
      <AppCard :padded="false" class="mt-4">
        <template #header>
          <h2 class="u-label text-ink">Available to sell</h2>
          <AppButton
            variant="ghost"
            :disabled="visible.length === 0"
            @click="exportCsv(gapAccountKey ? `ats-gaps-${gapAccountKey}` : 'ats-list', visible, csvColumns)"
          >
            Export CSV
          </AppButton>
        </template>

        <div class="border-line space-y-2 border-b p-3">
          <AccountPicker
            v-model="gapAccountKey"
            :accounts="accounts"
            placeholder="Show gaps for one account…"
          />
          <p v-if="gapAccountKey" class="text-muted text-[13px]">
            <template v-if="gapsQuery.isPending.value">Working out what they don't carry…</template>
            <template v-else-if="gapsQuery.error.value">
              Couldn't load that account's history — showing the whole catalog.
            </template>
            <template v-else>
              {{ count(rows.length) }} in stock that
              {{ gapAccountName }} doesn't carry, out of
              {{ count(allRows.length) }}.
            </template>
          </p>
        </div>

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
