<script setup lang="ts">
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import {
  hasProductLine,
  pivotSkuYears,
  useSkuSalesByAccount,
  useTerritorySkuSales,
  type SkuPivotRow,
} from '@/composables/useIntel'
import { useDataFreshness } from '@/composables/useDataFreshness'
import { useTerritoryAccounts } from '@/composables/useOverview'
import TerritoryAccountPicker from './TerritoryAccountPicker.vue'
import DataGrid from '@/components/DataGrid.vue'
import SkuProspectsSheet from '@/components/SkuProspectsSheet.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import ProductLink from '@/components/ui/ProductLink.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import type { ExportColumn } from '@/lib/xlsx'
import { exportTimestamp } from '@/lib/download'
import { count, money, shortDate } from '@/lib/format'

/**
 * Sales by SKU — what was bought, by SKU, this year vs history. Two modes:
 * "My territory" (the whole book rolled up per SKU) and "By account"
 * (one account's SKU history, picker fed from the same territory rows the
 * Overview already cached — read only once "By account" is chosen).
 *
 * Last year is the WHOLE calendar year (agg_sku_year has no months), so it
 * is labelled "all of" and never set against this year as a percentage: in
 * October a flat territory read "−20% vs last year" because ten months were
 * being compared with twelve.
 *
 * "My territory" rolls the book up per SKU, which hides who bought it — so
 * each row opens the dealers who did (the In stock list's sheet, in its
 * buyers mode), with their rep when the book spans several, as a
 * principal's does.
 */
const mode = ref<'territory' | 'account'>('territory')
const accountKey = ref('')
const search = ref('')

const territory = useTerritorySkuSales()
const account = useSkuSalesByAccount(accountKey)

const active = computed(() => (mode.value === 'territory' ? territory : account))
const yearNow = new Date().getFullYear()

/** "By account" with nothing chosen yet — a prompt, not an empty result. */
const nothingPicked = computed(() => mode.value === 'account' && !accountKey.value)

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

/* "Product line" (dim_part.product_code, 20261027090500) beside Family —
   what Tableau calls Family. Only once the views carry it. */
const showProductLine = computed(() => hasProductLine(pivoted.value))

/* ---- who bought it --------------------------------------------------------- */
const buyersPart = ref<SkuPivotRow | null>(null)
const buyersOpen = ref(false)
function showBuyers(row: SkuPivotRow) {
  buyersPart.value = row
  buyersOpen.value = true
}

const columns = computed<ColumnDef<SkuPivotRow, any>[]>(() => [
  { id: 'part_id', header: 'SKU', accessorKey: 'part_id', meta: { filter: 'text' } },
  { id: 'part_description', header: 'Description', accessorKey: 'part_description' },
  {
    id: 'product_family',
    header: 'Family',
    accessorKey: 'product_family',
    meta: { filter: 'select' },
  },
  ...(showProductLine.value
    ? [
        {
          id: 'product_code',
          header: 'Product line',
          accessorKey: 'product_code',
          meta: { filter: 'select' },
        } as ColumnDef<SkuPivotRow, any>,
      ]
    : []),
  {
    id: 'chambering',
    header: 'Chambering',
    accessorKey: 'chambering',
    meta: { filter: 'select' },
  },
  { id: 'qtyThisYear', header: `Qty ${yearNow} so far`, accessorKey: 'qtyThisYear' },
  { id: 'revenueThisYear', header: `Rev ${yearNow} so far`, accessorKey: 'revenueThisYear' },
  { id: 'qtyLastYear', header: `Qty all ${yearNow - 1}`, accessorKey: 'qtyLastYear' },
  { id: 'revenueLastYear', header: `Rev all ${yearNow - 1}`, accessorKey: 'revenueLastYear' },
  { id: 'lastInvoiceDate', header: 'Last invoice', accessorKey: 'lastInvoiceDate' },
  // One account already IS the buyer; the territory roll-up is where the
  // question comes from.
  ...(mode.value === 'territory'
    ? [{ id: 'buyers', header: 'Buyers', accessorFn: () => '', enableSorting: false }]
    : []),
])

/** What's on screen is what exports — DataGrid emits its visible rows. */
const visible = ref<SkuPivotRow[]>([])
/** The grid's search box + column filters, in words (DataGrid filtersChange). */
const gridFilters = ref<string[]>([])
/* The grid unmounts while a new account loads, for "By account" with no
   pick, and for an empty scope, and `visible` keeps the last rows it
   emitted. Nothing on screen then, so nothing to download. */
