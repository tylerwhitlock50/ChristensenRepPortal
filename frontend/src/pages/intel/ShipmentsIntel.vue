<script setup lang="ts">
import { computed, reactive, ref, shallowRef } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import { useBookShipments } from '@/composables/useBookLists'
import BookListCard from '@/components/BookListCard.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import type { CsvColumn } from '@/lib/csv'
import { count, humanize, isoDate, money, shortDate } from '@/lib/format'
import { trackingList, upsTrackUrl } from '@/lib/tracking'
import {
  distinctOptions,
  filterShipments,
  groupPacklists,
  presetRange,
  rangeProblem,
  SHIPMENT_PRESETS,
  shipmentTotals,
  shipToText,
  sortShipments,
  type BookListTotal,
  type BookShipmentLine,
  type DateRange,
  type PacklistRow,
  type ShipmentFilters,
  type ShipmentPreset,
  withActive,
} from '@/lib/bookLists'

/**
 * Shipments (G04) — every packlist line in the book for a date window: what
 * went out, to whom, on which PO, with tracking and whether it has been
 * invoiced yet. The other Tableau list outside reps lived in.
 *
 * Read from public.report_book_shipments(p_from, p_to), a SECURITY INVOKER
 * function (RLS is the territory filter) built to answer a principal's
 * whole year inside the 8 s timeout. This year is the default window.
 *
 * Dollars are "Shipped value" — the packlist value (qty × price net of trade
 * discount) — and never revenue: shipping can packlist days ahead of
 * invoicing, and revenue counts only once invoiced. The Invoice column says
 * which lines have caught up.
 *
 * Line vs Packlist: the same lines, grouped per packlist on the phone
 * (groupPacklists) — no second request. The filters apply to lines first,
 * so a packlist filtered by product line totals only that product line.
 */
const today = new Date()

const preset = ref<ShipmentPreset>('ytd')
const customFrom = ref('')
const customTo = ref('')

const range = computed<DateRange>(() =>
  preset.value === 'custom'
    ? { from: customFrom.value, to: customTo.value }
    : presetRange(preset.value, today),
)
const rangeError = computed(() =>
  preset.value === 'custom' ? rangeProblem(customFrom.value, customTo.value) : null,
)

/** Custom starts from the window the rep was looking at, not two blank boxes. */
function onPreset(value: ShipmentPreset) {
  if (value === 'custom' && preset.value !== 'custom') {
    customFrom.value = range.value.from
    customTo.value = range.value.to
  }
  preset.value = value
}

const query = useBookShipments(range, () => rangeError.value === null)
const all = computed(() => sortShipments(query.data.value ?? []))

const grain = ref<'line' | 'packlist'>('line')

const filters = reactive<ShipmentFilters>({ account: '', rep: '', productLine: '' })
const filteredLines = computed(() => filterShipments(all.value, filters))
const packlists = computed(() => groupPacklists(filteredLines.value))

/* ---- options from the whole window, so a choice never vanishes from its
   own dropdown. ------------------------------------------------------- */
const accountOptions = computed(() =>
  withActive(
    distinctOptions(all.value, (r) => r.customer_key, (r) => r.customer_name || r.customer_key),
    filters.account,
  ),
)
const repOptions = computed(() =>
  withActive(distinctOptions(all.value, (r) => r.assigned_sales_rep_name), filters.rep),
)
/** Only a book that spans more than one rep gets a Rep filter and column. */
const multiRep = computed(() => repOptions.value.length > 1)
const productLineOptions = computed(() =>
  withActive(distinctOptions(all.value, (r) => r.product_code), filters.productLine),
)

/* ---- what is on screen ----------------------------------------------- */
const visibleLines = shallowRef<BookShipmentLine[]>([])
const visiblePacklists = shallowRef<PacklistRow[]>([])
const totals = computed(() =>
  grain.value === 'line'
    ? shipmentTotals(visibleLines.value)
    : shipmentTotals(visiblePacklists.value),
)

