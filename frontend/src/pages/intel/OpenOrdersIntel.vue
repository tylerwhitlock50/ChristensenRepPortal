<script setup lang="ts">
import { computed, reactive, shallowRef } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import type { ColumnDef } from '@tanstack/vue-table'
import { useOpenOrderLines } from '@/composables/useBookLists'
import { useDataFreshness } from '@/composables/useDataFreshness'
import BookListCard from '@/components/BookListCard.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ProductLink from '@/components/ui/ProductLink.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { exportTimestamp } from '@/lib/download'
import type { ExportColumn } from '@/lib/xlsx'
import { count, isoDate, money, shortDate } from '@/lib/format'
import {
  DEFAULT_OPEN_ORDER_FILTERS,
  distinctOptions,
  filterOpenOrders,
  groupStarts,
  openOrderSubtotals,
  openOrderTotals,
  openSkuTotals,
  orderKey,
  orderStatusLabel,
  rollupOpenOrdersBySku,
  sortOpenOrders,
  type BookListTotal,
  type OpenOrderFilters,
  type OpenOrderLine,
  type OpenSkuRow,
} from '@/lib/bookLists'

/**
 * Open orders (G03) — every open order line in the book, shown two ways:
 *
 *   By order  one row per line, grouped by account and then order: the list
 *             outside reps pulled from Tableau to answer "what does Scheels
 *             still have coming, and when?".
 *   By SKU    the same lines added up by SKU for each account: "how many
 *             6.5 PRC Ridgelines am I owed, and who is waiting on them?".
 *
 * These were two tabs ("Open orders" and "Backlog") reading the same rows
 * through two views, with different defaults for RMA/warranty lines — so the
 * same question got two quantities (rep feedback, 2026-11). Now there is one
 * read (public.v_open_order_lines: every is_backlog_line row — Released,
 * Firmed and Hold; cancelled and closed lines are never open), one set of
 * filters, and the by-SKU rows are added up here from the lines the filters
 * left (rollupOpenOrdersBySku), so the two cuts cannot disagree.
 *
 * "Open $" is the unshipped order value, the same figure as the Overview's
 * Open Orders tile; it is owed, not earned. It is never called backlog here:
 * on the portal that word means the past-promise slice.
 *
 * The cut is in the URL (?view=sku), so a shared link and the old
 * /intel/backlog address (router: redirects here) land on the right one.
 *
 * By order, on a flat re-sortable grid: the rows arrive sorted account →
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

type View = 'order' | 'sku'
const route = useRoute()
const router = useRouter()
const view = computed<View>({
  get: () => (route.query.view === 'sku' ? 'sku' : 'order'),
  set: (v) =>
    void router.replace({ query: { ...route.query, view: v === 'sku' ? 'sku' : undefined } }),
})

const filters = reactive<OpenOrderFilters>({ ...DEFAULT_OPEN_ORDER_FILTERS })
const filtered = computed(() => filterOpenOrders(all.value, filters))
/** The filters cut the lines; the SKU rows are built from what is left. */
const bySku = computed(() => rollupOpenOrdersBySku(filtered.value))

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
/* Chambering reached the view in 20261119130000. Before that migration it is
   null on every line, and a column and filter with nothing in them would
   only confuse. */
const showChambering = computed(() => all.value.some((r) => (r.chambering ?? '').trim() !== ''))

/**
 * What "Hide RMA/warranty" is hiding, in numbers, with the switch beside
 * them: these lines are in the Overview's Open Orders tile, so while they
 * are hidden this page's total can sit under it.
 */
const hiddenRma = computed(() => {
  if (!filters.hideRma) return { lines: 0, qty: 0 }
  const hidden = filterOpenOrders(all.value, { ...filters, hideRma: false }).filter((r) => r.is_rma)
  return { lines: hidden.length, qty: hidden.reduce((a, r) => a + r.backlog_qty, 0) }
})

