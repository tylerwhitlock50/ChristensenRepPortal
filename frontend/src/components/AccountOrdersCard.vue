<script setup lang="ts">
import { computed, ref, toRef, watch } from 'vue'
import { format, isThisYear, parseISO } from 'date-fns'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCollapsibleCard from '@/components/ui/AppCollapsibleCard.vue'
import AppModal from '@/components/ui/AppModal.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { cardHintState } from '@/components/ui/cardHint'
import { count, humanize, money, shortDate } from '@/lib/format'
import { trackingList, upsTrackUrl } from '@/lib/tracking'
import { shippedValue } from '@/lib/shippedValue'
import {
  useAccountOrderHeaders,
  useAccountOrderLines,
  useAccountShipmentHeaders,
  useAccountShipmentLines,
  useAccountSummary,
} from '@/composables/useAccountMetrics'

/**
 * Recent ORDERS and recent SHIPMENTS at header grain — one row per order /
 * per packlist. Tapping a row opens a modal with that document's lines. A rep
 * looking for "order 51234" scans 20 orders, not 20 arbitrary lines of three
 * orders.
 *
 * ── Stacked and collapsed, not side by side ───────────────────────────────
 * These were two columns on a laptop, which meant each 34rem table lived in a
 * half-width box and scrolled sideways inside its own column while the page
 * scrolled down past 40 rows nobody asked for. Full width kills the sideways
 * scroll (the tables now fit outright at laptop width), and collapsing by
 * default keeps the cards two headers tall until a rep actually wants the
 * history. The header hint carries the count and the latest date, so the
 * decision to open is made without opening.
 *
 * ── Paged and searchable, not capped at 20 ───────────────────────────────
 * 018 wrote `where rn <= 20` into the header views, so an account's 21st
 * order was unreachable by any query — a rep chasing something from last
 * season simply could not get to it. 035 uncapped the views; these lists now
 * page 20 at a time with "Load older…", and both carry a filter box.
 *
 * The filter runs over what is LOADED, not over the server. That is a real
 * limitation and the row counts under each list state it outright ("12 of 40
 * loaded · more available") so a filtered miss can never be misread as "this
 * account never had that order". Searching the whole history regardless of
 * account is what the Lookup page is for.
 *
 * The modal's line queries fetch one document by its primary key and only run
 * while a modal is open.
 *
 * ── Nothing is fetched until a card opens ─────────────────────────────────
 * Both cards arrive collapsed, and most account opens never expand them, so
 * each list's query waits for its card's first open. Until then the hints
 * come from v_account_summary, which the page has already read ("latest
 * Sep 12 · 2 open"). Orders can arrive sooner: the "Before you call" card
 * reads the newest page for its last-order line, and this card shows those
 * rows without a second request.
 *
 * Tracking numbers: everything ships UPS, so the number links straight to
 * UPS tracking. The header shows one number per packlist (line-level
 * tracking_number, header waybill fallback — migration 032); the drill-in
 * modal shows each line's own number, which is what differs on a
 * multi-package shipment.
 *
 * ── Phones get lists, not tables ──────────────────────────────────────────
 * Every table here carries a min-width (34rem for the headers, 30rem for the
 * lines) so its columns stay readable. On a 390px phone that means the rep
 * reads two of five columns and has to drag the rest into view — inside the
 * modal too, where the sheet is already the width of the screen. Scrolling
 * sideways was contained, but containment is not the same as usable.
 *
 * So below `sm` each table has a stacked-list twin showing the same fields in
 * reading order, and the table is `hidden sm:block`. This is the pattern
 * DataGrid already uses for the admin grids (its `card` slot) — same reason,
 * same breakpoint. The markup is duplicated rather than generated because the
 * four documents want genuinely different summaries, and a component that
 * could render all four would be harder to read than both versions are.
 *
 * Horizontal scroll still lives on the table wrapper only, for the tablet and
 * desktop widths where the table survives. The page itself never scrolls
 * sideways (html has overflow-x: hidden in style.css).
 */
const props = defineProps<{ customerKey: string }>()
const emit = defineEmits<{
  /** The rep closed an order's drill-in — the page drops a ?order= that
      named it. */
  'order-closed': [orderId: string]
}>()