function totalsFor(rows: (BookShipmentLine | PacklistRow)[]): BookListTotal[] {
  const t = shipmentTotals(rows)
  return [
    { label: 'Packlists', value: count(t.packlists) },
    { label: 'Lines', value: count(t.lines) },
    { label: 'Accounts', value: count(t.accounts) },
    { label: 'Qty', value: count(t.qty) },
    { label: 'Shipped value', value: money(t.value) },
  ]
}

const rangeText = computed(() =>
  range.value.from && range.value.to
    ? `${shortDate(range.value.from)} – ${shortDate(range.value.to)}`
    : '',
)

/* ---- columns: line grain ---------------------------------------------- */
const repColumn = <R extends { assigned_sales_rep_name: string | null }>() =>
  multiRep.value
    ? [{ id: 'rep', header: 'Rep', accessorFn: (r: R) => r.assigned_sales_rep_name ?? '' }]
    : []

const lineColumns = computed<ColumnDef<BookShipmentLine, any>[]>(() => [
  { id: 'ship_date', header: 'Shipped', accessorFn: (r) => r.ship_date ?? '' },
  { id: 'account', header: 'Account', accessorFn: (r) => r.customer_name ?? r.customer_key },
  ...(repColumn<BookShipmentLine>() as ColumnDef<BookShipmentLine, any>[]),
  { id: 'packlist_id', header: 'Packlist', accessorKey: 'packlist_id' },
  { id: 'order_id', header: 'Order #', accessorFn: (r) => r.order_id ?? '' },
  { id: 'customer_po_number', header: 'PO', accessorFn: (r) => r.customer_po_number ?? '' },
  { id: 'part_id', header: 'Part', accessorFn: (r) => r.part_id ?? '' },
  { id: 'part_description', header: 'Description', accessorFn: (r) => r.part_description ?? '' },
  { id: 'product_code', header: 'Product line', accessorFn: (r) => r.product_code ?? '' },
  { id: 'shipped_qty', header: 'Qty', accessorKey: 'shipped_qty' },
  { id: 'shipped_value', header: 'Shipped value', accessorKey: 'shipped_value' },
  {
    id: 'invoice',
    header: 'Invoice',
    accessorFn: (r) => [r.invoice_id, r.invoice_status].filter(Boolean).join(' '),
  },
  { id: 'ship_via', header: 'Ship via', accessorFn: (r) => r.ship_via ?? '' },
  { id: 'tracking', header: 'Tracking', accessorFn: (r) => r.tracking_number ?? '' },
  { id: 'ship_to', header: 'Ship-to', accessorFn: (r) => shipToText(r) },
])

/* ---- columns: packlist grain ------------------------------------------ */
const packlistColumns = computed<ColumnDef<PacklistRow, any>[]>(() => [
  { id: 'ship_date', header: 'Shipped', accessorFn: (r) => r.ship_date ?? '' },
  { id: 'account', header: 'Account', accessorFn: (r) => r.customer_name ?? r.customer_key },
  ...(repColumn<PacklistRow>() as ColumnDef<PacklistRow, any>[]),
  { id: 'packlist_id', header: 'Packlist', accessorKey: 'packlist_id' },
  { id: 'order_ids', header: 'Orders', accessorKey: 'order_ids' },
  { id: 'customer_po_numbers', header: 'PO', accessorKey: 'customer_po_numbers' },
  { id: 'line_count', header: 'Lines', accessorKey: 'line_count' },
  { id: 'shipped_qty', header: 'Qty', accessorKey: 'shipped_qty' },
  { id: 'shipped_value', header: 'Shipped value', accessorKey: 'shipped_value' },
  { id: 'invoice', header: 'Invoice', accessorKey: 'invoice_ids' },
  { id: 'ship_via', header: 'Ship via', accessorFn: (r) => r.ship_via ?? '' },
  { id: 'tracking', header: 'Tracking', accessorKey: 'tracking_numbers' },
  { id: 'ship_to', header: 'Ship-to', accessorFn: (r) => shipToText(r) },
])

