<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import type { ColumnDef } from '@tanstack/vue-table'
import { useAtsList, type AtsRow } from '@/composables/useIntel'
import { isViewMissing, useTerritoryAccounts } from '@/composables/useOverview'
import { useAccountSkuGaps } from '@/composables/useAccountGaps'
import { useReorderCandidates } from '@/composables/useReorderCandidates'
import AccountPicker from '@/components/AccountPicker.vue'
import DataGrid from '@/components/DataGrid.vue'
import SkuProspectsSheet from '@/components/SkuProspectsSheet.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import ProductLink from '@/components/ui/ProductLink.vue'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import { count } from '@/lib/format'
import { useFeatureFlags } from '@/composables/useAppSettings'

/**
 * ATS — what the company can actually sell right now, straight from the
 * ERP's certified calculation (erp.fact_available_to_sell, landed from
 * bi.vw_FactAvailableToSell). On hand is the SHIPPING warehouse net of
 * staging; committed = allocated open orders; backlog = all open demand;
 * ATS is signed, so negatives mean oversold. The upstream model does not
 * (yet) certify inbound supply or a next-available date.
 *
 * Reps see it as "In stock": "ATS" is the ERP's word, not theirs. Routes and
 * names keep 'ats'.
 */
/* ?q= seeds the filter: the header search's product results land here
   already narrowed to that SKU. Following it while mounted covers a second
   header-search pick made from this page. Typing does not touch the URL. */
const route = useRoute()
const routeTerm = () => (typeof route.query.q === 'string' ? route.query.q : '')
const search = ref(routeTerm())
watch(
  () => route.query.q,
  () => {
    search.value = routeTerm()
  },
)
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

/**
 * Two questions about one dealer, one toggle: what could they START
 * carrying ("New to them" — the SKU-gap RPC's never-bought rows, which is
 * all this page used to show), and what do they already buy that we can
 * ship ("Reorders" — report_reorder_candidates, the account card's first
 * list; on a database without it, the gap RPC's bought-before rows).
 */
const gapMode = ref<'new' | 'reorders'>('new')

const reordersQuery = useReorderCandidates(
  () => (gapMode.value === 'reorders' ? gapAccountKey.value : ''),
  50,
)
const reordersFromGaps = computed(
  () => gapMode.value === 'reorders' && reordersQuery.unavailable.value,
)
// 100, not the card's 25: this page lays the suggestions over the whole
// catalog, and a rep scrolling a "gaps" list of 25 reads it as everything.
const gapsQuery = useAccountSkuGaps(
  computed(() => (gapMode.value === 'new' || reordersFromGaps.value ? gapAccountKey.value : '')),
  100,
)
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
 * The RPC returns a RANKED SHORTLIST of what this dealer does not carry —
 * guns only, in stock, bought by 4+ dealers, top N by breadth — not the
 * complement of their history, so the filtered grid is "suggestions", never
 * "everything they lack", and the copy below says so. On error or while
 * loading, fall through to the whole catalog rather than showing an empty
 * grid — a rep who picked an account and got nothing would read that as
 * "no stock", not "still loading".
 */
const gapKeys = computed(() => {
  if (!gapAccountKey.value) return null
  if (gapMode.value === 'reorders' && !reordersFromGaps.value) {
    if (reordersQuery.data.value === undefined) return null
    return new Set(reordersQuery.rows.value.map((r) => r.part_key))
  }
  const rowsOut = gapsQuery.data.value
  if (!rowsOut) return null
  const wantBought = gapMode.value === 'reorders'
  return new Set(rowsOut.filter((r) => r.bought_before === wantBought).map((r) => r.part_key))
})

/** Reorders that are due now get a badge in the grid. */
const dueKeys = computed(
  () =>
    new Set(
      gapMode.value === 'reorders' && gapAccountKey.value
        ? reordersQuery.rows.value.filter((r) => r.is_due).map((r) => r.part_key)
        : [],
    ),
)

/** The query behind the current account filter, for its status line. */
const filterQuery = computed(() =>
  gapMode.value === 'reorders' && !reordersFromGaps.value ? reordersQuery : gapsQuery,
)

/* "Who should I call?" — one sheet for the page, opened from any row. */
const prospectPart = ref<AtsRow | null>(null)
const prospectsOpen = ref(false)
function whoToCall(row: AtsRow) {
  prospectPart.value = row
  prospectsOpen.value = true
}

const rows = computed(() =>
  gapKeys.value
    ? allRows.value.filter((r) => gapKeys.value!.has(r.part_key))
    : allRows.value,
)

/**
 * Default-on per rep feedback: the list is "what can I sell", and a page of
 * zeros isn't that. The tiles keep counting the full set so "Out of stock"
 * stays truthful — and tapping that tile flips this off to show them.
 */
const inStockOnly = ref(true)