/* ---- what the grid shows (filters + its search box) ------------------ */
const visibleLines = shallowRef<OpenOrderLine[]>([])
const visibleSkus = shallowRef<OpenSkuRow[]>([])
/** The tiles: the same four figures in either cut, over the rows on screen. */
const totals = computed(() =>
  view.value === 'sku' ? openSkuTotals(visibleSkus.value) : openOrderTotals(visibleLines.value),
)
const subtotals = computed(() => openOrderSubtotals(visibleLines.value))
const accountStarts = computed(() => groupStarts(visibleLines.value, (r) => r.customer_key))
const orderStarts = computed(() => groupStarts(visibleLines.value, orderKey))

function lineTotalsFor(rows: OpenOrderLine[]): BookListTotal[] {
  const t = openOrderTotals(rows)
  return [
    { label: 'Lines', value: count(t.lines) },
    { label: 'Orders', value: count(t.orders) },
    { label: 'Accounts', value: count(t.accounts) },
    { label: 'Open qty', value: count(t.qty) },
    { label: 'Open $', value: money(t.amount) },
  ]
}
function skuTotalsFor(rows: OpenSkuRow[]): BookListTotal[] {
  const t = openSkuTotals(rows)
  return [
    { label: 'SKUs', value: count(t.skus) },
    { label: 'Accounts', value: count(t.accounts) },
    { label: 'Lines', value: count(t.lines) },
    { label: 'Open qty', value: count(t.qty) },
    { label: 'Open $', value: money(t.amount) },
  ]
}

