<script setup lang="ts">
import { computed, reactive, shallowRef } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import { useOpenOrderLines } from '@/composables/useBookLists'
import BookListCard from '@/components/BookListCard.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import type { CsvColumn } from '@/lib/csv'
import { count, isoDate, money } from '@/lib/format'
import {
  DEFAULT_OPEN_ORDER_FILTERS,
  distinctOptions,
  filterOpenOrders,
  groupStarts,
  openOrderSubtotals,
  openOrderTotals,
  orderKey,
  orderStatusLabel,
  sortOpenOrders,
  type BookListTotal,
  type OpenOrderFilters,
  type OpenOrderLine,
} from '@/lib/bookLists'

/**
 * Open orders (G03) — every open order line in the book, grouped by account
 * and then order: the list outside reps pulled from Tableau to answer "what
 * does Scheels still have coming, and when?".
 *
 * Read from public.v_open_order_lines (every is_backlog_line row: Released,
 * Firmed and Hold — cancelled and closed lines are never open). "Open $" is
 * the unshipped order value, the same figure as the Overview's Open Orders
 * tile; it is owed, not earned.
 *
 * Grouping on a flat, re-sortable grid: the rows arrive sorted account →
 * order → line, and the account and order are printed only on the first row
 * of each run (groupStarts over the rows the grid shows). Re-sort by Open $
 * and the runs break up, so every row names its own account again.
 *
 * Two default-on/off choices worth knowing:
 *   - "Hide RMA/warranty" starts ON: a return or warranty replacement is not
 *     a sale to chase, and they cluttered the Tableau list.
 *   - "Hide discount/credit lines" starts OFF: the book's open total is net
 *     of them (the Overview tile is), so hiding them by default would make
 *     this page's total disagree with the Overview's.
 */
const query = useOpenOrderLines()
const all = computed(() => sortOpenOrders(query.data.value ?? []))

const filters = reactive<OpenOrderFilters>({ ...DEFAULT_OPEN_ORDER_FILTERS })
const filtered = computed(() => filterOpenOrders(all.value, filters))

/* ---- filter options: from the whole book, not the filtered rows, so a
   choice never disappears from its own dropdown. ---------------------- */
const accountOptions = computed(() =>
  distinctOptions(
    all.value,
    (r) => r.customer_key,
    (r) => `${r.customer_id || r.customer_key}${r.customer_name ? ` — ${r.customer_name}` : ''}`,
  ),
)
/** Only a book that spans more than one rep (a principal, an admin) gets a Rep filter. */
const repOptions = computed(() =>
  distinctOptions(
    all.value,
    (r) => r.assigned_sales_rep_id,
    (r) => r.assigned_sales_rep_name || r.assigned_sales_rep_id || '',
  ),
)
const multiRep = computed(() => repOptions.value.length > 1)
const productLineOptions = computed(() => distinctOptions(all.value, (r) => r.product_code))
const statusOptions = computed(() =>
  distinctOptions(all.value, (r) => orderStatusLabel(r.order_status, r.order_status_desc)),
)

/* ---- what the grid shows (filters + its search box) ------------------ */
const visible = shallowRef<OpenOrderLine[]>([])
const totals = computed(() => openOrderTotals(visible.value))
const subtotals = computed(() => openOrderSubtotals(visible.value))
const accountStarts = computed(() => groupStarts(visible.value, (r) => r.customer_key))
const orderStarts = computed(() => groupStarts(visible.value, orderKey))

function totalsFor(rows: OpenOrderLine[]): BookListTotal[] {
  const t = openOrderTotals(rows)
  return [
    { label: 'Lines', value: count(t.lines) },
    { label: 'Orders', value: count(t.orders) },
    { label: 'Accounts', value: count(t.accounts) },
    { label: 'Open qty', value: count(t.qty) },
    { label: 'Open $', value: money(t.amount) },
  ]
}