const customerKey = toRef(props, 'customerKey')

const ordersCardRef = ref<InstanceType<typeof AppCollapsibleCard> | null>(null)
const shipmentsCardRef = ref<InstanceType<typeof AppCollapsibleCard> | null>(null)

/* Latched on first open: closing the card again keeps its rows rather than
   dropping them and showing the summary hint. Re-armed per account — the
   router reuses this component across /accounts/:customerKey. */
const ordersWanted = ref(false)
const shipmentsWanted = ref(false)
watch(
  () => ordersCardRef.value?.isOpen,
  (open) => {
    if (open) ordersWanted.value = true
  },
)
watch(
  () => shipmentsCardRef.value?.isOpen,
  (open) => {
    if (open) shipmentsWanted.value = true
  },
)
watch(customerKey, () => {
  ordersWanted.value = !!ordersCardRef.value?.isOpen
  shipmentsWanted.value = !!shipmentsCardRef.value?.isOpen
  // An open drill-in belongs to the account it was opened on.
  openOrderId.value = null
  openPacklistId.value = null
})

const ordersQuery = useAccountOrderHeaders(customerKey, { enabled: ordersWanted })
const shipmentsQuery = useAccountShipmentHeaders(customerKey, {
  enabled: shipmentsWanted,
})
/** Already read by the page (vue-query dedupes it) — the collapsed hints. */
const summary = useAccountSummary(customerKey)

/* Paged as of migration 035 — flatten the pages the same way AccountsView
   flattens its book. */
const allOrders = computed(
  () => ordersQuery.data.value?.pages.flat() ?? [],
)
const allShipments = computed(
  () => shipmentsQuery.data.value?.pages.flat() ?? [],
)

/* ---- search ------------------------------------------------------------
   "Did my PO land?" is the question this card exists to answer, and until
   035 it could not: the PO number was not in the payload and only the newest
   20 orders were reachable at all. The filter runs over what has been loaded;
   "Load more" extends that, and the row counts below always say which of the
   two the rep is looking at so a filtered list can never be mistaken for the
   whole history.
------------------------------------------------------------------------- */
const orderSearch = ref('')
const shipmentSearch = ref('')

function matches(haystack: (string | null)[], term: string): boolean {
  const t = term.trim().toLowerCase()
  if (!t) return true
  return haystack.some((v) => (v ?? '').toLowerCase().includes(t))
}

const orders = computed(() =>
  allOrders.value.filter((o) =>
    matches([o.order_id, o.customer_po_number, o.order_status_desc], orderSearch.value),
  ),
)
const shipments = computed(() =>
  allShipments.value.filter((s) =>
    matches([s.packlist_id, s.order_ids, s.tracking_number], shipmentSearch.value),
  ),
)

/**
 * What the collapsed headers say. Both lists come back newest first, so row 0
 * is the latest — "12 · latest Jul 9" tells a rep whether there is anything
 * recent in here before they spend a tap on it. A full first page with more
 * behind it reads "20+", not "20": the count is what is loaded.
 */
function withLatest(rows: { length: number }, latest: string | null, more: boolean): string {
  const n = `${rows.length}${more ? '+' : ''}`
  return latest ? `${n} · latest ${shortDate(latest)}` : n
}

/** "Oct 8", or "Mar 2024" when it was not this year: a collapsed header has
    room for a short hint only — the title truncates first. */
function hintDate(value: string): string {
  const d = parseISO(value)
  return format(d, isThisYear(d) ? 'MMM d' : 'MMM yyyy')
}

/* Before the list loads: the summary's dates and open count, or nothing —
   never "···" for a read that is not running. */
const ordersSummaryHint = computed(() => {
  const s = summary.data.value
  if (!s?.last_order_date) return s ? 'None' : undefined
  const open = s.open_order_count > 0 ? ` · ${count(s.open_order_count)} open` : ''
  return `latest ${hintDate(s.last_order_date)}${open}`
})
/* The summary has no ship date, and the last INVOICE date (which the
   Performance card already shows) read as "nothing shipped since" until the
   card was opened and said otherwise. Only "None" is safe to say early. */
const shipmentsSummaryHint = computed(() => {
  const s = summary.data.value
  if (!s) return undefined
  return s.last_invoice_date ? undefined : 'None'
})