const displayRows = computed(() =>
  inStockOnly.value ? rows.value.filter((r) => r.ats_qty > 0) : rows.value,
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

/* "Order now" — a door into the order writer with the SKU carried along.
   Exists only while the orders feature is on; the /orders routes redirect
   away when it's off, so a dead link would be worse than none. */
const flags = useFeatureFlags()

const columns = computed<ColumnDef<AtsRow, any>[]>(() => [
  { id: 'part_id', header: 'SKU', accessorKey: 'part_id', meta: { filter: 'text' } },
  { id: 'part_description', header: 'Description', accessorKey: 'part_description' },
  {
    id: 'product_family',
    header: 'Family',
    accessorKey: 'product_family',
    meta: { filter: 'select' },
  },
  {
    id: 'chambering',
    header: 'Chambering',
    accessorKey: 'chambering',
    meta: { filter: 'select' },
  },
  // "Available", the word every other screen uses for this number (Before
  // you call, Ready to ship, the header search) — beside "On hand", "In
  // stock" read as a second name for the same thing.
  { id: 'ats_qty', header: 'Available', accessorKey: 'ats_qty' },
  { id: 'on_hand_qty', header: 'On hand', accessorKey: 'on_hand_qty' },
  { id: 'committed_qty', header: 'Committed', accessorKey: 'committed_qty' },
  { id: 'backlog_qty', header: 'Backlog', accessorKey: 'backlog_qty' },
  { id: 'who', header: '', enableSorting: false } as ColumnDef<AtsRow, any>,
  ...(flags.orders.value
    ? [{ id: 'order', header: '', enableSorting: false } as ColumnDef<AtsRow, any>]
    : []),
])

/** "18 available", "None available", or "Oversold by 3" when below zero. */
function availableText(qty: number): string {
  if (qty < 0) return `Oversold by ${count(-qty)}`
  if (qty === 0) return 'None available'
  return `${count(qty)} available`
}

const visible = ref<AtsRow[]>([])
const csvColumns: CsvColumn<AtsRow>[] = [
  { key: 'part_id', header: 'SKU' },
  { key: 'part_description', header: 'Description' },
  { key: 'product_family', header: 'Family' },
  { key: 'chambering', header: 'Chambering' },
  { key: 'barrel_length', header: 'Barrel' },
  { key: 'upc', header: 'UPC' },
  { key: 'ats_qty', header: 'Available qty' },
  { key: 'on_hand_qty', header: 'On hand' },
  { key: 'committed_qty', header: 'Committed' },
  { key: 'backlog_qty', header: 'Backlog' },
]
</script>

<template>
  <div class="space-y-4">
    <!-- The feed is a separate deployment step (ERP view + ETL entry); say
         so instead of erroring while it's on the way. -->
    <AppCard v-if="feedMissing" title="In stock">
      <p class="text-ink-2 text-[15px] leading-relaxed">
        The in-stock feed hasn't landed yet. Once the ERP-side view
        (<code>bi.vw_FactAvailableToSell</code>) ships and the nightly load
        runs, this page fills in on its own.
      </p>
    </AppCard>

    <AsyncState
      v-else
      :loading="query.isPending.value"
      :error="query.error.value"
      :has-data="query.data.value !== undefined"
      :updated-at="query.dataUpdatedAt.value"
      :empty="!query.isPending.value && rows.length === 0"
      empty-title="No stock data yet"
      empty-body="The table exists but the nightly ERP load hasn't filled it. Check back after the next load."
      :rows="4"
      @retry="query.refetch()"
    >
      <div class="border-line bg-line grid grid-cols-3 gap-px border">
        <StatTile label="Sellable SKUs" :value="count(totals.sellable)" />
        <StatTile label="Units available" :value="count(totals.units)" />
        <!-- The out-of-stock rows are hidden by default (toggle below), so
             this tile is also the way to see them. -->
        <button
          type="button"
          class="block h-full w-full text-left"
          :title="inStockOnly ? 'Show the out-of-stock rows' : 'Hide the out-of-stock rows'"
          @click="inStockOnly = !inStockOnly"
        >
          <StatTile
            class="h-full transition-colors hover:bg-canvas"
            label="Out of stock"
            :value="count(totals.out)"
            :tone="totals.out > 0 ? 'alert' : 'default'"
          />
        </button>
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
            @click="exportCsv(gapAccountKey ? `ats-${gapMode === 'new' ? 'gaps' : 'reorders'}-${gapAccountKey}` : 'ats-list', visible, csvColumns)"
          >
            Export CSV
          </AppButton>
        </template>

        <div class="border-line space-y-2 border-b p-3">
          <div class="flex flex-wrap items-center gap-2">
            <button
              type="button"
              class="tap-target font-label inline-flex items-center px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
              :class="
                inStockOnly
                  ? 'bg-ink text-canvas'
                  : 'border-line-2 text-ink-2 border bg-transparent'
              "
              :aria-pressed="inStockOnly"
              @click="inStockOnly = !inStockOnly"
            >
              In stock only
            </button>
            <span v-if="!inStockOnly" class="text-muted text-[13px]">
              showing {{ count(totals.out) }} out-of-stock too
            </span>
          </div>
          <AccountPicker
            v-model="gapAccountKey"
            :accounts="accounts"
            placeholder="Filter for one account…"
          />
          <div
            v-if="gapAccountKey"
            class="border-line flex w-fit border"
            role="group"
            aria-label="What to show for this account"
          >
            <button
              type="button"
              class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
              :class="gapMode === 'new' ? 'bg-ink text-canvas' : 'text-muted'"
              :aria-pressed="gapMode === 'new'"
              @click="gapMode = 'new'"
            >
              New to them
            </button>
            <button
              type="button"
              class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
              :class="gapMode === 'reorders' ? 'bg-ink text-canvas' : 'text-muted'"
              :aria-pressed="gapMode === 'reorders'"
              @click="gapMode = 'reorders'"
            >
              Reorders
            </button>
          </div>
          <p v-if="gapAccountKey" class="text-muted text-[13px]">
            <template v-if="filterQuery.isPending.value">
              {{ gapMode === 'new' ? "Working out what they don't carry…" : 'Finding what they reorder…' }}
            </template>
            <template v-else-if="filterQuery.error.value">
              Couldn't load that account's history — showing the whole catalog.
            </template>
            <template v-else-if="gapMode === 'new'">
              Top {{ count(rows.length) }} suggestions for {{ gapAccountName }}
              — in stock, carried by 4+ dealers, never bought here. Not a full
              list of what they don't carry.
            </template>
            <template v-else>
              {{ count(rows.length) }} in-stock {{ rows.length === 1 ? 'item' : 'items' }}
              {{ gapAccountName }} has bought before<template v-if="dueKeys.size">,
              {{ count(dueKeys.size) }} due for a reorder</template>.
            </template>
          </p>
        </div>

        <DataGrid
          :columns="columns"
          :data="displayRows"
          :initial-sorting="[{ id: 'ats_qty', desc: true }]"
          searchable
          search-placeholder="Filter by SKU, description, chambering…"
          v-model:global-filter="search"
          :get-row-id="(r: AtsRow) => r.part_key"
          class="p-3"
          @rows-change="visible = $event"
        >
          <!-- The picture lives on the website — the family page. -->
          <template #cell-part_id="{ row }">
            <ProductLink :family="row.product_family">{{ row.part_id }}</ProductLink>
            <AppBadge v-if="dueKeys.has(row.part_key)" tone="good" class="ml-2">Due</AppBadge>
          </template>
          <template #cell-who="{ row }">
            <button
              type="button"
              class="btn-ghost text-[13px] whitespace-nowrap"
              @click="whoToCall(row)"
            >
              Who should I call?
            </button>
          </template>
          <!-- The grid can be empty because of the in-stock toggle, not the
               data — say so, or a searched-for out-of-stock SKU reads as
               "doesn't exist". -->
          <template #empty>
            <p class="text-muted py-10 text-center text-[15px]">
              <template v-if="inStockOnly">
                Nothing in stock matches. Turn off "In stock only" to include
                out-of-stock SKUs.
              </template>
              <template v-else>Nothing to show.</template>
            </p>
          </template>
          <template #cell-order="{ row }">
            <RouterLink
              :to="{ name: 'orders-new', query: { sku: row.part_id ?? undefined } }"
              class="btn-ghost text-[13px] whitespace-nowrap"
            >
              Order now
            </RouterLink>
          </template>
          <template #cell-ats_qty="{ row }">
            <span
              class="font-semibold tabular-nums"
              :class="row.ats_qty <= 0 ? 'text-accent' : 'text-ink'"
            >
              {{ row.ats_qty < 0 ? availableText(row.ats_qty) : count(row.ats_qty) }}
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
              <div class="flex items-start justify-between gap-3">
                <p class="text-ink min-w-0 text-[15px] font-semibold">
                  {{ row.part_id }} · {{ row.part_description }}
                </p>
                <AppBadge v-if="dueKeys.has(row.part_key)" tone="good" class="shrink-0">Due</AppBadge>
              </div>
              <p class="text-muted mt-0.5 text-xs">
                {{ row.product_family }} · {{ row.chambering }}
              </p>
              <p class="mt-1 text-sm tabular-nums" :class="row.ats_qty <= 0 ? 'text-accent' : 'text-ink-2'">
                {{ availableText(row.ats_qty) }} · {{ count(row.on_hand_qty) }} on hand
                <ProductLink :family="row.product_family" fallback="none">
                  · see it
                </ProductLink>
              </p>
              <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1">
                <button
                  type="button"
                  class="btn-ghost text-[13px]"
                  @click="whoToCall(row)"
                >
                  Who should I call?
                </button>
                <RouterLink
                  v-if="flags.orders.value"
                  :to="{ name: 'orders-new', query: { sku: row.part_id ?? undefined } }"
                  class="text-ink text-sm font-semibold underline decoration-dotted underline-offset-2"
                >
                  Order now
                </RouterLink>
              </div>
            </div>
          </template>
        </DataGrid>
      </AppCard>
    </AsyncState>

    <SkuProspectsSheet v-model:open="prospectsOpen" :part="prospectPart" />
  </div>
</template>
