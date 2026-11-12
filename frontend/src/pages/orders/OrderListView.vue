<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import OrderStatusBadge from '@/components/orders/OrderStatusBadge.vue'
import OrderSourceBadge from '@/components/orders/OrderSourceBadge.vue'
import { useFeatureFlags } from '@/composables/useAppSettings'
import { useMyOrders, useOrderOwnerNames } from '@/composables/useOrders'
import { money, shortDate } from '@/lib/format'
import { isPortalReference } from '@/lib/mcpOrders'
import {
  ownerLabel,
  readListScope,
  scopeOrders,
  writeListScope,
  type OrderListScope,
} from '@/lib/orderOwners'
import { useSessionStore } from '@/stores/session'
import { ORDER_STATUS_LABELS, ORDER_STATUSES, type OrderStatus } from '@/types/domain'

/**
 * Every order the caller can read — a rep's own (plus the agency's for a
 * principal), everything for an admin or inside sales. The feedback loop
 * lives here: a rep watches submitted → entered (with the ERP number) →
 * verified without having to call the office.
 *
 * An admin or inside sales reads every order in the company, every rep's
 * unfinished drafts included, so their list opens on their OWN orders, with
 * Everyone a tap away (remembered for the tab). Rows that are not the
 * viewer's say who drafted them; their own are marked Yours.
 */
const session = useSessionStore()
const ordersQuery = useMyOrders()
/** Hand entry can be off while Claude drafting is on: no "New order" then. */
const flags = useFeatureFlags()

const seesEveryone = computed(() => session.isAdmin || session.isOrderEntry)
const scope = ref<OrderListScope>(readListScope())

/** What the scope switch leaves: everything for a rep (it is theirs, or their agency's). */
const scoped = computed(() => {
  const rows = ordersQuery.data.value ?? []
  return seesEveryone.value ? scopeOrders(rows, scope.value, session.user?.id) : rows
})

const statusFilter = ref<OrderStatus | 'all'>('all')
watch(scope, (next) => {
  writeListScope(next)
  // A status the other scope has none of would leave an empty, unexplained list.
  if (statusFilter.value !== 'all' && !scoped.value.some((o) => o.status === statusFilter.value)) {
    statusFilter.value = 'all'
  }
})

const filtered = computed(() => {
  const rows = scoped.value
  if (statusFilter.value === 'all') return rows
  return rows.filter((o) => o.status === statusFilter.value)
})

/** Anyone else's orders on screen: then rows say whose they are. */
const showsOthers = computed(() => filtered.value.some((o) => o.user_id !== session.user?.id))
const owners = useOrderOwnerNames(
  computed(() => (showsOthers.value ? filtered.value.map((o) => o.user_id) : [])),
)
function ownerOf(userId: string): string {
  return ownerLabel(owners.names.value[userId], { isViewer: userId === session.user?.id })
}

const filterOptions = computed(() => {
  const rows = scoped.value
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
      <div
        v-if="seesEveryone"
        class="flex gap-2"
        role="radiogroup"
        aria-label="Whose orders"
      >
        <button
          v-for="opt in [{ key: 'mine', label: 'Mine' }, { key: 'everyone', label: 'Everyone' }] as const"
          :key="opt.key"
          type="button"
          role="radio"
          :aria-checked="scope === opt.key"
          class="tap-target font-label border px-3 text-[13px] font-semibold tracking-[0.1em] uppercase"
          :class="
            scope === opt.key ? 'border-ink bg-ink text-canvas' : 'border-line text-muted hover:text-ink'
          "
          @click="scope = opt.key"
        >
          {{ opt.label }}
        </button>
      </div>
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
      <RouterLink v-if="flags.orders.value" :to="{ name: 'orders-new' }">
        <AppButton variant="primary">New order</AppButton>
      </RouterLink>
    </div>

    <AsyncState
      :loading="ordersQuery.isLoading.value"
      :error="ordersQuery.error.value"
      :has-data="ordersQuery.data.value !== undefined"
      :updated-at="ordersQuery.dataUpdatedAt.value"
      :empty="filtered.length === 0"
      :empty-title="seesEveryone && scope === 'mine' ? 'No orders of yours yet' : 'No orders yet'"
      :empty-body="
        seesEveryone && scope === 'mine' && (ordersQuery.data.value ?? []).length > 0
          ? 'Everyone\'s orders are under Everyone.'
          : flags.orders.value
            ? 'Write the first one — pick the account, pick the price list, add lines.'
            : 'Orders Claude drafts for you land here to review and submit.'
      "
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
                <!-- A PORTAL- reference is the portal's, not the customer's PO. -->
                <template v-if="order.po_number">
                  · {{ isPortalReference(order.po_number) ? '' : 'PO ' }}{{ order.po_number }}</template
                >
                <template v-if="order.erp_order_number">
                  · ERP {{ order.erp_order_number }}</template
                >
                · {{ shortDate(order.created_at) }}
                <template v-if="showsOthers && order.user_id !== session.user?.id && ownerOf(order.user_id)">
                  · by {{ ownerOf(order.user_id) }}</template
                >
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-3">
              <AppBadge v-if="showsOthers && order.user_id === session.user?.id">Yours</AppBadge>
              <OrderSourceBadge :source="order.source" :is-test="order.is_test" />
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