const columns = computed<ColumnDef<OpenOrderLine, any>[]>(() => [
  {
    id: 'account',
    header: 'Account',
    // ID first so the search box and sorting see "SCHE INC" and the name.
    accessorFn: (r) => `${r.customer_id ?? r.customer_key} ${r.customer_name ?? ''}`.trim(),
  },
  ...(multiRep.value
    ? [
        {
          id: 'rep',
          header: 'Rep',
          accessorFn: (r) => r.assigned_sales_rep_name ?? r.assigned_sales_rep_id ?? '',
        } as ColumnDef<OpenOrderLine, any>,
      ]
    : []),
  { id: 'order_id', header: 'Order #', accessorKey: 'order_id' },
  { id: 'customer_po_number', header: 'PO', accessorFn: (r) => r.customer_po_number ?? '' },
  { id: 'desired_ship_date', header: 'Want date', accessorFn: (r) => r.desired_ship_date ?? '' },
  { id: 'promise_date', header: 'Promise', accessorFn: (r) => r.promise_date ?? '' },
  {
    id: 'status',
    header: 'Status',
    accessorFn: (r) => orderStatusLabel(r.order_status, r.order_status_desc),
  },
  { id: 'part_id', header: 'Part', accessorFn: (r) => r.part_id ?? '' },
  { id: 'part_description', header: 'Description', accessorFn: (r) => r.part_description ?? '' },
  { id: 'product_code', header: 'Product line', accessorFn: (r) => r.product_code ?? '' },
  { id: 'backlog_qty', header: 'Open qty', accessorKey: 'backlog_qty' },
  { id: 'backlog_amount', header: 'Open $', accessorKey: 'backlog_amount' },
])

