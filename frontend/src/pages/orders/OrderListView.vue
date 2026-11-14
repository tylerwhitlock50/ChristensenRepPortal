<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import OrderStatusBadge from '@/components/orders/OrderStatusBadge.vue'
import OrderSourceBadge from '@/components/orders/OrderSourceBadge.vue'
import { useFeatureFlags } from '@/composables/useAppSettings'
import { useMyOrders, useOrderOwnerNames, type OrderRow } from '@/composables/useOrders'
import { money, shortDate } from '@/lib/format'
import { isPortalReference, sourceBadgeLabel } from '@/lib/mcpOrders'
import type { ExportColumn } from '@/lib/xlsx'
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

/* ---- the download: exactly the list on screen ------------------------- */
const viewerId = computed(() => session.user?.id)
/**
 * Other people's orders in the scope: a principal's agency, Everyone, or any
 * order someone else (an admin, a principal) drafted on a rep's own book —
 * RLS lets a plain rep read those too. In View-as the viewer id is the
 * admin's, so every row of the target counts as someone else's.
 */
const scopeHasOthers = computed(() => scoped.value.some((o) => o.user_id !== viewerId.value))

/** Who drafted it, by name: "you" means nothing in a forwarded file. */
function draftedBy(o: OrderRow): string {
  return o.user_id === viewerId.value ? session.displayName : ownerOf(o.user_id)
}

const exportColumns = computed<ExportColumn<OrderRow>[]>(() => [
  { key: 'id', header: 'Order #', type: 'text' },
  { key: 'customer_name', header: 'Account', format: (o) => o.customer_name || o.customer_key },
  { key: 'customer_key', header: 'Customer key', type: 'text' },
  // A PORTAL- reference is the portal's own, shown as-is like the screen does.
  { key: 'po_number', header: 'PO / reference', type: 'text' },
  { key: 'erp_order_number', header: 'ERP order #', type: 'text' },
  { key: 'created_at', header: 'Created', type: 'datetime' },
  { key: 'submitted_at', header: 'Submitted', type: 'datetime' },
  { key: 'requested_ship_date', header: 'Requested ship date', type: 'date' },
  ...(showsOthers.value
    ? [{ key: 'user_id', header: 'Drafted by', format: draftedBy } as ExportColumn<OrderRow>]
    : []),
  { key: 'source', header: 'Source', format: (o) => sourceBadgeLabel(o.source) || 'Portal' },
  { key: 'is_test', header: 'Test draft', format: (o) => (o.is_test ? 'Yes' : 'No') },
  { key: 'total_amount', header: 'Total', type: 'money' },
  { key: 'status', header: 'Status', format: (o) => ORDER_STATUS_LABELS[o.status] ?? o.status },
])

const everyone = computed(() => seesEveryone.value && scope.value === 'everyone')
const exportTitle = computed(() => {
  if (everyone.value) return 'Portal orders — everyone'
  if (!seesEveryone.value && scopeHasOthers.value) {
    // Only a principal has an agency; anyone else's extra rows are on their accounts.
    return session.isPrincipal
      ? 'Portal orders — mine and my agency'
      : 'Portal orders — mine and on my accounts'
  }
  return 'My portal orders'
})
const exportFilename = computed(
  () =>
    `portal-orders${everyone.value ? '-everyone' : ''}` +
    (statusFilter.value === 'all' ? '' : `-${statusFilter.value}`),
)
const EXPORT_DESCRIPTION =
  'Orders written in the portal, by hand or drafted by Claude, and where each one stands: ' +
  'draft, submitted, entered in the ERP, verified.'
const exportDetails = computed(() => [
  seesEveryone.value && `Whose orders: ${scope.value === 'everyone' ? 'Everyone' : 'Mine'}`,
  `Status: ${statusFilter.value === 'all' ? 'All' : ORDER_STATUS_LABELS[statusFilter.value]}`,
])

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
      <div class="flex flex-wrap items-center justify-end gap-2">
        <RouterLink v-if="flags.orders.value" :to="{ name: 'orders-new' }">
          <AppButton variant="primary">New order</AppButton>
        </RouterLink>
        <ExportMenu
          :rows="filtered"
          :columns="exportColumns"
          :title="exportTitle"
          :filename="exportFilename"
          :description="EXPORT_DESCRIPTION"
          :details="exportDetails"
          sheet-name="Portal orders"
        />
      </div>
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
