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
 * UPS tracking. The ERP feed currently only carries waybills on old
 * shipments (see 018's header) — the column renders whenever data exists.
 *
 * Horizontal scroll lives on the table wrapper only. The page itself never
 * scrolls sideways (html has overflow-x: hidden in style.css); a table that
 * shoves the whole layout off-screen is the fastest way to make a rep put
 * the phone away.
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
        <div class="overflow-x-auto">
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
        <div class="overflow-x-auto">
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
    <p v-if="openOrder && openOrder.open_line_count > 0" class="mb-3 text-sm">
      <AppBadge tone="high">
        {{ count(openOrder.open_line_count) }} open —
        {{ count(openOrder.backlog_qty) }} pcs / {{ money(openOrder.backlog_amount) }}
      </AppBadge>
      <span v-if="openOrder.next_promise_date" class="text-muted ml-2">
        next promise {{ shortDate(openOrder.next_promise_date) }}
      </span>
    </p>
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
      <div class="overflow-x-auto">
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
      <div class="overflow-x-auto">
        <table class="w-full min-w-[30rem] border-collapse text-sm">
          <thead>
            <tr class="border-line border-b">
              <th scope="col" class="u-label py-2 pr-3 text-left">Part</th>
              <th scope="col" class="u-label py-2 pr-3 text-right">Qty</th>
              <th scope="col" class="u-label py-2 pr-3 text-right">Value</th>
              <th scope="col" class="u-label py-2 text-left">Order</th>
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
              <td class="py-2.5 whitespace-nowrap">
                {{ line.order_id ?? '—' }}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </AsyncState>
  </AppModal>
</template>
