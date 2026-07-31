<script setup lang="ts">
import { computed, toRef } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count, humanize, money, shortDate } from '@/lib/format'
import {
  useAccountRecentOrders,
  useAccountRecentShipments,
} from '@/composables/useAccountMetrics'

/**
 * Recent order lines and recent shipment lines, side by side on a laptop and
 * stacked on a phone.
 *
 * Both lists come back capped at 20 rows by
 * public.v_account_recent_orders / _recent_shipments — the ERP fact tables
 * are half a million rows each and this is a glance, not a report.
 *
 * Horizontal scroll lives on the table wrapper only. The page itself never
 * scrolls sideways (html has overflow-x: hidden in style.css); a table that
 * shoves the whole layout off-screen is the fastest way to make a rep put
 * the phone away.
 */
const props = defineProps<{ customerKey: string }>()

const customerKey = toRef(props, 'customerKey')
const ordersQuery = useAccountRecentOrders(customerKey)
const shipmentsQuery = useAccountRecentShipments(customerKey)

const orders = computed(() => ordersQuery.data.value ?? [])
const shipments = computed(() => shipmentsQuery.data.value ?? [])
</script>

<template>
  <div class="grid gap-4 lg:grid-cols-2">
    <AppCard title="Recent orders" hint="Last 20 lines">
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
              The 20 most recent order lines for this account
            </caption>
            <thead>
              <tr class="border-line border-b">
                <th scope="col" class="u-label py-2 pr-3 text-left">Ordered</th>
                <th scope="col" class="u-label py-2 pr-3 text-left">Part</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Qty</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Value</th>
                <th scope="col" class="u-label py-2 text-left">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="row in orders"
                :key="`${row.order_id}-${row.line_num}`"
                class="border-line/60 border-b last:border-0"
              >
                <td class="py-2.5 pr-3 whitespace-nowrap tabular-nums">
                  {{ shortDate(row.order_date) }}
                  <span class="text-muted block text-xs">{{ row.order_id }}</span>
                </td>
                <td class="py-2.5 pr-3">
                  <span class="text-ink block font-medium">
                    {{ row.part_id ?? row.part_key ?? '—' }}
                  </span>
                  <span
                    v-if="row.part_description"
                    class="text-muted block max-w-[14rem] truncate text-xs"
                    :title="row.part_description"
                  >
                    {{ row.part_description }}
                  </span>
                </td>
                <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                  {{ count(row.order_qty) }}
                </td>
                <td class="py-2.5 pr-3 text-right whitespace-nowrap tabular-nums">
                  {{ money(row.bookings) }}
                </td>
                <td class="py-2.5 whitespace-nowrap">
                  <AppBadge v-if="row.is_backlog_line" tone="warn">
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

    <AppCard title="Recent shipments" hint="Last 20 lines">
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
              The 20 most recent shipment lines for this account
            </caption>
            <thead>
              <tr class="border-line border-b">
                <th scope="col" class="u-label py-2 pr-3 text-left">Shipped</th>
                <th scope="col" class="u-label py-2 pr-3 text-left">Part</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Qty</th>
                <th scope="col" class="u-label py-2 pr-3 text-right">Value</th>
                <th scope="col" class="u-label py-2 text-left">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="row in shipments"
                :key="`${row.packlist_id}-${row.line_num}`"
                class="border-line/60 border-b last:border-0"
              >
                <td class="py-2.5 pr-3 whitespace-nowrap tabular-nums">
                  {{ shortDate(row.ship_date) }}
                  <span class="text-muted block text-xs">{{ row.packlist_id }}</span>
                </td>
                <td class="py-2.5 pr-3">
                  <span class="text-ink block font-medium">
                    {{ row.part_id ?? row.part_key ?? '—' }}
                  </span>
                  <span
                    v-if="row.part_description"
                    class="text-muted block max-w-[14rem] truncate text-xs"
                    :title="row.part_description"
                  >
                    {{ row.part_description }}
                  </span>
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
</template>