/** Not fetched yet, and not failed: the summary speaks for the list. */
function notLoaded(q: {
  data: { value: unknown }
  isFetching: { value: boolean }
  error: { value: unknown }
}): boolean {
  return q.data.value === undefined && !q.isFetching.value && !q.error.value
}

const ordersHint = computed(() =>
  notLoaded(ordersQuery)
    ? ordersSummaryHint.value
    : (cardHintState(ordersQuery, allOrders.value.length) ??
      withLatest(
        allOrders.value,
        allOrders.value[0]?.order_date ?? null,
        ordersQuery.hasNextPage.value,
      )),
)
const shipmentsHint = computed(() =>
  notLoaded(shipmentsQuery)
    ? shipmentsSummaryHint.value
    : (cardHintState(shipmentsQuery, allShipments.value.length) ??
      withLatest(
        allShipments.value,
        allShipments.value[0]?.ship_date ?? null,
        shipmentsQuery.hasNextPage.value,
      )),
)

/* ---- drill-in modals ---------------------------------------------------- */

const openOrderId = ref<string | null>(null)
const openPacklistId = ref<string | null>(null)

const orderLinesQuery = useAccountOrderLines(customerKey, openOrderId)
const shipmentLinesQuery = useAccountShipmentLines(customerKey, openPacklistId)

const orderLines = computed(() => orderLinesQuery.data.value ?? [])
const shipmentLines = computed(() => shipmentLinesQuery.data.value ?? [])

/* Resolved against the UNFILTERED lists: clearing the search box while a
   modal is open must not empty the modal's header. */
const openOrderRow = computed(
  () => allOrders.value.find((o) => o.order_id === openOrderId.value) ?? null,
)

/**
 * The drill-in's subtitle. From the header row when the order is among the
 * loaded pages; otherwise — a deep link to an older order — from its own
 * lines, which carry the order date (035).
 */
function lineCount(n: number): string {
  return `${count(n)} line${n === 1 ? '' : 's'}`
}
const openOrderSubtitle = computed(() => {
  const o = openOrderRow.value
  if (o) {
    return `Ordered ${shortDate(o.order_date)} · ${lineCount(o.line_count)} · ${money(o.bookings)}`
  }
  const lines = orderLines.value
  if (!lines.length) return undefined
  const value = lines.reduce((sum, l) => sum + (l.bookings ?? 0), 0)
  return `Ordered ${shortDate(lines[0].order_date)} · ${lineCount(lines.length)} · ${money(value)}`
})
const openShipment = computed(
  () => allShipments.value.find((s) => s.packlist_id === openPacklistId.value) ?? null,
)

/* ---- programmatic entry points ------------------------------------------
   The page deep-links here: "Last order" and "what's owed" in the Before
   you call card, the Performance card's last invoice, and ?order=<id> from
   Lookup and the activity feed. The parent scrolls; these open the right
   card, and openOrder also pops the drill-in for one order. It needs only
   the id — the lines are fetched by primary key, so an order older than
   the loaded pages opens just the same.
------------------------------------------------------------------------- */
function expandOrders() {
  ordersCardRef.value?.expand()
}
function expandShipments() {
  shipmentsCardRef.value?.expand()
}
function openOrder(orderId: string) {
  expandOrders()
  if (orderId) openOrderId.value = orderId
}
function closeOrder() {
  const id = openOrderId.value
  openOrderId.value = null
  if (id) emit('order-closed', id)
}

/** The shipments card is halfway down this component — "Last invoice →"
    needs to land on IT, not on the orders card above it. */
