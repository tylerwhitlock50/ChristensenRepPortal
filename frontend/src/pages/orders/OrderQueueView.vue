<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppModal from '@/components/ui/AppModal.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import OrderStatusBadge from '@/components/orders/OrderStatusBadge.vue'
import {
  useMarkOrderEntered,
  useOrderQueue,
  useRunOrderQc,
  type OrderRow,
} from '@/composables/useOrders'
import { useSessionStore } from '@/stores/session'
import { money, shortDate } from '@/lib/format'

/**
 * The order-entry workbench: every submitted order waiting to be keyed into
 * the ERP, everything entered and awaiting QC, and the discrepancies. The
 * router lets any signed-in user reach /orders when the flag is on, so this
 * page additionally gates itself to order_entry + admin — a rep deep-linking
 * here gets the notice, not the queue (RLS would show them only their own
 * orders anyway; defense in depth, same as the DB).
 */
const session = useSessionStore()
const allowed = computed(() => session.isOrderEntry || session.isAdmin)

const queueQuery = useOrderQueue()
const markEntered = useMarkOrderEntered()
const runQc = useRunOrderQc()

type Filter = 'submitted' | 'entered' | 'discrepancy' | 'all'
const filter = ref<Filter>('submitted')

const counts = computed(() => {
  const rows = queueQuery.data.value ?? []
  return {
    submitted: rows.filter((o) => o.status === 'submitted').length,
    entered: rows.filter((o) => o.status === 'entered').length,
    discrepancy: rows.filter((o) => o.status === 'discrepancy').length,
    all: rows.length,
  }
})

const filterTabs = computed(() => [
  { key: 'submitted' as const, label: `To enter (${counts.value.submitted})` },
  { key: 'entered' as const, label: `Awaiting QC (${counts.value.entered})` },
  { key: 'discrepancy' as const, label: `Discrepancies (${counts.value.discrepancy})` },
  { key: 'all' as const, label: `All (${counts.value.all})` },
])

const filtered = computed(() => {
  const rows = queueQuery.data.value ?? []
  if (filter.value === 'all') return rows
  return rows.filter((o) => o.status === filter.value)
})

// -------------------------------------------------------- mark entered modal
const target = ref<OrderRow | null>(null)
const erpNumber = ref('')
const actionError = ref('')

function openEnter(order: OrderRow) {
  target.value = order
  erpNumber.value = ''
  actionError.value = ''
}

async function confirmEntered() {
  if (!target.value) return
  actionError.value = ''
  try {
    await markEntered.mutateAsync({
      id: target.value.id,
      erpOrderNumber: erpNumber.value,
    })
    target.value = null
  } catch (err) {
    actionError.value = (err as { message?: string }).message || 'That failed.'
  }
}

async function recheck(order: OrderRow) {
  actionError.value = ''
  try {
    await runQc.mutateAsync(order.id)
  } catch (err) {
    actionError.value = (err as { message?: string }).message || 'That failed.'
  }
}
</script>

<template>
  <div v-if="!allowed" class="px-4 py-10 text-center">
    <p class="u-display text-ink text-2xl">Order entry only</p>
    <p class="text-muted mx-auto mt-2 max-w-xs text-[15px]">
      The entry queue is for the order entry role and admins.
    </p>
  </div>

  <div v-else class="space-y-4">
    <div class="flex flex-wrap gap-2" role="tablist" aria-label="Queue filters">
      <button
        v-for="tab in filterTabs"
        :key="tab.key"
        type="button"
        role="tab"
        :aria-selected="filter === tab.key"
        class="tap-target font-label border px-3 text-[13px] font-semibold tracking-[0.1em] uppercase"
        :class="
          filter === tab.key
            ? 'border-ink bg-ink text-canvas'
            : 'border-line text-muted hover:text-ink'
        "
        @click="filter = tab.key"
      >
        {{ tab.label }}
      </button>
    </div>

    <p v-if="actionError" role="alert" class="text-danger text-sm font-medium">
      {{ actionError }}
    </p>

    <AsyncState
      :loading="queueQuery.isLoading.value"
      :error="queueQuery.error.value"
      :empty="filtered.length === 0"
      empty-title="Queue clear"
      :empty-body="
        filter === 'submitted'
          ? 'Nothing waiting to be entered.'
          : 'Nothing here right now.'
      "
      :rows="3"
      @retry="queueQuery.refetch()"
    >
      <ul class="divide-line border-line divide-y border">
        <li
          v-for="order in filtered"
          :key="order.id"
          class="flex flex-wrap items-center justify-between gap-3 px-4 py-3"
        >
          <RouterLink
            :to="{ name: 'order-detail', params: { id: order.id } }"
            class="min-w-0 flex-1"
          >
            <p class="text-ink truncate text-[15px] font-semibold">
              {{ order.customer_name || order.customer_key }}
            </p>
            <p class="text-muted text-[13px]">
              #{{ order.id }}
              <template v-if="order.po_number"> · PO {{ order.po_number }}</template>
              <template v-if="order.erp_order_number">
                · ERP {{ order.erp_order_number }}</template
              >
              <template v-if="order.submitted_at">
                · submitted {{ shortDate(order.submitted_at) }}</template
              >
              <template v-if="order.requested_ship_date">
                · ship {{ shortDate(order.requested_ship_date) }}</template
              >
            </p>
            <p v-if="order.notes" class="text-ink-2 mt-0.5 truncate text-[13px]">
              {{ order.notes }}
            </p>
          </RouterLink>
          <div class="flex shrink-0 items-center gap-3">
            <span v-if="order.total_amount != null" class="text-ink text-[15px] font-semibold">
              {{ money(order.total_amount) }}
            </span>
            <OrderStatusBadge :status="order.status" />
            <AppButton
              v-if="order.status === 'submitted'"
              variant="primary"
              @click="openEnter(order)"
            >
              Mark entered
            </AppButton>
            <AppButton
              v-else
              variant="ghost"
              :loading="runQc.isPending.value"
              @click="recheck(order)"
            >
              Re-check
            </AppButton>
          </div>
        </li>
      </ul>
    </AsyncState>

    <AppModal
      :open="target != null"
      title="Mark entered in ERP"
      :subtitle="target ? `Order #${target.id} · ${target.customer_name}` : ''"
      @update:open="(open: boolean) => { if (!open) target = null }"
    >
      <div class="space-y-3">
        <label class="block">
          <span class="u-label text-ink block pb-2">ERP order number</span>
          <input
            v-model="erpNumber"
            class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
            placeholder="As entered in the ERP"
            @keydown.enter="confirmEntered"
          />
        </label>
        <p v-if="actionError" role="alert" class="text-danger text-sm">{{ actionError }}</p>
        <AppButton
          variant="primary"
          :loading="markEntered.isPending.value"
          :disabled="!erpNumber.trim()"
          @click="confirmEntered"
        >
          Confirm entered
        </AppButton>
      </div>
    </AppModal>
  </div>
</template>
