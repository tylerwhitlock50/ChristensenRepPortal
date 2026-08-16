<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import OrderStatusBadge from '@/components/orders/OrderStatusBadge.vue'
import { useMyOrders } from '@/composables/useOrders'
import { money, shortDate } from '@/lib/format'
import { ORDER_STATUS_LABELS, ORDER_STATUSES, type OrderStatus } from '@/types/domain'

/**
 * Every order the caller can read — a rep's own (plus the agency's for a
 * principal), everything for an admin. The feedback loop lives here: a rep
 * watches submitted → entered (with the ERP number) → verified without
 * having to call the office.
 */
const ordersQuery = useMyOrders()

const statusFilter = ref<OrderStatus | 'all'>('all')

const filtered = computed(() => {
  const rows = ordersQuery.data.value ?? []
  if (statusFilter.value === 'all') return rows
  return rows.filter((o) => o.status === statusFilter.value)
})

const filterOptions = computed(() => {
  const rows = ordersQuery.data.value ?? []
  const counts = new Map<OrderStatus, number>()
  for (const o of rows) counts.set(o.status, (counts.get(o.status) ?? 0) + 1)
  return ORDER_STATUSES.filter((s) => (counts.get(s) ?? 0) > 0).map((s) => ({
    value: s,
    label: `${ORDER_STATUS_LABELS[s]} (${counts.get(s)})`,
  }))
})
</script>

<template>
  <div class="space-y-4">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <label class="flex items-center gap-2">
        <span class="u-label text-ink">Status</span>
        <select
          v-model="statusFilter"
          class="border-line text-ink min-h-12 border px-3 text-[15px]"
        >
          <option value="all">All</option>
          <option v-for="opt in filterOptions" :key="opt.value" :value="opt.value">
            {{ opt.label }}
          </option>
        </select>
      </label>
      <RouterLink :to="{ name: 'orders-new' }">
        <AppButton variant="primary">New order</AppButton>
      </RouterLink>
    </div>

    <AsyncState
      :loading="ordersQuery.isLoading.value"
      :error="ordersQuery.error.value"
      :empty="filtered.length === 0"
      empty-title="No orders yet"
      empty-body="Write the first one — pick the account, pick the price list, add lines."
      :rows="3"
      @retry="ordersQuery.refetch()"
    >
      <ul class="divide-line border-line divide-y border">
        <li v-for="order in filtered" :key="order.id">
          <RouterLink
            :to="{ name: 'order-detail', params: { id: order.id } }"
            class="hover:bg-canvas flex flex-wrap items-center justify-between gap-3 px-4 py-3"
          >
            <div class="min-w-0">
              <p class="text-ink truncate text-[15px] font-semibold">
                {{ order.customer_name || order.customer_key }}
              </p>
              <p class="text-muted text-[13px]">
                #{{ order.id }}
                <template v-if="order.po_number"> · PO {{ order.po_number }}</template>
                <template v-if="order.erp_order_number">
                  · ERP {{ order.erp_order_number }}</template
                >
                · {{ shortDate(order.created_at) }}
              </p>
            </div>
            <div class="flex items-center gap-3">
              <span v-if="order.total_amount != null" class="text-ink text-[15px] font-semibold">
                {{ money(order.total_amount) }}
              </span>
              <OrderStatusBadge :status="order.status" />
            </div>
          </RouterLink>
        </li>
      </ul>
    </AsyncState>
  </div>
</template>