/* ---- CSV ---------------------------------------------------------------- */
const lineCsv: CsvColumn<BookShipmentLine>[] = [
  { key: 'ship_date', header: 'Ship date' },
  { key: 'customer_key', header: 'Customer key' },
  { key: 'customer_name', header: 'Account' },
  { key: 'assigned_sales_rep_name', header: 'Rep' },
  { key: 'packlist_id', header: 'Packlist' },
  { key: 'line_num', header: 'Packlist line' },
  { key: 'order_id', header: 'Order #' },
  { key: 'order_line_no', header: 'Order line' },
  { key: 'customer_po_number', header: 'PO' },
  { key: 'part_id', header: 'Part' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_code', header: 'Product line' },
  { key: 'shipped_qty', header: 'Qty' },
  { key: 'unit_price', header: 'Unit price' },
  { key: 'trade_discount_pct', header: 'Discount %' },
  { key: 'shipped_value', header: 'Shipped value' },
  { key: 'invoice_id', header: 'Invoice #' },
  { key: 'invoice_status', header: 'Invoice status' },
  { key: 'ship_via', header: 'Ship via' },
  { key: 'tracking_number', header: 'Tracking' },
  { key: 'ship_to_name', header: 'Ship-to' },
  { key: 'ship_to_city', header: 'Ship-to city' },
  { key: 'ship_to_state', header: 'Ship-to state' },
]
const packlistCsv: CsvColumn<PacklistRow>[] = [
  { key: 'ship_date', header: 'Ship date' },
  { key: 'customer_key', header: 'Customer key' },
  { key: 'customer_name', header: 'Account' },
  { key: 'assigned_sales_rep_name', header: 'Rep' },
  { key: 'packlist_id', header: 'Packlist' },
  { key: 'order_ids', header: 'Orders' },
  { key: 'customer_po_numbers', header: 'PO' },
  { key: 'product_codes', header: 'Product lines' },
  { key: 'line_count', header: 'Lines' },
  { key: 'shipped_qty', header: 'Qty' },
  { key: 'shipped_value', header: 'Shipped value' },
  { key: 'invoice_ids', header: 'Invoices' },
  { key: 'uninvoiced_lines', header: 'Lines not invoiced yet' },
  { key: 'ship_via', header: 'Ship via' },
  { key: 'tracking_numbers', header: 'Tracking' },
  { key: 'ship_to_name', header: 'Ship-to' },
  { key: 'ship_to_city', header: 'Ship-to city' },
  { key: 'ship_to_state', header: 'Ship-to state' },
]
const csvPrefix = computed(
  () => `shipments-${grain.value === 'line' ? 'lines' : 'packlists'}-${range.value.from}-to-${range.value.to}`,
)

const accountLink = (customerKey: string) => ({ name: 'account', params: { customerKey } })

const chip = (on: boolean) => (on ? 'bg-ink text-canvas' : 'text-muted')
</script>

<template>
  <div class="space-y-4">
    <!-- A database without 20261027090600: say the list is coming. -->
    <AppCard v-if="query.unavailable.value" title="Shipments">
      <p class="text-ink-2 text-[15px] leading-relaxed">
        The shipments list isn't switched on yet. It appears here once the
        next portal update reaches the database. Until then, each account's
        recent shipments (with tracking) are on its page.
      </p>
    </AppCard>

    <template v-else>
      <!-- The window. Presets first, because "this year" and "last week"
           are what reps ask for; Custom opens two date boxes. -->
      <div class="flex flex-wrap items-end gap-2">
        <label class="block w-full sm:w-48">
          <span class="u-label mb-1.5 block">Shipped</span>
          <select
            :value="preset"
            class="field"
            @change="onPreset(($event.target as HTMLSelectElement).value as ShipmentPreset)"
          >
            <option v-for="p in SHIPMENT_PRESETS" :key="p.value" :value="p.value">
              {{ p.label }}
            </option>
          </select>
        </label>
        <template v-if="preset === 'custom'">
          <label class="block min-w-0 flex-1 sm:w-40 sm:flex-none">
            <span class="u-label mb-1.5 block">From</span>
            <input v-model="customFrom" type="date" class="field" />
          </label>
          <label class="block min-w-0 flex-1 sm:w-40 sm:flex-none">
            <span class="u-label mb-1.5 block">To</span>
            <input v-model="customTo" type="date" class="field" />
          </label>
        </template>
        <div
          class="border-line flex border sm:ml-auto"
          role="group"
          aria-label="Show lines or packlists"
        >
          <button
            type="button"
            class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
            :class="chip(grain === 'line')"
            :aria-pressed="grain === 'line'"
            @click="grain = 'line'"
          >
            Lines
          </button>
          <button
            type="button"
            class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
            :class="chip(grain === 'packlist')"
            :aria-pressed="grain === 'packlist'"
            @click="grain = 'packlist'"
          >
            Packlists
          </button>
        </div>
      </div>
      <!-- Who and what, shared by both grains: the filters cut the lines,
           and the packlist grain is built from what is left. -->
      <div class="grid grid-cols-2 gap-2 sm:flex sm:flex-wrap">
        <label class="col-span-2 block sm:w-64">
          <span class="sr-only">Account</span>
          <select v-model="filters.account" class="field">
            <option value="">All accounts</option>
            <option v-for="o in accountOptions" :key="o.value" :value="o.value">
              {{ o.label }}
            </option>
          </select>
        </label>
        <label v-if="multiRep" class="block sm:w-48">
          <span class="sr-only">Rep</span>
          <select v-model="filters.rep" class="field">
            <option value="">All reps</option>
            <option v-for="o in repOptions" :key="o.value" :value="o.value">
              {{ o.label }}
            </option>
          </select>
        </label>
        <label v-if="productLineOptions.length" class="block sm:w-48">
          <span class="sr-only">Product line</span>
          <select v-model="filters.productLine" class="field">
            <option value="">All product lines</option>
            <option v-for="o in productLineOptions" :key="o.value" :value="o.value">
              {{ o.label }}
            </option>
          </select>
        </label>
      </div>
      <p v-if="rangeError" role="alert" class="text-danger text-sm font-medium">
        {{ rangeError }}
      </p>
      <p v-else-if="rangeText" class="text-muted text-xs">{{ rangeText }}</p>

      <AsyncState
        v-if="!rangeError"
        :loading="query.isPending.value"
        :error="query.error.value"
        :has-data="query.data.value !== undefined"
        :updated-at="query.dataUpdatedAt.value"
        :empty="!query.isPending.value && all.length === 0"
        empty-title="Nothing shipped"
        empty-body="Nothing in your book shipped in this window. Try a longer one."
        :rows="4"
        @retry="query.refetch()"
      >
        <!-- The tiles follow the filters and the search box. -->
        <div class="border-line bg-line grid grid-cols-2 gap-px border md:grid-cols-4">
          <StatTile label="Shipped value" :value="money(totals.value)" sub="Packlist value, not invoiced revenue" />
          <StatTile label="Qty shipped" :value="count(totals.qty)" />
          <StatTile label="Packlists" :value="count(totals.packlists)" />
          <StatTile label="Accounts" :value="count(totals.accounts)" />
        </div>

        <BookListCard
          v-if="grain === 'line'"
          key="lines"
          class="mt-4"
          title="Shipment lines"
          :rows="filteredLines"
          :columns="lineColumns"
          :csv-columns="lineCsv"
          :csv-prefix="csvPrefix"
          :totals="totalsFor"
          :get-row-id="(r: BookShipmentLine) => `${r.packlist_id}:${r.line_num}`"
          search-placeholder="PO, order #, packlist, part or tracking…"
          min-width="80rem"
          @rows-change="visibleLines = $event"
        >
          <template #cell-ship_date="{ row }">
            <span class="whitespace-nowrap tabular-nums">{{ isoDate(row.ship_date) }}</span>
          </template>
          <template #cell-account="{ row }">
            <RouterLink
              :to="accountLink(row.customer_key)"
              class="text-ink block max-w-[14rem] truncate font-semibold underline-offset-2 hover:underline"
            >
              {{ row.customer_name || row.customer_key }}
            </RouterLink>
          </template>
          <template #cell-part_description="{ row }">
            <span class="block max-w-[16rem] truncate" :title="row.part_description ?? undefined">
              {{ row.part_description }}
            </span>
          </template>
          <template #cell-shipped_qty="{ row }">
            <span class="tabular-nums">{{ count(row.shipped_qty) }}</span>
          </template>
          <template #cell-shipped_value="{ row }">
            <span class="tabular-nums">{{ money(row.shipped_value) }}</span>
          </template>
          <template #cell-invoice="{ row }">
            <span v-if="row.invoice_id" class="whitespace-nowrap">
              {{ row.invoice_id }}
              <span v-if="row.invoice_status" class="text-muted text-xs">
                · {{ humanize(row.invoice_status) }}
              </span>
            </span>
            <span v-else class="text-muted whitespace-nowrap">Not invoiced yet</span>
          </template>
          <template #cell-tracking="{ row }">
            <span v-if="trackingList(row.tracking_number).length" class="flex flex-col">
              <a
                v-for="t in trackingList(row.tracking_number)"
                :key="t"
                :href="upsTrackUrl(t)"
                target="_blank"
                rel="noopener noreferrer"
                class="text-ink whitespace-nowrap underline decoration-dotted underline-offset-2"
                :title="`Track ${t} on ups.com`"
              >
                {{ t }}
              </a>
            </span>
            <span v-else class="text-muted">—</span>
          </template>
          <template #cell-ship_to="{ row }">
            <span class="block max-w-[14rem] truncate" :title="shipToText(row)">
              {{ shipToText(row) || '—' }}
            </span>
          </template>
          <template #card="{ row }">
            <div class="px-1">
              <div class="flex items-baseline justify-between gap-3">
                <RouterLink
                  :to="accountLink(row.customer_key)"
                  class="text-ink min-w-0 truncate text-[15px] font-semibold"
                >
                  {{ row.customer_name || row.customer_key }}
                </RouterLink>
                <span class="text-ink shrink-0 text-[15px] font-semibold tabular-nums">
                  {{ money(row.shipped_value) }}
                </span>
              </div>
              <p class="text-ink-2 mt-0.5 truncate text-sm">
                {{ row.part_id || '—' }} · {{ row.part_description }}
              </p>
              <p class="text-muted mt-0.5 text-xs tabular-nums">
                {{ isoDate(row.ship_date) }} · {{ count(row.shipped_qty) }} pcs · packlist
                {{ row.packlist_id }}
                <template v-if="row.order_id"> · order {{ row.order_id }}</template>
                <template v-if="row.customer_po_number"> · PO {{ row.customer_po_number }}</template>
              </p>
              <p class="text-muted mt-0.5 text-xs">
                <template v-if="row.invoice_id">Invoice {{ row.invoice_id }}</template>
                <template v-else>Not invoiced yet</template>
                <template v-if="multiRep && row.assigned_sales_rep_name"> · {{ row.assigned_sales_rep_name }}</template>
              </p>
              <a
                v-for="t in trackingList(row.tracking_number)"
                :key="t"
                :href="upsTrackUrl(t)"
                target="_blank"
                rel="noopener noreferrer"
                class="text-ink mt-1 mr-3 inline-block text-sm underline decoration-dotted underline-offset-2"
              >
                Track {{ t }}
              </a>
            </div>
          </template>
        </BookListCard>

        <BookListCard
          v-else
          key="packlists"
          class="mt-4"
          title="Packlists"
          :rows="packlists"
          :columns="packlistColumns"
          :csv-columns="packlistCsv"
          :csv-prefix="csvPrefix"
          :totals="totalsFor"
          :get-row-id="(r: PacklistRow) => r.key"
          search-placeholder="PO, order #, packlist or tracking…"
          min-width="72rem"
          @rows-change="visiblePacklists = $event"
        >
          <template #cell-ship_date="{ row }">
            <span class="whitespace-nowrap tabular-nums">{{ isoDate(row.ship_date) }}</span>
          </template>
          <template #cell-account="{ row }">
            <RouterLink
              :to="accountLink(row.customer_key)"
              class="text-ink block max-w-[14rem] truncate font-semibold underline-offset-2 hover:underline"
            >
              {{ row.customer_name || row.customer_key }}
            </RouterLink>
          </template>
          <template #cell-shipped_qty="{ row }">
            <span class="tabular-nums">{{ count(row.shipped_qty) }}</span>
          </template>
          <template #cell-shipped_value="{ row }">
            <span class="tabular-nums">{{ money(row.shipped_value) }}</span>
          </template>
          <template #cell-invoice="{ row }">
            <span v-if="row.invoice_ids" class="whitespace-nowrap">{{ row.invoice_ids }}</span>
            <span
              v-if="row.uninvoiced_lines"
              class="text-muted block text-xs whitespace-nowrap"
            >
              {{ row.uninvoiced_lines === row.line_count ? 'Not invoiced yet' : `${count(row.uninvoiced_lines)} lines not invoiced` }}
            </span>
          </template>
          <template #cell-tracking="{ row }">
            <span v-if="trackingList(row.tracking_numbers).length" class="flex flex-col">
              <a
                v-for="t in trackingList(row.tracking_numbers)"
                :key="t"
                :href="upsTrackUrl(t)"
                target="_blank"
                rel="noopener noreferrer"
                class="text-ink whitespace-nowrap underline decoration-dotted underline-offset-2"
                :title="`Track ${t} on ups.com`"
              >
                {{ t }}
              </a>
            </span>
            <span v-else class="text-muted">—</span>
          </template>
          <template #cell-ship_to="{ row }">
            <span class="block max-w-[14rem] truncate" :title="shipToText(row)">
              {{ shipToText(row) || '—' }}
            </span>
          </template>
          <template #card="{ row }">
            <div class="px-1">
              <div class="flex items-baseline justify-between gap-3">
                <RouterLink
                  :to="accountLink(row.customer_key)"
                  class="text-ink min-w-0 truncate text-[15px] font-semibold"
                >
                  {{ row.customer_name || row.customer_key }}
                </RouterLink>
                <span class="text-ink shrink-0 text-[15px] font-semibold tabular-nums">
                  {{ money(row.shipped_value) }}
                </span>
              </div>
              <p class="text-ink-2 mt-0.5 text-sm tabular-nums">
                Packlist {{ row.packlist_id }} · {{ isoDate(row.ship_date) }} ·
                {{ count(row.line_count) }} {{ row.line_count === 1 ? 'line' : 'lines' }},
                {{ count(row.shipped_qty) }} pcs
              </p>
              <p class="text-muted mt-0.5 text-xs">
                <template v-if="row.order_ids">Order {{ row.order_ids }}</template>
                <template v-if="row.customer_po_numbers"> · PO {{ row.customer_po_numbers }}</template>
                <template v-if="row.uninvoiced_lines"> · not all invoiced yet</template>
              </p>
              <a
                v-for="t in trackingList(row.tracking_numbers)"
                :key="t"
                :href="upsTrackUrl(t)"
                target="_blank"
                rel="noopener noreferrer"
                class="text-ink mt-1 mr-3 inline-block text-sm underline decoration-dotted underline-offset-2"
              >
                Track {{ t }}
              </a>
            </div>
          </template>
        </BookListCard>
      </AsyncState>
    </template>
  </div>
</template>