/* ---- columns: by order ------------------------------------------------ */
const lineColumns = computed<ColumnDef<OpenOrderLine, any>[]>(() => [
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

/* ---- columns: by SKU ---------------------------------------------------
   The dates are the same two the lines carry — "Want date" and "Promise" —
   as the soonest among the SKU's lines. Family and Chambering filter in the
   column header (DataGrid meta.filter); Product line is already a page
   filter above. */
const skuColumns = computed<ColumnDef<OpenSkuRow, any>[]>(() => [
  {
    id: 'account',
    header: 'Account',
    accessorFn: (r) => `${r.customer_id ?? r.customer_key} ${r.customer_name ?? ''}`.trim(),
  },
  ...(multiRep.value
    ? [
        {
          id: 'rep',
          header: 'Rep',
          accessorFn: (r) => r.assigned_sales_rep_name ?? r.assigned_sales_rep_id ?? '',
        } as ColumnDef<OpenSkuRow, any>,
      ]
    : []),
  { id: 'part_id', header: 'SKU', accessorFn: (r) => r.part_id ?? '' },
  { id: 'part_description', header: 'Description', accessorFn: (r) => r.part_description ?? '' },
  {
    id: 'product_family',
    header: 'Family',
    accessorFn: (r) => r.product_family ?? '',
    meta: { filter: 'select' },
  },
  { id: 'product_code', header: 'Product line', accessorFn: (r) => r.product_code ?? '' },
  ...(showChambering.value
    ? [
        {
          id: 'chambering',
          header: 'Chambering',
          accessorFn: (r) => r.chambering ?? '',
          meta: { filter: 'select' },
        } as ColumnDef<OpenSkuRow, any>,
      ]
    : []),
  { id: 'backlog_qty', header: 'Open qty', accessorKey: 'backlog_qty' },
  { id: 'backlog_amount', header: 'Open $', accessorKey: 'backlog_amount' },
  {
    id: 'earliest_desired_ship_date',
    header: 'Earliest want date',
    accessorFn: (r) => r.earliest_desired_ship_date ?? '',
  },
  {
    id: 'earliest_promise_date',
    header: 'Earliest promise',
    accessorFn: (r) => r.earliest_promise_date ?? '',
  },
])

const yesNo = (v: boolean) => (v ? 'Yes' : 'No')
/* The download (Excel and CSV): the screen's columns plus what the row
   carries that helps in a spreadsheet. Ids are text so Excel keeps them as
   typed; the discount stays a whole percent (10 = 10%), as the ERP has it. */
const lineExport = computed<ExportColumn<OpenOrderLine>[]>(() => [
  { key: 'customer_key', header: 'Customer key', type: 'text' },
  { key: 'customer_id', header: 'Account ID', type: 'text' },
  { key: 'customer_name', header: 'Account' },
  { key: 'assigned_sales_rep_name', header: 'Rep' },
  { key: 'order_id', header: 'Order #', type: 'text' },
  { key: 'line_num', header: 'Line', type: 'integer' },
  { key: 'order_date', header: 'Order date', type: 'date' },
  { key: 'customer_po_number', header: 'PO', type: 'text' },
  { key: 'desired_ship_date', header: 'Want date', type: 'date' },
  { key: 'promise_date', header: 'Promise', type: 'date' },
  { key: 'status', header: 'Status', format: (r) => orderStatusLabel(r.order_status, r.order_status_desc) },
  { key: 'part_id', header: 'Part', type: 'text' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_code', header: 'Product line', type: 'text' },
  { key: 'product_family', header: 'Family' },
  ...(showChambering.value
    ? [{ key: 'chambering', header: 'Chambering' } as ExportColumn<OpenOrderLine>]
    : []),
  { key: 'upc', header: 'UPC', type: 'text' },
  { key: 'program_code', header: 'Program', type: 'text' },
  { key: 'unit_price', header: 'Unit price', type: 'money' },
  { key: 'trade_discount_pct', header: 'Discount %', type: 'number' },
  { key: 'backlog_qty', header: 'Open qty', type: 'number' },
  { key: 'backlog_amount', header: 'Open $', type: 'money' },
  { key: 'credit_status', header: 'Credit status' },
  { key: 'is_past_want', header: 'Past want date', format: (r) => yesNo(r.is_past_want) },
  { key: 'is_past_promise', header: 'Past promise', format: (r) => yesNo(r.is_past_promise) },
  { key: 'is_rma', header: 'RMA / warranty', format: (r) => yesNo(r.is_rma) },
  { key: 'is_non_part', header: 'Discount / credit line', format: (r) => yesNo(r.is_non_part) },
])
const skuExport = computed<ExportColumn<OpenSkuRow>[]>(() => [
  { key: 'customer_key', header: 'Customer key', type: 'text' },
  { key: 'customer_id', header: 'Account ID', type: 'text' },
  { key: 'customer_name', header: 'Account' },
  { key: 'assigned_sales_rep_name', header: 'Rep' },
  { key: 'part_id', header: 'SKU', type: 'text' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  { key: 'product_code', header: 'Product line', type: 'text' },
  ...(showChambering.value
    ? [{ key: 'chambering', header: 'Chambering' } as ExportColumn<OpenSkuRow>]
    : []),
  { key: 'backlog_qty', header: 'Open qty', type: 'number' },
  { key: 'backlog_amount', header: 'Open $', type: 'money' },
  { key: 'open_line_count', header: 'Open lines', type: 'integer' },
  { key: 'order_count', header: 'Orders', type: 'integer' },
  { key: 'earliest_desired_ship_date', header: 'Earliest want date', type: 'date' },
  { key: 'earliest_promise_date', header: 'Earliest promise', type: 'date' },
  { key: 'latest_order_date', header: 'Latest order', type: 'date' },
  { key: 'is_past_want', header: 'Past want date', format: (r) => yesNo(r.is_past_want) },
  { key: 'is_past_promise', header: 'Past promise', format: (r) => yesNo(r.is_past_promise) },
])

/* ---- what the downloaded sheet says about itself ---------------------- */
const { loadedAt, ordersThrough } = useDataFreshness()

const accountName = computed(() => {
  if (!filters.account) return ''
  const r = all.value.find((x) => x.customer_key === filters.account)
  return r?.customer_name || r?.customer_id || filters.account
})
const accountLabel = computed(
  () => accountOptions.value.find((o) => o.value === filters.account)?.label || accountName.value,
)
const repName = computed(() =>
  filters.rep ? repOptions.value.find((o) => o.value === filters.rep)?.label || filters.rep : '',
)

/** Picking an account (or a rep) makes the sheet that account's list. */
const exportTitle = computed(() => {
  const what = view.value === 'sku' ? 'Open orders by SKU' : 'Open orders'
  const scope = accountName.value || repName.value
  return scope ? `${what} — ${scope}` : `${what} — all accounts`
})
const exportFilenamePrefix = computed(() => {
  const base = view.value === 'sku' ? 'open-orders-by-sku' : 'open-orders'
  if (filters.account) return `${base}-${filters.account}`
  return filters.rep ? `${base}-rep-${repName.value}` : base
})
const exportDescription = computed(() =>
  view.value === 'sku'
    ? 'Open order lines (Released, Firmed or Hold) added up by SKU for each account. Open $ ' +
      'is the unshipped value — owed on open orders, not yet invoiced revenue.'
    : 'Every open order line (Released, Firmed or Hold). Open $ is the unshipped value of the ' +
      'line — owed on open orders, not yet invoiced revenue.',
)
const exportDetails = computed(() => [
  loadedAt.value && `Data loaded ${exportTimestamp(new Date(loadedAt.value))}`,
  ordersThrough.value && `Orders through ${shortDate(ordersThrough.value)}`,
  filters.account && `Account: ${accountLabel.value}`,
  filters.rep && `Rep: ${repName.value}`,
  filters.productLine && `Product line: ${filters.productLine}`,
  filters.status && `Status: ${filters.status}`,
  filters.pastWantOnly && 'Only lines past their want date',
  filters.hideRma ? 'RMA / warranty lines hidden' : 'Includes RMA / warranty lines',
  filters.hideNonPart ? 'Discount / credit lines hidden' : 'Includes discount / credit lines',
])

const accountLink = (r: { customer_key: string }) => ({
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
/** The By order / By SKU switch: the same look as Shipments' Lines / Packlists. */
const segment = (on: boolean) => (on ? 'bg-ink text-canvas' : 'text-muted')
</script>

<template>
  <div class="space-y-4">
    <!-- A database without 20261027090600 (a preview, or before the
         migration runs): say the list is coming, not that it broke. -->
    <AppCard v-if="query.unavailable.value" title="Open orders">
      <p class="text-ink-2 text-[15px] leading-relaxed">
        The open-orders list isn't switched on yet. It appears here once the
        next portal update reaches the database. Until then, every account's
        open orders are on its page.
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
      <div>
        <!-- One list, two cuts. The switch leads the page so it reads as
             "how do you want these lines laid out", not as another filter. -->
        <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
          <div
            class="border-line flex border"
            role="group"
            aria-label="Show open orders by order or by SKU"
          >
            <button
              type="button"
              class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
              :class="segment(view === 'order')"
              :aria-pressed="view === 'order'"
              @click="view = 'order'"
            >
              By order
            </button>
            <button
              type="button"
              class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
              :class="segment(view === 'sku')"
              :aria-pressed="view === 'sku'"
              @click="view = 'sku'"
            >
              By SKU
            </button>
          </div>
          <p class="text-muted min-w-0 text-[13px] leading-relaxed">
            <template v-if="view === 'sku'">
              The same open lines, added up by SKU for each account.
            </template>
            <template v-else>Every open order line, under its account and order.</template>
          </p>
        </div>

        <!-- Who and what, shared by both cuts: the filters cut the lines,
             and the by-SKU rows are added up from what is left. -->
        <div class="mt-3 space-y-2">
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
        </div>

        <!-- The tiles follow every filter and the search box, and read the
             same in either cut: pick an account and they become that
             account's open-order summary. -->
        <div class="border-line bg-line mt-4 grid grid-cols-2 gap-px border md:grid-cols-4">
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

        <p v-if="hiddenRma.lines" class="text-muted mt-2 text-[13px] leading-relaxed">
          {{ count(hiddenRma.lines) }} RMA/warranty
          {{ hiddenRma.lines === 1 ? 'line' : 'lines' }} ({{ count(hiddenRma.qty) }}
          {{ hiddenRma.qty === 1 ? 'unit' : 'units' }})
          {{ hiddenRma.lines === 1 ? 'is' : 'are' }} hidden.
          <button
            type="button"
            class="text-ink-2 underline decoration-dotted underline-offset-2"
            @click="filters.hideRma = false"
          >
            Show them
          </button>
        </p>

        <BookListCard
          v-if="view === 'order'"
          key="order"
          class="mt-4"
          title="Open order lines"
          :rows="filtered"
          :columns="lineColumns"
          :export-columns="lineExport"
          :export-filename="exportFilenamePrefix"
          :export-title="exportTitle"
          :export-description="exportDescription"
          :export-details="exportDetails"
          :totals="lineTotalsFor"
          :get-row-id="(r: OpenOrderLine) => `${r.order_id}:${r.line_num}`"
          search-placeholder="PO, order #, part or description…"
          min-width="68rem"
          @rows-change="visibleLines = $event"
        >
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

        <!-- By SKU: biggest dollars first, as the Backlog tab opened. -->
        <BookListCard
          v-else
          key="sku"
          class="mt-4"
          title="Open orders by SKU"
          :rows="bySku"
          :columns="skuColumns"
          :export-columns="skuExport"
          :export-filename="exportFilenamePrefix"
          :export-title="exportTitle"
          :export-description="exportDescription"
          :export-details="exportDetails"
          :totals="skuTotalsFor"
          :get-row-id="(r: OpenSkuRow) => r.key"
          :initial-sorting="[{ id: 'backlog_amount', desc: true }]"
          search-placeholder="Account, SKU, family or chambering…"
          min-width="64rem"
          @rows-change="visibleSkus = $event"
        >
          <template #cell-account="{ row }">
            <RouterLink
              :to="accountLink(row)"
              class="text-ink block font-semibold whitespace-nowrap underline-offset-2 hover:underline"
            >
              {{ row.customer_id || row.customer_key }}
            </RouterLink>
            <span class="text-muted block max-w-[12rem] truncate text-xs">
              {{ row.customer_name }}
            </span>
          </template>
          <template #cell-rep="{ row }">
            <span class="text-ink-2 block whitespace-nowrap">
              {{ row.assigned_sales_rep_name || row.assigned_sales_rep_id || '—' }}
            </span>
          </template>
          <!-- The picture lives on the website — the family page. -->
          <template #cell-part_id="{ row }">
            <span class="whitespace-nowrap">
              <ProductLink :family="row.product_family">{{ row.part_id || '—' }}</ProductLink>
            </span>
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
          <template #cell-earliest_desired_ship_date="{ row }">
            <span
              class="whitespace-nowrap tabular-nums"
              :class="row.is_past_want ? 'text-accent font-semibold' : ''"
            >
              {{ isoDate(row.earliest_desired_ship_date) }}
            </span>
          </template>
          <template #cell-earliest_promise_date="{ row }">
            <span
              class="whitespace-nowrap tabular-nums"
              :class="row.is_past_promise ? 'text-accent font-semibold' : ''"
            >
              {{ isoDate(row.earliest_promise_date) }}
            </span>
          </template>

          <template #card="{ row }">
            <div class="px-1">
              <div class="flex items-baseline justify-between gap-3">
                <RouterLink :to="accountLink(row)" class="text-ink min-w-0 truncate text-[15px] font-semibold">
                  {{ row.customer_name || row.customer_id || row.customer_key }}
                </RouterLink>
                <span class="text-ink shrink-0 text-[15px] font-semibold tabular-nums">
                  {{ money(row.backlog_amount) }}
                </span>
              </div>
              <p v-if="multiRep" class="text-muted text-xs">
                {{ row.assigned_sales_rep_name || row.assigned_sales_rep_id || 'No rep assigned' }}
              </p>
              <p class="text-ink-2 mt-0.5 truncate text-sm">
                {{ row.part_id || '—' }} · {{ row.part_description }}
              </p>
              <p class="text-muted mt-0.5 text-xs tabular-nums">
                {{ count(row.backlog_qty) }} open on {{ count(row.order_count) }}
                {{ row.order_count === 1 ? 'order' : 'orders' }} · want
                <span :class="row.is_past_want ? 'text-accent font-semibold' : ''">
                  {{ isoDate(row.earliest_desired_ship_date) }}</span>
                · promise
                <span :class="row.is_past_promise ? 'text-accent font-semibold' : ''">
                  {{ isoDate(row.earliest_promise_date) }}</span>
                <ProductLink :family="row.product_family" fallback="none"> · see it</ProductLink>
              </p>
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
      </div>
    </AsyncState>
  </div>
</template>
