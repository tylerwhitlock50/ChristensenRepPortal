<script setup lang="ts">
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import { useTerritoryBacklog, type BacklogSkuRow } from '@/composables/useIntel'
import DataGrid from '@/components/DataGrid.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import { count, isoDate, money } from '@/lib/format'

/**
 * Backlog by SKU by account — everything the territory is still owed. Free
 * text still covers SKU/chambering/account, and the account dropdown is the
 * one-click version of "show me Scheels' backorders". The stat tiles follow
 * the dropdown, so filtering to an account turns the page into that
 * account's backorder summary.
 */
const search = ref('')
const accountKey = ref('')
const query = useTerritoryBacklog()
const rows = computed(() => query.data.value ?? [])

const accounts = computed(() => {
  const byKey = new Map<string, { key: string; id: string; name: string }>()
  for (const r of rows.value) {
    if (!byKey.has(r.customer_key)) {
      byKey.set(r.customer_key, {
        key: r.customer_key,
        id: r.customer_id || r.customer_key,
        name: r.customer_name || '',
      })
    }
  }
  return [...byKey.values()].sort((a, b) => a.id.localeCompare(b.id))
})

const filtered = computed(() =>
  accountKey.value
    ? rows.value.filter((r) => r.customer_key === accountKey.value)
    : rows.value,
)

const totals = computed(() => {
  const r = filtered.value
  return {
    amount: r.reduce((a, x) => a + x.backlog_amount, 0),
    qty: r.reduce((a, x) => a + x.backlog_qty, 0),
    accounts: new Set(r.map((x) => x.customer_key)).size,
    skus: new Set(r.map((x) => x.part_key)).size,
  }
})

const columns: ColumnDef<BacklogSkuRow, any>[] = [
  {
    id: 'account',
    header: 'Account',
    // ID first so sorting and the global filter both see "SMOK MOUN" and
    // the full name.
    accessorFn: (r) => `${r.customer_id ?? ''} ${r.customer_name ?? ''}`.trim(),
  },
  { id: 'part_id', header: 'SKU', accessorKey: 'part_id' },
  { id: 'part_description', header: 'Description', accessorKey: 'part_description' },
  { id: 'chambering', header: 'Chambering', accessorKey: 'chambering' },
  { id: 'backlog_qty', header: 'Qty', accessorKey: 'backlog_qty' },
  { id: 'backlog_amount', header: 'Value', accessorKey: 'backlog_amount' },
  {
    id: 'earliest_desired_ship_date',
    header: 'Est. production',
    accessorKey: 'earliest_desired_ship_date',
  },
  { id: 'earliest_promise_date', header: 'Promise', accessorKey: 'earliest_promise_date' },
]