function scrollToShipments() {
  const el = shipmentsCardRef.value?.$el as HTMLElement | undefined
  el?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

defineExpose({ expandOrders, expandShipments, openOrder, scrollToShipments })
</script>

<template>
  <!-- grid-cols-1 matters: it makes the track minmax(0,1fr), so the cards can
       shrink below the tables' min-w and the overflow-x-auto wrappers scroll
       instead of the whole card getting clipped at the phone edge. -->
  <div class="grid grid-cols-1 gap-4">
    <AppCollapsibleCard ref="ordersCardRef" title="Recent orders" :hint="ordersHint">
      <AsyncState
        :loading="ordersQuery.isPending.value"
        :error="ordersQuery.error.value"
        :has-data="ordersQuery.data.value !== undefined"
        :updated-at="ordersQuery.dataUpdatedAt.value"
        :empty="!ordersQuery.isPending.value && !allOrders.length"
        empty-title="No orders"
        empty-body="Nothing has been ordered on this account yet."
        :rows="3"
        @retry="ordersQuery.refetch()"
      >
        <label class="mb-3 block">
          <span class="sr-only">Search orders</span>
          <input
            v-model="orderSearch"
            type="search"
            placeholder="Order # or the dealer's PO #"
            autocapitalize="none"
            spellcheck="false"
            class="field"
          />
        </label>
        <!-- A search with no match keeps the box (and the footer's Load
             older orders): it is about what is loaded, not the account. -->
        <p v-if="orderSearch.trim() && !orders.length" class="text-muted py-2 text-[15px]" role="status">
          No loaded order matches "{{ orderSearch.trim() }}".
          <template v-if="ordersQuery.hasNextPage.value">Load older orders below to look further back.</template>
        </p>

        <!-- Phone: one tappable row per order. The whole row is the button —
             a nested link would be invalid inside it, and everything a rep
             might tap through to is in the drill-in a tap away. -->
        <ul class="divide-line divide-y sm:hidden">
          <li v-for="row in orders" :key="row.order_id">
            <button
              type="button"
              class="tap-target hover:bg-canvas flex w-full flex-col items-start gap-1 py-2.5 text-left"
              :aria-label="`Order ${row.order_id}, ${shortDate(row.order_date)} — show lines`"
              @click="openOrderId = row.order_id"
            >
              <span class="flex w-full items-baseline justify-between gap-3">
                <span class="text-ink truncate font-semibold tabular-nums">
                  {{ row.order_id }}
                </span>
                <span class="u-display text-ink shrink-0 text-lg tabular-nums">
                  {{ money(row.bookings) }}
                </span>
              </span>
              <span class="text-muted text-[13px] tabular-nums">
                {{ shortDate(row.order_date) }} · {{ count(row.line_count) }} lines ·
                {{ count(row.order_qty) }} pcs
              </span>
              <!-- The dealer's own paperwork number — the thing they quote
                   down the phone, and the whole point of migration 035. -->
              <span
                v-if="row.customer_po_number"
                class="text-ink-2 text-[13px] break-words"
              >
                Their PO {{ row.customer_po_number }}
              </span>
              <AppBadge v-if="row.open_line_count > 0" tone="high">
                Open {{ count(row.backlog_qty) }}
              </AppBadge>
              <span v-else class="text-muted text-[13px]">
                {{ humanize(row.order_state ?? row.order_status_desc) }}
              </span>
            </button>
          </li>
        </ul>

        <div v-if="orders.length" class="hidden overflow-x-auto sm:block">
          <table class="w-full min-w-[34rem] border-collapse text-sm">
            <caption class="sr-only">
              Orders for this account, newest first — select one for its lines
            </caption>
            <thead>
              <tr class="border-line border-b">
                <th scope="col" class="u-label py-2 pr-3 text-left">Ordered</th>
                <th scope="col" class="u-label py-2 pr-3 text-left">Their PO</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Lines</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Qty</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Value</th>
                <th scope="col" class="u-label py-2 text-left">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="row in orders"
                :key="row.order_id"
                class="border-line/60 hover:bg-canvas cursor-pointer border-b last:border-0"
                @click="openOrderId = row.order_id"
              >
                <td class="py-2.5 pr-3 whitespace-nowrap tabular-nums">
                  {{ shortDate(row.order_date) }}
                  <!-- The button is the keyboard/screen-reader way in; the row
                       click is the same action for a thumb. -->
                  <button
                    type="button"
                    class="text-ink block text-xs font-medium underline decoration-dotted underline-offset-2"
                    @click.stop="openOrderId = row.order_id"
                  >
                    {{ row.order_id }}
                  </button>
                </td>
                <td class="text-ink-2 py-2.5 pr-3">
                  {{ row.customer_po_number ?? '—' }}
                </td>
                <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                  {{ count(row.line_count) }}
                </td>
                <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                  {{ count(row.order_qty) }}
                </td>
                <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                  {{ money(row.bookings) }}
                </td>
                <td class="py-2.5 whitespace-nowrap">
                  <AppBadge v-if="row.open_line_count > 0" tone="high">
                    Open {{ count(row.backlog_qty) }}
                  </AppBadge>
                  <span v-else class="text-muted">
                    {{ humanize(row.order_state ?? row.order_status_desc) }}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <!-- Always says how much of the history is on screen. A paged list
             that just stops is indistinguishable from a complete one, and
             with a filter applied it is worse: "no results" could mean "not
             loaded yet". Same contract as AccountsView's footer. -->
        <div class="border-line mt-3 border-t pt-3 text-center">
          <p class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase tabular-nums">
            <template v-if="orderSearch.trim()">
              {{ count(orders.length) }} of {{ count(allOrders.length) }} loaded
            </template>
            <template v-else>{{ count(allOrders.length) }} loaded</template>
            <template v-if="ordersQuery.hasNextPage.value"> · more available</template>
          </p>
          <AppButton
            v-if="ordersQuery.hasNextPage.value"
            variant="secondary"
            class="mt-2"
            :loading="ordersQuery.isFetchingNextPage.value"
            @click="ordersQuery.fetchNextPage()"
          >
            Load older orders
          </AppButton>
        </div>
      </AsyncState>
    </AppCollapsibleCard>

    <AppCollapsibleCard
      ref="shipmentsCardRef"
      class="scroll-mt-16"
      title="Recent shipments"
      :hint="shipmentsHint"
    >
      <AsyncState
        :loading="shipmentsQuery.isPending.value"
        :error="shipmentsQuery.error.value"
        :has-data="shipmentsQuery.data.value !== undefined"
        :updated-at="shipmentsQuery.dataUpdatedAt.value"
        :empty="!shipmentsQuery.isPending.value && !allShipments.length"
        empty-title="No shipments"
        empty-body="Nothing has shipped to this account yet."
        :rows="3"
        @retry="shipmentsQuery.refetch()"
      >
        <label class="mb-3 block">
          <span class="sr-only">Search shipments</span>
          <input
            v-model="shipmentSearch"
            type="search"
            placeholder="Packlist #, order #, or tracking #"
            autocapitalize="none"
            spellcheck="false"
            class="field"
          />
        </label>
        <p v-if="shipmentSearch.trim() && !shipments.length" class="text-muted py-2 text-[15px]" role="status">
          No loaded shipment matches "{{ shipmentSearch.trim() }}".
          <template v-if="shipmentsQuery.hasNextPage.value">Load older shipments below to look further back.</template>
        </p>

        <!-- Phone: same shape as the orders list. The tracking link is NOT
             here — an <a> inside the row button would be invalid interactive
             nesting, and the drill-in renders it as a proper link one tap
             away, next to ship-via and the order numbers. -->
        <ul class="divide-line divide-y sm:hidden">
          <li v-for="row in shipments" :key="row.packlist_id">
            <button
              type="button"
              class="tap-target hover:bg-canvas flex w-full flex-col items-start gap-1 py-2.5 text-left"
              :aria-label="`Packlist ${row.packlist_id}, ${shortDate(row.ship_date)} — show lines`"
              @click="openPacklistId = row.packlist_id"
            >
              <span class="flex w-full items-baseline justify-between gap-3">
                <span class="text-ink truncate font-semibold tabular-nums">
                  {{ row.packlist_id }}
                </span>
                <!-- Packlist value, never "revenue": shipping runs ahead of
                     invoicing (lib/shippedValue.ts). -->
                <span class="shrink-0 text-right">
                  <span class="u-display text-ink block text-lg tabular-nums">
                    {{ money(shippedValue(row)) }}
                  </span>
                  <span class="font-label text-muted block text-[11px] font-semibold tracking-[0.12em] uppercase">
                    Shipped value
                  </span>
                </span>
              </span>
              <span class="text-muted text-[13px] tabular-nums">
                {{ shortDate(row.ship_date) }} · {{ count(row.shipped_qty) }} pcs
                <template v-if="row.tracking_number"> · tracked</template>
              </span>
              <AppBadge v-if="row.actual_delivery_date" tone="good">
                Delivered {{ shortDate(row.actual_delivery_date) }}
              </AppBadge>
              <span v-else class="text-muted text-[13px]">
                {{ humanize(row.shipment_state ?? row.shipper_status_desc) }}
              </span>
            </button>
          </li>
        </ul>

        <div v-if="shipments.length" class="hidden overflow-x-auto sm:block">
          <table class="w-full min-w-[34rem] border-collapse text-sm">
            <caption class="sr-only">
              The 20 most recent shipments for this account — select one for its
              lines
            </caption>
            <thead>
              <tr class="border-line border-b">
                <th scope="col" class="u-label py-2 pr-3 text-left">Shipped</th>
                <th scope="col" class="u-label py-2 pr-3 text-left">Tracking</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Qty</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Shipped value</th>
                <th scope="col" class="u-label py-2 text-left">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="row in shipments"
                :key="row.packlist_id"
                class="border-line/60 hover:bg-canvas cursor-pointer border-b last:border-0"
                @click="openPacklistId = row.packlist_id"
              >
                <td class="py-2.5 pr-3 whitespace-nowrap tabular-nums">
                  {{ shortDate(row.ship_date) }}
                  <button
                    type="button"
                    class="text-ink block text-xs font-medium underline decoration-dotted underline-offset-2"
                    @click.stop="openPacklistId = row.packlist_id"
                  >
                    {{ row.packlist_id }}
                  </button>
                </td>
                <td class="py-2.5 pr-3 whitespace-nowrap">
                  <!-- Everything ships UPS — the number goes straight to UPS
                       tracking. @click.stop so following it doesn't also open
                       the modal underneath. -->
                  <a
                    v-if="row.tracking_number"
                    :href="upsTrackUrl(row.tracking_number)"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="text-ink underline decoration-dotted underline-offset-2"
                    :title="`Track ${row.tracking_number} on ups.com`"
                    @click.stop
                  >
                    {{ row.tracking_number }}
                  </a>
                  <span v-else class="text-muted">—</span>
                </td>
                <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                  {{ count(row.shipped_qty) }}
                </td>
                <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                  {{ money(shippedValue(row)) }}
                </td>
                <td class="py-2.5 whitespace-nowrap">
                  <AppBadge v-if="row.actual_delivery_date" tone="good">
                    Delivered {{ shortDate(row.actual_delivery_date) }}
                  </AppBadge>
                  <span v-else class="text-muted">
                    {{ humanize(row.shipment_state ?? row.shipper_status_desc) }}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="border-line mt-3 border-t pt-3 text-center">
          <p class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase tabular-nums">
            <template v-if="shipmentSearch.trim()">
              {{ count(shipments.length) }} of {{ count(allShipments.length) }} loaded
            </template>
            <template v-else>{{ count(allShipments.length) }} loaded</template>
            <template v-if="shipmentsQuery.hasNextPage.value">
              · more available
            </template>
          </p>
          <AppButton
            v-if="shipmentsQuery.hasNextPage.value"
            variant="secondary"
            class="mt-2"
            :loading="shipmentsQuery.isFetchingNextPage.value"
            @click="shipmentsQuery.fetchNextPage()"
          >
            Load older shipments
          </AppButton>
        </div>
      </AsyncState>
    </AppCollapsibleCard>
  </div>

  <!-- Order drill-in -->
  <AppModal
    :open="!!openOrderId"
    :title="`Order ${openOrderId ?? ''}`"
    :subtitle="openOrderSubtitle"
    @update:open="closeOrder"
  >
    <!-- flex-wrap, not an inline span: at phone width "next promise" and its
         date were breaking across lines with the badge, so the phrase read as
         two unrelated fragments. -->
    <div
      v-if="openOrderRow && openOrderRow.open_line_count > 0"
      class="mb-3 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm"
    >
      <AppBadge tone="high">
        {{ count(openOrderRow.open_line_count) }} open —
        {{ count(openOrderRow.backlog_qty) }} pcs / {{ money(openOrderRow.backlog_amount) }}
      </AppBadge>
      <span v-if="openOrderRow.next_promise_date" class="text-muted whitespace-nowrap">
        next promise {{ shortDate(openOrderRow.next_promise_date) }}
      </span>
    </div>
    <AsyncState
      :loading="orderLinesQuery.isPending.value"
      :error="orderLinesQuery.error.value"
      :has-data="orderLinesQuery.data.value !== undefined"
      :updated-at="orderLinesQuery.dataUpdatedAt.value"
      :empty="!orderLinesQuery.isPending.value && !orderLines.length"
      empty-title="No lines"
      :rows="3"
      @retry="orderLinesQuery.refetch()"
    >
      <!-- Phone: the part first, then what was ordered against it. The
           description wraps here instead of truncating at 16rem — in a sheet
           this narrow the truncation was hiding most of the part name, and
           there is nothing to the right competing for the space. -->
      <ul class="divide-line divide-y sm:hidden">
        <li v-for="line in orderLines" :key="line.line_num" class="py-2.5">
          <p class="text-ink font-medium">
            {{ line.part_id ?? line.part_key ?? '—' }}
          </p>
          <p v-if="line.part_description" class="text-muted text-[13px]">
            {{ line.part_description }}
          </p>
          <p class="text-ink-2 mt-1 text-[13px] tabular-nums">
            {{ count(line.order_qty) }} pcs · {{ money(line.bookings) }}
            <template v-if="line.promise_date">
              · promise {{ shortDate(line.promise_date) }}
            </template>
          </p>
          <p class="mt-1">
            <AppBadge v-if="line.is_backlog_line" tone="high">
              Open {{ count(line.backlog_qty) }}
            </AppBadge>
            <span v-else class="text-muted text-[13px]">
              {{ humanize(line.line_status_desc) }}
            </span>
          </p>
          <!-- This line's own parcels (20261013150000), as on Find. -->
          <p
            v-if="trackingList(line.tracking_numbers).length"
            class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1"
          >
            <span class="u-label text-muted">Tracking</span>
            <a
              v-for="t in trackingList(line.tracking_numbers)"
              :key="t"
              :href="upsTrackUrl(t)"
              target="_blank"
              rel="noopener noreferrer"
              class="text-ink inline-flex min-h-11 items-center text-sm break-all underline decoration-dotted underline-offset-2"
              :title="`Track ${t} on ups.com`"
            >
              {{ t }}
            </a>
          </p>
        </li>
      </ul>

      <div class="hidden overflow-x-auto sm:block">
        <table class="w-full min-w-[30rem] border-collapse text-sm">
          <thead>
            <tr class="border-line border-b">
              <th scope="col" class="u-label py-2 pr-3 text-left">Part</th>
              <th scope="col" class="u-label py-2 pr-3 text-right">Qty</th>
              <th scope="col" class="u-label py-2 pr-3 text-right">Value</th>
              <th scope="col" class="u-label py-2 pr-3 text-left">Promise</th>
              <th scope="col" class="u-label py-2 text-left">Status</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="line in orderLines"
              :key="line.line_num"
              class="border-line/60 border-b last:border-0"
            >
              <td class="py-2.5 pr-3">
                <span class="text-ink block font-medium">
                  {{ line.part_id ?? line.part_key ?? '—' }}
                </span>
                <span
                  v-if="line.part_description"
                  class="text-muted block max-w-[16rem] truncate text-xs"
                  :title="line.part_description"
                >
                  {{ line.part_description }}
                </span>
              </td>
              <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                {{ count(line.order_qty) }}
              </td>
              <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                {{ money(line.bookings) }}
              </td>
              <td class="py-2.5 pr-3 whitespace-nowrap tabular-nums">
                {{ shortDate(line.promise_date) }}
              </td>
              <td class="py-2.5 whitespace-nowrap">
                <AppBadge v-if="line.is_backlog_line" tone="high">
                  Open {{ count(line.backlog_qty) }}
                </AppBadge>
                <span v-else class="text-muted">
                  {{ humanize(line.line_status_desc) }}
                </span>
                <a
                  v-for="t in trackingList(line.tracking_numbers)"
                  :key="t"
                  :href="upsTrackUrl(t)"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-ink block text-xs underline decoration-dotted underline-offset-2"
                  :title="`Track ${t} on ups.com`"
                >
                  {{ t }}
                </a>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </AsyncState>
  </AppModal>

  <!-- Shipment drill-in -->
  <AppModal
    :open="!!openPacklistId"
    :title="`Packlist ${openPacklistId ?? ''}`"
    :subtitle="
      openShipment
        ? `Shipped ${shortDate(openShipment.ship_date)} · ${count(openShipment.line_count)} lines · ${money(shippedValue(openShipment))} shipped value`
        : undefined
    "
    @update:open="openPacklistId = null"
  >
    <div v-if="openShipment" class="mb-3 space-y-1 text-sm">
      <p v-if="openShipment.tracking_number">
        <span class="u-label mr-2">Tracking</span>
        <a
          :href="upsTrackUrl(openShipment.tracking_number)"
          target="_blank"
          rel="noopener noreferrer"
          class="text-ink underline decoration-dotted underline-offset-2"
        >
          {{ openShipment.tracking_number }}
        </a>
      </p>
      <p v-if="openShipment.ship_via">
        <span class="u-label mr-2">Ship via</span>{{ openShipment.ship_via }}
      </p>
      <p v-if="openShipment.order_ids">
        <span class="u-label mr-2">Orders</span>{{ openShipment.order_ids }}
      </p>
      <p v-if="openShipment.actual_delivery_date">
        <AppBadge tone="good">
          Delivered {{ shortDate(openShipment.actual_delivery_date) }}
        </AppBadge>
      </p>
    </div>
    <AsyncState
      :loading="shipmentLinesQuery.isPending.value"
      :error="shipmentLinesQuery.error.value"
      :has-data="shipmentLinesQuery.data.value !== undefined"
      :updated-at="shipmentLinesQuery.dataUpdatedAt.value"
      :empty="!shipmentLinesQuery.isPending.value && !shipmentLines.length"
      empty-title="No lines"
      :rows="3"
      @retry="shipmentLinesQuery.refetch()"
    >
      <!-- Phone: same shape as the order lines. -->
      <ul class="divide-line divide-y sm:hidden">
        <li v-for="line in shipmentLines" :key="line.line_num" class="py-2.5">
          <p class="text-ink font-medium">
            {{ line.part_id ?? line.part_key ?? '—' }}
          </p>
          <p v-if="line.part_description" class="text-muted text-[13px]">
            {{ line.part_description }}
          </p>
          <p class="text-ink-2 mt-1 text-[13px] tabular-nums">
            {{ count(line.shipped_qty) }} pcs · {{ money(shippedValue(line)) }} shipped value
            <template v-if="line.order_id"> · order {{ line.order_id }}</template>
          </p>
        </li>
      </ul>

      <div class="hidden overflow-x-auto sm:block">
        <table class="w-full min-w-[30rem] border-collapse text-sm">
          <thead>
            <tr class="border-line border-b">
              <th scope="col" class="u-label py-2 pr-3 text-left">Part</th>
              <th scope="col" class="u-label py-2 pr-3 text-right">Qty</th>
              <th scope="col" class="u-label py-2 pr-3 text-right">Shipped value</th>
              <th scope="col" class="u-label py-2 pr-3 text-left">Order</th>
              <th scope="col" class="u-label py-2 text-left">Tracking</th>
            </tr>
          </thead>
          <tbody>
            <tr
              v-for="line in shipmentLines"
              :key="line.line_num"
              class="border-line/60 border-b last:border-0"
            >
              <td class="py-2.5 pr-3">
                <span class="text-ink block font-medium">
                  {{ line.part_id ?? line.part_key ?? '—' }}
                </span>
                <span
                  v-if="line.part_description"
                  class="text-muted block max-w-[16rem] truncate text-xs"
                  :title="line.part_description"
                >
                  {{ line.part_description }}
                </span>
              </td>
              <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                {{ count(line.shipped_qty) }}
              </td>
              <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                {{ money(shippedValue(line)) }}
              </td>
              <td class="py-2.5 pr-3 whitespace-nowrap">
                {{ line.order_id ?? '—' }}
              </td>
              <td class="py-2.5 whitespace-nowrap">
                <a
                  v-if="line.tracking_number"
                  :href="upsTrackUrl(line.tracking_number)"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-ink underline decoration-dotted underline-offset-2"
                  :title="`Track ${line.tracking_number} on ups.com`"
                >
                  {{ line.tracking_number }}
                </a>
                <span v-else class="text-muted">—</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </AsyncState>
  </AppModal>
</template>