const exportRows = computed(() => (pivoted.value.length ? visible.value : []))
const exportColumns = computed<ExportColumn<SkuPivotRow>[]>(() => [
  { key: 'part_id', header: 'SKU', type: 'text' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  ...(showProductLine.value
    ? [{ key: 'product_code', header: 'Product line' } as ExportColumn<SkuPivotRow>]
    : []),
  { key: 'chambering', header: 'Chambering' },
  { key: 'upc', header: 'UPC', type: 'text' },
  // The grid's wording, with "Rev" spelled out.
  { key: 'qtyThisYear', header: `Qty ${yearNow} so far`, type: 'number' },
  { key: 'revenueThisYear', header: `Revenue ${yearNow} so far`, type: 'money' },
  { key: 'qtyLastYear', header: `Qty all ${yearNow - 1}`, type: 'number' },
  { key: 'revenueLastYear', header: `Revenue all ${yearNow - 1}`, type: 'money' },
  { key: 'lastInvoiceDate', header: 'Last invoice', type: 'date' },
])

/* The account's NAME for the sheet's title. The picker reads the same
   cached book; gated on "By account" so My territory still costs nothing. */
const book = useTerritoryAccounts(() => mode.value === 'account')
const accountName = computed(() => {
  const a = (book.data.value ?? []).find((x) => x.customer_key === accountKey.value)
  return a?.customer_name || accountKey.value
})

/* What the downloaded sheet says about itself: whose sales, how fresh, the
   year caveat, and every grid filter that narrowed it. */
const { loadedAt, dataThrough } = useDataFreshness()
const exportTitle = computed(() =>
  mode.value === 'territory'
    ? 'Sales by SKU — my territory'
    : `Sales by SKU — ${accountName.value}`,
)
const exportFilenamePrefix = computed(() =>
  mode.value === 'territory' ? 'sku-sales-territory' : `sku-sales-${accountKey.value}`,
)
const EXPORT_DESCRIPTION =
  `Invoiced units and revenue by SKU. ${yearNow} is year to date; ${yearNow - 1} is ` +
  'the whole calendar year, not the same period.'
const exportDetails = computed(() => [
  dataThrough.value && `Invoiced through ${shortDate(dataThrough.value)}`,
  loadedAt.value && `Data loaded ${exportTimestamp(new Date(loadedAt.value))}`,
  mode.value === 'territory'
    ? 'Scope: my territory (every account in the book, rolled up per SKU)'
    : `Account: ${accountName.value}`,
  ...gridFilters.value,
])
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

      <TerritoryAccountPicker
        v-if="mode === 'account'"
        v-model="accountKey"
        placeholder="Choose an account…"
        class="order-last w-full sm:order-none sm:w-auto sm:min-w-0 sm:max-w-sm sm:flex-1"
      />

      <ExportMenu
        class="ml-auto"
        :rows="exportRows"
        :columns="exportColumns"
        :title="exportTitle"
        :filename="exportFilenamePrefix"
        :description="EXPORT_DESCRIPTION"
        :details="exportDetails"
        sheet-name="Sales by SKU"
      />
    </div>

    <!--
      The empty arm was missing, so a scope with no SKU history fell through
      to tiles reading $0 / 0 / 0 above DataGrid's generic "Nothing to show."
      Gated on `nothingPicked` so the pick-an-account prompt below still owns
      that state rather than being replaced by an empty-title.
    -->
    <AsyncState
      :loading="active.isPending.value && !nothingPicked"
      :error="active.error.value"
      :has-data="active.data.value !== undefined"
      :updated-at="active.dataUpdatedAt.value"
      :empty="!active.isPending.value && !nothingPicked && pivoted.length === 0"
      :empty-title="
        mode === 'account' ? 'Nothing bought yet' : 'No SKU history'
      "
      :empty-body="
        mode === 'account'
          ? 'This account has no invoiced lines in the last four years.'
          : 'Nothing has been invoiced in your territory in the last four years. If that seems wrong, ask your admin to check the data load.'
      "
      :rows="4"
      @retry="active.refetch()"
    >
      <p v-if="nothingPicked" class="text-muted text-[15px]">
        Pick an account to see what they bought, by SKU, this year and the
        three before it.
      </p>

      <template v-else>
        <!-- So-what tiles first; the grid is the detail. -->
        <div class="border-line bg-line grid grid-cols-2 gap-px border md:grid-cols-4">
          <StatTile
            :label="`Revenue ${yearNow}`"
            :value="money(totals.rev)"
            :sub="`So far · all of ${yearNow - 1}: ${money(totals.revLY)}`"
          />
          <StatTile :label="`Units ${yearNow}`" :value="count(totals.qty)" sub="So far" />
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
            @filters-change="gridFilters = $event"
          >
            <!-- The picture lives on the website: the family page has the
                 photography the ERP doesn't. -->
            <template #cell-part_id="{ row }">
              <ProductLink :family="row.product_family">{{ row.part_id }}</ProductLink>
            </template>
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
            <template #cell-buyers="{ row }">
              <button
                type="button"
                class="tap-target text-ink font-semibold whitespace-nowrap underline-offset-2 hover:underline"
                @click="showBuyers(row)"
              >
                Who bought it
              </button>
            </template>
            <template #card="{ row }">
              <div class="px-1">
                <p class="text-ink text-[15px] font-semibold">
                  {{ row.part_id }} · {{ row.part_description }}
                </p>
                <p class="text-muted mt-0.5 text-xs">
                  {{ row.product_family }} · {{ row.chambering }}
                  <ProductLink :family="row.product_family" fallback="none">
                    · see it
                  </ProductLink>
                </p>
                <p class="text-ink-2 mt-1 text-sm tabular-nums">
                  {{ yearNow }} so far: {{ count(row.qtyThisYear) }} units,
                  {{ money(row.revenueThisYear) }} · all of {{ yearNow - 1 }}:
                  {{ count(row.qtyLastYear) }} units,
                  {{ money(row.revenueLastYear) }}
                </p>
                <AppButton
                  v-if="mode === 'territory'"
                  variant="ghost"
                  class="mt-1 -ml-3"
                  @click="showBuyers(row)"
                >
                  Who bought it
                </AppButton>
              </div>
            </template>
          </DataGrid>
        </AppCard>
      </template>
    </AsyncState>

    <SkuProspectsSheet v-model:open="buyersOpen" :part="buyersPart" purpose="buyers" />
  </div>
</template>