const yesNo = (v: boolean) => (v ? 'Yes' : 'No')
const csvColumns: CsvColumn<OpenOrderLine>[] = [
  { key: 'customer_key', header: 'Customer key' },
  { key: 'customer_id', header: 'Account ID' },
  { key: 'customer_name', header: 'Account' },
  { key: 'assigned_sales_rep_name', header: 'Rep' },
  { key: 'order_id', header: 'Order #' },
  { key: 'line_num', header: 'Line' },
  { key: 'order_date', header: 'Order date' },
  { key: 'customer_po_number', header: 'PO' },
  { key: 'status', header: 'Status', format: (r) => orderStatusLabel(r.order_status, r.order_status_desc) },
  { key: 'desired_ship_date', header: 'Want date' },
  { key: 'promise_date', header: 'Promise date' },
  { key: 'part_id', header: 'Part' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_code', header: 'Product line' },
  { key: 'product_family', header: 'Family' },
  { key: 'upc', header: 'UPC' },
  { key: 'program_code', header: 'Program' },
  { key: 'unit_price', header: 'Unit price' },
  { key: 'trade_discount_pct', header: 'Discount %' },
  { key: 'backlog_qty', header: 'Open qty' },
  { key: 'backlog_amount', header: 'Open $' },
  { key: 'credit_status', header: 'Credit status' },
  { key: 'is_past_want', header: 'Past want date', format: (r) => yesNo(r.is_past_want) },
  { key: 'is_past_promise', header: 'Past promise', format: (r) => yesNo(r.is_past_promise) },
  { key: 'is_rma', header: 'RMA / warranty', format: (r) => yesNo(r.is_rma) },
  { key: 'is_non_part', header: 'Discount / credit line', format: (r) => yesNo(r.is_non_part) },
]

const accountLink = (r: OpenOrderLine) => ({
  name: 'account',
  params: { customerKey: r.customer_key },
})
/** The account page opens the order's lines from ?order= (AccountOrdersCard). */
const orderLink = (r: OpenOrderLine) => ({
  name: 'account',
  params: { customerKey: r.customer_key },
  query: { order: r.order_id },
})

const filtersChanged = computed(() =>
  (Object.keys(DEFAULT_OPEN_ORDER_FILTERS) as (keyof OpenOrderFilters)[]).some(
    (k) => filters[k] !== DEFAULT_OPEN_ORDER_FILTERS[k],
  ),
)
function resetFilters() {
  Object.assign(filters, DEFAULT_OPEN_ORDER_FILTERS)
}

const chip = (on: boolean) =>
  on ? 'bg-ink text-canvas' : 'border-line-2 text-ink-2 border bg-transparent'
</script>

<template>
  <div class="space-y-4">
    <!-- A database without 20261027090600 (a preview, or before the
         migration runs): say the list is coming, not that it broke. -->
    <AppCard v-if="query.unavailable.value" title="Open orders">
      <p class="text-ink-2 text-[15px] leading-relaxed">
        The open-orders list isn't switched on yet. It appears here once the
        next portal update reaches the database. Until then, every account's
        open orders are on its page, and the Backlog tab totals them by SKU.
      </p>
    </AppCard>

    <AsyncState
      v-else
      :loading="query.isPending.value"
      :error="query.error.value"
      :has-data="query.data.value !== undefined"
      :updated-at="query.dataUpdatedAt.value"
      :empty="!query.isPending.value && all.length === 0"
      empty-title="No open orders"
      empty-body="Nothing in your book is waiting to ship."
      :rows="4"
      @retry="query.refetch()"
    >
      <!-- The tiles follow every filter and the search box: pick an
           account and they become that account's open-order summary. -->
      <div class="border-line bg-line grid grid-cols-2 gap-px border md:grid-cols-4">
        <StatTile label="Open $" :value="money(totals.amount)" sub="Unshipped order value" />
        <StatTile label="Open qty" :value="count(totals.qty)" />
        <StatTile
          label="Orders"
          :value="count(totals.orders)"
          :sub="`${count(totals.accounts)} ${totals.accounts === 1 ? 'account' : 'accounts'}`"
        />
        <!-- Also the way into "Past want date" — the late slice is what a
             dealer calls about. -->
        <button
          type="button"
          class="block h-full w-full text-left"
          :title="filters.pastWantOnly ? 'Show every open line' : 'Show only lines past their want date'"
          :aria-pressed="filters.pastWantOnly"
          @click="filters.pastWantOnly = !filters.pastWantOnly"
        >
          <StatTile
            class="hover:bg-canvas h-full transition-colors"
            label="Past want date"
            :value="money(totals.pastWantAmount)"
            :tone="totals.pastWantAmount > 0 ? 'alert' : 'default'"
          />
        </button>
      </div>

      <BookListCard
        class="mt-4"
        title="Open order lines"
        :rows="filtered"
        :columns="columns"
        :csv-columns="csvColumns"
        csv-prefix="open-orders"
        :totals="totalsFor"
        :get-row-id="(r: OpenOrderLine) => `${r.order_id}:${r.line_num}`"
        search-placeholder="PO, order #, part or description…"
        min-width="68rem"
        @rows-change="visible = $event"
      >
        <template #filters>
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
            <label class="block sm:w-40">
              <span class="sr-only">Status</span>
              <select v-model="filters.status" class="field">
                <option value="">All statuses</option>
                <option v-for="o in statusOptions" :key="o.value" :value="o.value">
                  {{ o.label }}
                </option>
              </select>
            </label>
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              class="tap-target font-label inline-flex items-center px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
              :class="chip(filters.pastWantOnly)"
              :aria-pressed="filters.pastWantOnly"
              @click="filters.pastWantOnly = !filters.pastWantOnly"
            >
              Past want date
            </button>
            <button
              type="button"
              class="tap-target font-label inline-flex items-center px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
              :class="chip(filters.hideRma)"
              :aria-pressed="filters.hideRma"
              @click="filters.hideRma = !filters.hideRma"
            >
              Hide RMA/warranty
            </button>
            <button
              type="button"
              class="tap-target font-label inline-flex items-center px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
              :class="chip(filters.hideNonPart)"
              :aria-pressed="filters.hideNonPart"
              @click="filters.hideNonPart = !filters.hideNonPart"
            >
              Hide discount/credit lines
            </button>
            <button
              v-if="filtersChanged"
              type="button"
              class="btn-ghost text-[13px]"
              @click="resetFilters"
            >
              Reset filters
            </button>
          </div>
        </template>

        <!-- Grouping: the account and the order print once, on the first
             row of their run. The other rows keep the text for screen
             readers so a row read on its own still says whose it is. -->
        <template #cell-account="{ row }">
          <template v-if="accountStarts.has(row)">
            <RouterLink
              :to="accountLink(row)"
              class="text-ink block font-semibold whitespace-nowrap underline-offset-2 hover:underline"
            >
              {{ row.customer_id || row.customer_key }}
            </RouterLink>
            <span class="text-muted block max-w-[14rem] truncate text-xs">
              {{ row.customer_name }}
            </span>
            <span
              v-if="subtotals.byAccount.get(row.customer_key)"
              class="text-ink-2 block text-xs tabular-nums"
            >
              {{ count(subtotals.byAccount.get(row.customer_key)!.orders) }}
              {{ subtotals.byAccount.get(row.customer_key)!.orders === 1 ? 'order' : 'orders' }} ·
              {{ money(subtotals.byAccount.get(row.customer_key)!.amount) }}
            </span>
          </template>
          <span v-else class="sr-only">{{ row.customer_id }} {{ row.customer_name }}</span>
        </template>
        <template #cell-order_id="{ row }">
          <RouterLink
            v-if="orderStarts.has(row)"
            :to="orderLink(row)"
            class="text-ink font-semibold whitespace-nowrap tabular-nums underline decoration-dotted underline-offset-2"
            :title="`Open order ${row.order_id} on the account page`"
          >
            {{ row.order_id }}
          </RouterLink>
          <span v-else class="sr-only">{{ row.order_id }}</span>
        </template>
        <template #cell-customer_po_number="{ row }">
          <span v-if="orderStarts.has(row)" class="whitespace-nowrap">
            {{ row.customer_po_number || '—' }}
          </span>
          <span v-else class="sr-only">{{ row.customer_po_number }}</span>
        </template>
        <template #cell-desired_ship_date="{ row }">
          <span
            class="whitespace-nowrap tabular-nums"
            :class="row.is_past_want ? 'text-accent font-semibold' : ''"
          >
            {{ isoDate(row.desired_ship_date) }}
          </span>
        </template>
        <template #cell-promise_date="{ row }">
          <span
            class="whitespace-nowrap tabular-nums"
            :class="row.is_past_promise ? 'text-accent font-semibold' : ''"
          >
            {{ isoDate(row.promise_date) }}
          </span>
        </template>
        <template #cell-status="{ row }">
          <span class="whitespace-nowrap">
            {{ orderStatusLabel(row.order_status, row.order_status_desc) }}
          </span>
          <AppBadge v-if="row.is_rma" tone="neutral" class="ml-1">RMA</AppBadge>
        </template>
        <template #cell-part_id="{ row }">
          <span class="whitespace-nowrap">{{ row.part_id || '—' }}</span>
        </template>
        <template #cell-part_description="{ row }">
          <span class="block max-w-[18rem] truncate" :title="row.part_description ?? undefined">
            {{ row.part_description }}
          </span>
        </template>
        <template #cell-backlog_qty="{ row }">
          <span class="tabular-nums">{{ count(row.backlog_qty) }}</span>
        </template>
        <template #cell-backlog_amount="{ row }">
          <span class="tabular-nums">{{ money(row.backlog_amount) }}</span>
        </template>

        <!-- Phone: the same grouping as stacked headings — the account once,
             the order once, then its lines. -->
        <template #card="{ row }">
          <div class="px-1">
            <div
              v-if="accountStarts.has(row)"
              class="bg-canvas -mx-1 mb-2 flex items-baseline justify-between gap-3 px-2 py-1.5"
            >
              <RouterLink :to="accountLink(row)" class="text-ink min-w-0 truncate text-[15px] font-semibold">
                {{ row.customer_name || row.customer_id || row.customer_key }}
              </RouterLink>
              <span
                v-if="subtotals.byAccount.get(row.customer_key)"
                class="text-ink-2 shrink-0 text-xs tabular-nums"
              >
                {{ money(subtotals.byAccount.get(row.customer_key)!.amount) }}
              </span>
            </div>
            <p v-if="orderStarts.has(row)" class="text-ink text-sm">
              <RouterLink :to="orderLink(row)" class="font-semibold underline decoration-dotted underline-offset-2">
                Order {{ row.order_id }}
              </RouterLink>
              <template v-if="row.customer_po_number"> · PO {{ row.customer_po_number }}</template>
              · {{ orderStatusLabel(row.order_status, row.order_status_desc) }}
              <template v-if="multiRep && row.assigned_sales_rep_name">
                · {{ row.assigned_sales_rep_name }}
              </template>
            </p>
            <p class="text-ink-2 mt-0.5 truncate text-sm">
              {{ row.part_id || '—' }} · {{ row.part_description }}
            </p>
            <p class="text-muted mt-0.5 text-xs tabular-nums">
              {{ count(row.backlog_qty) }} open · {{ money(row.backlog_amount) }} · want
              <span :class="row.is_past_want ? 'text-accent font-semibold' : ''">
                {{ isoDate(row.desired_ship_date) }}</span>
              · promise
              <span :class="row.is_past_promise ? 'text-accent font-semibold' : ''">
                {{ isoDate(row.promise_date) }}</span>
              <template v-if="row.product_code"> · {{ row.product_code }}</template>
            </p>
            <AppBadge v-if="row.is_rma" tone="neutral" class="mt-1">RMA / warranty</AppBadge>
          </div>
        </template>

        <template #empty>
          <p class="text-muted py-10 text-center text-[15px]">
            No open line matches.
            <button v-if="filtersChanged" type="button" class="btn-ghost text-[15px]" @click="resetFilters">
              Reset filters
            </button>
          </p>
        </template>
      </BookListCard>
    </AsyncState>
  </div>
</template>
