<script setup lang="ts">
import { computed, ref, toRef } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppModal from '@/components/ui/AppModal.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count, humanize, money, shortDate } from '@/lib/format'
import {
  useAccountOrderHeaders,
  useAccountOrderLines,
  useAccountShipmentHeaders,
  useAccountShipmentLines,
} from '@/composables/useAccountMetrics'

/**
 * Recent ORDERS and recent SHIPMENTS at header grain — one row per order /
 * per packlist — side by side on a laptop, stacked on a phone. Tapping a row
 * opens a modal with that document's lines. A rep looking for "order 51234"
 * scans 20 orders, not 20 arbitrary lines of three orders.
 *
 * Both lists come back capped at 20 headers per account by
 * public.v_account_recent_order_headers / _shipment_headers (migration 018);
 * the modal's line queries fetch one document by its primary key and only
 * run while a modal is open.
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

const customerKey = toRef(props, 'customerKey')
const ordersQuery = useAccountOrderHeaders(customerKey)
const shipmentsQuery = useAccountShipmentHeaders(customerKey)

const orders = computed(() => ordersQuery.data.value ?? [])
const shipments = computed(() => shipmentsQuery.data.value ?? [])

/* ---- drill-in modals ---------------------------------------------------- */

const openOrderId = ref<string | null>(null)
const openPacklistId = ref<string | null>(null)

const orderLinesQuery = useAccountOrderLines(customerKey, openOrderId)
const shipmentLinesQuery = useAccountShipmentLines(customerKey, openPacklistId)

const orderLines = computed(() => orderLinesQuery.data.value ?? [])
const shipmentLines = computed(() => shipmentLinesQuery.data.value ?? [])

const openOrder = computed(
  () => orders.value.find((o) => o.order_id === openOrderId.value) ?? null,
)
const openShipment = computed(
  () => shipments.value.find((s) => s.packlist_id === openPacklistId.value) ?? null,
)

/** ups.com's tracking page accepts the number straight in the query string. */
function upsTrackUrl(trackingNumber: string): string {
  return `https://www.ups.com/track?tracknum=${encodeURIComponent(trackingNumber)}`
}
</script>

<template>
  <!-- grid-cols-1 matters: it makes the track minmax(0,1fr), so the cards can
       shrink below the tables' min-w and the overflow-x-auto wrappers scroll
       instead of the whole card getting clipped at the phone edge. -->
  <div class="grid grid-cols-1 gap-4 lg:grid-cols-2">
    <AppCard title="Recent orders" hint="Last 20 orders">
      <AsyncState
        :loading="ordersQuery.isPending.value"
        :error="ordersQuery.error.value"
        :empty="
          !ordersQuery.isPending.value && !ordersQuery.error.value && !orders.length
        "
        empty-title="No orders"
        empty-body="Nothing has been ordered on this account yet."
        :rows="3"
        @retry="ordersQuery.refetch()"
      >
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
              <AppBadge v-if="row.open_line_count > 0" tone="high">
                Open {{ count(row.backlog_qty) }}
              </AppBadge>
              <span v-else class="text-muted text-[13px]">
                {{ humanize(row.order_state ?? row.order_status_desc) }}
              </span>
            </button>
          </li>
        </ul>

        <div class="hidden overflow-x-auto sm:block">
          <table class="w-full min-w-[34rem] border-collapse text-sm">
            <caption class="sr-only">
              The 20 most recent orders for this account — select one for its lines
            </caption>
            <thead>
              <tr class="border-line border-b">
                <th scope="col" class="u-label py-2 pr-3 text-left">Ordered</th>
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
      </AsyncState>
    </AppCard>

    <AppCard title="Recent shipments" hint="Last 20 shipments">
      <AsyncState
        :loading="shipmentsQuery.isPending.value"
        :error="shipmentsQuery.error.value"
        :empty="
          !shipmentsQuery.isPending.value &&
          !shipmentsQuery.error.value &&
          !shipments.length
        "
        empty-title="No shipments"
        empty-body="Nothing has shipped to this account yet."
        :rows="3"
        @retry="shipmentsQuery.refetch()"
      >
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
                <span class="u-display text-ink shrink-0 text-lg tabular-nums">
                  {{ money(row.shipped_revenue) }}
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

        <div class="hidden overflow-x-auto sm:block">
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
                <th scope="col" class="u-label py-2 pr-3 text-right">Value</th>
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
                  {{ money(row.shipped_revenue) }}
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
      </AsyncState>
    </AppCard>
  </div>

  <!-- Order drill-in -->
  <AppModal
    :open="!!openOrderId"
    :title="`Order ${openOrderId ?? ''}`"
    :subtitle="
      openOrder
        ? `Ordered ${shortDate(openOrder.order_date)} · ${count(openOrder.line_count)} lines · ${money(openOrder.bookings)}`
        : undefined
    "
    @update:open="openOrderId = null"
  >
    <!-- flex-wrap, not an inline span: at phone width "next promise" and its
         date were breaking across lines with the badge, so the phrase read as
         two unrelated fragments. -->
    <div
      v-if="openOrder && openOrder.open_line_count > 0"
      class="mb-3 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm"
    >
      <AppBadge tone="high">
        {{ count(openOrder.open_line_count) }} open —
        {{ count(openOrder.backlog_qty) }} pcs / {{ money(openOrder.backlog_amount) }}
      </AppBadge>
      <span v-if="openOrder.next_promise_date" class="text-muted whitespace-nowrap">
        next promise {{ shortDate(openOrder.next_promise_date) }}
      </span>
    </div>
    <AsyncState
      :loading="orderLinesQuery.isPending.value"
      :error="orderLinesQuery.error.value"
      :empty="
        !orderLinesQuery.isPending.value &&
        !orderLinesQuery.error.value &&
        !orderLines.length
      "
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
        ? `Shipped ${shortDate(openShipment.ship_date)} · ${count(openShipment.line_count)} lines · ${money(openShipment.shipped_revenue)}`
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
      :empty="
        !shipmentLinesQuery.isPending.value &&
        !shipmentLinesQuery.error.value &&
        !shipmentLines.length
      "
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
            {{ count(line.shipped_qty) }} pcs · {{ money(line.shipped_revenue) }}
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
              <th scope="col" class="u-label py-2 pr-3 text-right">Value</th>
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
                {{ money(line.shipped_revenue) }}
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