const visible = ref<BacklogSkuRow[]>([])
const csvColumns: CsvColumn<BacklogSkuRow>[] = [
  { key: 'customer_key', header: 'Customer key' },
  { key: 'customer_id', header: 'Account ID' },
  { key: 'customer_name', header: 'Account' },
  { key: 'part_id', header: 'SKU' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  { key: 'chambering', header: 'Chambering' },
  { key: 'backlog_qty', header: 'Backlog qty' },
  { key: 'backlog_amount', header: 'Backlog value' },
  { key: 'open_line_count', header: 'Open lines' },
  { key: 'earliest_desired_ship_date', header: 'Est. production date' },
  { key: 'earliest_promise_date', header: 'Earliest promise' },
  { key: 'latest_order_date', header: 'Latest order' },
]
</script>

<template>
  <div class="space-y-4">
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && rows.length === 0"
      empty-title="No backorders"
      empty-body="Nothing in your territory is waiting on stock right now."
      :rows="4"
      @retry="query.refetch()"
    >
      <div class="border-line bg-line grid grid-cols-2 gap-px border md:grid-cols-4">
        <StatTile
          label="On backorder"
          :value="money(totals.amount)"
          :tone="totals.amount > 0 ? 'alert' : 'default'"
        />
        <StatTile label="Units" :value="count(totals.qty)" />
        <StatTile label="Accounts waiting" :value="count(totals.accounts)" />
        <StatTile label="SKUs affected" :value="count(totals.skus)" />
      </div>

      <AppCard :padded="false" class="mt-4">
        <template #header>
          <h2 class="u-label text-ink">Backlog by SKU</h2>
          <AppButton
            variant="ghost"
            :disabled="visible.length === 0"
            @click="exportCsv('backlog', visible, csvColumns)"
          >
            Export CSV
          </AppButton>
        </template>
        <div class="flex flex-col gap-2 p-3 pb-0 sm:flex-row">
          <label class="block w-full sm:max-w-xs">
            <span class="sr-only">Search</span>
            <input
              type="search"
              :value="search"
              placeholder="Filter by account, SKU, chambering…"
              class="field"
              @input="search = ($event.target as HTMLInputElement).value"
            />
          </label>
          <label class="block w-full sm:max-w-xs">
            <span class="sr-only">Filter by account</span>
            <select v-model="accountKey" class="field">
              <option value="">All accounts</option>
              <option v-for="a in accounts" :key="a.key" :value="a.key">
                {{ a.id }}{{ a.name ? ` — ${a.name}` : '' }}
              </option>
            </select>
          </label>
        </div>
        <DataGrid
          :columns="columns"
          :data="filtered"
          :initial-sorting="[{ id: 'backlog_amount', desc: true }]"
          v-model:global-filter="search"
          :get-row-id="(r: BacklogSkuRow) => `${r.customer_key}:${r.part_key}`"
          class="p-3"
          @rows-change="visible = $event"
        >
          <template #cell-account="{ row }">
            <RouterLink
              :to="{ name: 'account', params: { customerKey: row.customer_key } }"
              class="text-ink block font-semibold whitespace-nowrap underline-offset-2 hover:underline"
            >
              {{ row.customer_id || row.customer_key }}
            </RouterLink>
            <span class="text-muted block max-w-[12rem] truncate text-xs">
              {{ row.customer_name }}
            </span>
          </template>
          <template #cell-part_description="{ row }">
            <span
              class="block max-w-[18rem] truncate"
              :title="row.part_description ?? undefined"
            >
              {{ row.part_description }}
            </span>
          </template>
          <template #cell-backlog_amount="{ row }">
            <span class="tabular-nums">{{ money(row.backlog_amount) }}</span>
          </template>
          <template #cell-backlog_qty="{ row }">
            <span class="tabular-nums">{{ count(row.backlog_qty) }}</span>
          </template>
          <template #cell-earliest_desired_ship_date="{ row }">
            <span class="tabular-nums">{{ isoDate(row.earliest_desired_ship_date) }}</span>
          </template>
          <template #cell-earliest_promise_date="{ row }">
            <span class="tabular-nums">{{ isoDate(row.earliest_promise_date) }}</span>
          </template>
          <template #card="{ row }">
            <div class="px-1">
              <RouterLink
                :to="{ name: 'account', params: { customerKey: row.customer_key } }"
                class="text-ink text-[15px] font-semibold"
              >
                {{ row.customer_id || row.customer_key }}
                <span class="text-muted text-xs font-normal">{{ row.customer_name }}</span>
              </RouterLink>
              <p class="text-ink-2 mt-0.5 truncate text-sm">
                {{ row.part_id }} · {{ row.part_description }}
              </p>
              <p class="text-muted mt-1 text-xs tabular-nums">
                {{ count(row.backlog_qty) }} units · {{ money(row.backlog_amount) }} ·
                est. production {{ isoDate(row.earliest_desired_ship_date) }}
              </p>
            </div>
          </template>
        </DataGrid>
      </AppCard>
    </AsyncState>
  </div>
</template>
