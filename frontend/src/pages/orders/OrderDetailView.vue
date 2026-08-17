<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppModal from '@/components/ui/AppModal.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import OrderStatusBadge from '@/components/orders/OrderStatusBadge.vue'
import QcResultsCard from '@/components/orders/QcResultsCard.vue'
import {
  useCancelOrder,
  useMarkOrderEntered,
  useOrderDetail,
  useRecallOrder,
  useReopenEnteredOrder,
  useResolveDiscrepancy,
  useRunOrderQc,
  useSubmitOrder,
} from '@/composables/useOrders'
import { useSessionStore } from '@/stores/session'
import { money, shortDate } from '@/lib/format'

/**
 * One order, for all three audiences. Everyone sees the same facts — the
 * status timeline, the lines, the QC findings — and the action row is the
 * only role-dependent part. Every action is a transition RPC; the database
 * re-checks role and status, so a stale button click fails loudly instead
 * of corrupting anything.
 */
const props = defineProps<{ id: string }>()
const orderId = computed(() => Number(props.id))

const session = useSessionStore()
const detail = useOrderDetail(orderId)

const order = computed(() => detail.data.value?.order ?? null)
const lines = computed(() => detail.data.value?.lines ?? [])
const qc = computed(() => detail.data.value?.qc ?? [])

const isOwner = computed(() => order.value?.user_id === session.user?.id)
const canEnter = computed(() => session.isOrderEntry || session.isAdmin)

const submitOrder = useSubmitOrder()
const recallOrder = useRecallOrder()
const cancelOrder = useCancelOrder()
const markEntered = useMarkOrderEntered()
const reopenOrder = useReopenEnteredOrder()
const resolveDiscrepancy = useResolveDiscrepancy()
const runQc = useRunOrderQc()

const actionError = ref('')

async function act(action: () => Promise<unknown>) {
  actionError.value = ''
  try {
    await action()
  } catch (err) {
    actionError.value = (err as { message?: string }).message || 'That failed.'
  }
}

// -------------------------------------------------------- mark entered modal
const enterOpen = ref(false)
const erpNumber = ref('')

async function confirmEntered() {
  await act(async () => {
    await markEntered.mutateAsync({
      id: orderId.value,
      erpOrderNumber: erpNumber.value,
    })
    enterOpen.value = false
    erpNumber.value = ''
  })
}

// ------------------------------------------------------------ resolve modal
const resolveOpen = ref(false)
const resolveNote = ref('')

async function confirmResolve() {
  await act(async () => {
    await resolveDiscrepancy.mutateAsync({
      id: orderId.value,
      note: resolveNote.value.trim() || null,
    })
    resolveOpen.value = false
    resolveNote.value = ''
  })
}

async function onCancel() {
  if (!window.confirm('Cancel this order?')) return
  await act(() => cancelOrder.mutateAsync(orderId.value))
}

/** The status trail, oldest first — only stamps that exist are shown. */
const timeline = computed(() => {
  const o = order.value
  if (!o) return []
  const steps: { label: string; at: string | null; detail?: string }[] = [
    { label: 'Created', at: o.created_at },
  ]
  if (o.submitted_at) steps.push({ label: 'Submitted', at: o.submitted_at })
  if (o.entered_at) {
    steps.push({
      label: 'Entered in ERP',
      at: o.entered_at,
      detail: o.erp_order_number ? `ERP order ${o.erp_order_number}` : undefined,
    })
  }
  if (o.status === 'verified' && o.verified_at) {
    steps.push({
      label: 'Verified against ERP',
      at: o.verified_at,
      detail: o.resolution_note ?? undefined,
    })
  }
  if (o.status === 'discrepancy' && o.qc_checked_at) {
    steps.push({ label: 'Discrepancy found', at: o.qc_checked_at })
  }
  if (o.status === 'cancelled') steps.push({ label: 'Cancelled', at: o.updated_at })
  return steps
})
</script>

<template>
  <AsyncState
    :loading="detail.isLoading.value"
    :error="detail.error.value"
    :empty="!detail.isLoading.value && !order"
    empty-title="Order not found"
    empty-body="It may have been deleted, or it isn't yours to see."
    :rows="3"
    @retry="detail.refetch()"
  >
    <div v-if="order" class="space-y-5">
      <header class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="u-display text-ink text-2xl">
            {{ order.customer_name || order.customer_key }}
          </h2>
          <p class="text-muted text-[13px]">
            Order #{{ order.id }}
            <template v-if="order.po_number"> · PO {{ order.po_number }}</template>
            <template v-if="order.customer_type"> · {{ order.customer_type }}</template>
          </p>
        </div>
        <OrderStatusBadge :status="order.status" />
      </header>

      <p v-if="actionError" role="alert" class="text-danger text-sm font-medium">
        {{ actionError }}
      </p>

      <!-- Actions, by role and status. -->
      <div class="flex flex-wrap gap-2">
        <template v-if="order.status === 'draft' && isOwner">
          <RouterLink :to="{ name: 'order-edit', params: { id: order.id } }">
            <AppButton variant="primary">Edit draft</AppButton>
          </RouterLink>
          <AppButton
            variant="secondary"
            :loading="submitOrder.isPending.value"
            @click="act(() => submitOrder.mutateAsync(orderId))"
          >
            Submit
          </AppButton>
        </template>

        <template v-if="order.status === 'submitted'">
          <AppButton
            v-if="canEnter"
            variant="primary"
            @click="enterOpen = true"
          >
            Mark entered in ERP
          </AppButton>
          <AppButton
            v-if="isOwner"
            variant="secondary"
            :loading="recallOrder.isPending.value"
            @click="act(() => recallOrder.mutateAsync(orderId))"
          >
            Recall to draft
          </AppButton>
        </template>

        <template v-if="['entered', 'discrepancy'].includes(order.status) && canEnter">
          <AppButton
            variant="secondary"
            :loading="runQc.isPending.value"
            @click="act(() => runQc.mutateAsync(orderId))"
          >
            Re-check vs ERP
          </AppButton>
          <AppButton
            variant="ghost"
            :loading="reopenOrder.isPending.value"
            @click="act(() => reopenOrder.mutateAsync(orderId))"
          >
            Reopen (wrong ERP #)
          </AppButton>
        </template>

        <AppButton
          v-if="order.status === 'discrepancy' && session.isAdmin"
          variant="secondary"
          @click="resolveOpen = true"
        >
          Resolve discrepancy
        </AppButton>

        <AppButton
          v-if="['draft', 'submitted'].includes(order.status) && (isOwner || session.isAdmin)"
          variant="ghost"
          :loading="cancelOrder.isPending.value"
          @click="onCancel"
        >
          Cancel order
        </AppButton>
      </div>

      <QcResultsCard :qc="qc" :checked-at="order.qc_checked_at" />

      <!-- Timeline -->
      <AppCard title="Status">
        <ol class="space-y-2">
          <li
            v-for="step in timeline"
            :key="step.label"
            class="flex items-baseline gap-3"
          >
            <span class="text-muted w-24 shrink-0 text-[13px]">
              {{ step.at ? shortDate(step.at) : '' }}
            </span>
            <span class="text-ink text-[15px] font-medium">
              {{ step.label }}
              <span v-if="step.detail" class="text-ink-2 font-normal">
                — {{ step.detail }}</span
              >
            </span>
          </li>
        </ol>
      </AppCard>

      <!-- Lines -->
      <AppCard title="Lines" :hint="`${lines.length} lines`">
        <div class="-mx-4 overflow-x-auto px-4">
          <table class="w-full min-w-[480px] text-[14px]">
            <thead>
              <tr class="text-muted border-line border-b text-left">
                <th class="py-2 pr-3 font-semibold">Part</th>
                <th class="py-2 pr-3 text-right font-semibold">Qty</th>
                <th class="py-2 pr-3 text-right font-semibold">List</th>
                <th class="py-2 pr-3 text-right font-semibold">Disc.</th>
                <th class="py-2 pr-3 text-right font-semibold">Net</th>
                <th class="py-2 text-right font-semibold">Total</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="line in lines" :key="line.id" class="border-line border-b">
                <td class="py-2 pr-3">
                  <span class="text-ink block font-medium">{{ line.part_id }}</span>
                  <span class="text-muted block max-w-[220px] truncate text-[12px]">
                    {{ line.description || '' }}
                  </span>
                </td>
                <td class="text-ink py-2 pr-3 text-right">{{ line.qty }}</td>
                <td class="text-ink py-2 pr-3 text-right">{{ money(line.unit_price) }}</td>
                <td class="text-ink-2 py-2 pr-3 text-right">
                  {{ line.discount_pct > 0 ? `${line.discount_pct}%` : '—' }}
                </td>
                <td class="text-ink py-2 pr-3 text-right font-medium">
                  {{ money(line.effective_unit_price) }}
                </td>
                <td class="text-ink py-2 text-right font-semibold">
                  {{ money(line.line_total) }}
                </td>
              </tr>
            </tbody>
            <tfoot v-if="order.total_amount != null">
              <tr>
                <td colspan="5" class="text-ink py-3 pr-3 text-right font-semibold">
                  Order total
                </td>
                <td class="text-ink py-3 text-right text-[16px] font-bold">
                  {{ money(order.total_amount) }}
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
        <p v-if="order.notes" class="text-ink-2 border-line mt-3 border-t pt-3 text-[14px]">
          <strong class="text-ink">Notes:</strong> {{ order.notes }}
        </p>
        <p v-if="order.requested_ship_date" class="text-ink-2 mt-1 text-[14px]">
          <strong class="text-ink">Requested ship:</strong>
          {{ shortDate(order.requested_ship_date) }}
        </p>
      </AppCard>

      <!-- Mark entered -->
      <AppModal
        :open="enterOpen"
        title="Mark entered in ERP"
        :subtitle="`Order #${order.id} · ${order.customer_name}`"
        @update:open="enterOpen = $event"
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
          <p class="text-muted text-[13px]">
            The nightly QC compares this order to the ERP lines under that
            number and flags any difference in part, quantity, price, or
            customer.
          </p>
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

      <!-- Resolve discrepancy -->
      <AppModal
        :open="resolveOpen"
        title="Resolve discrepancy"
        :subtitle="`Order #${order.id}`"
        @update:open="resolveOpen = $event"
      >
        <div class="space-y-3">
          <p class="text-ink-2 text-[14px] leading-relaxed">
            Marks this order verified and clears its findings — use after
            confirming the ERP copy is actually right (an agreed price change,
            a substituted SKU). The note is kept on the order.
          </p>
          <label class="block">
            <span class="u-label text-ink block pb-2">Why is this okay?</span>
            <input
              v-model="resolveNote"
              class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              placeholder="e.g. price change agreed with the dealer 8/12"
            />
          </label>
          <AppButton
            variant="primary"
            :loading="resolveDiscrepancy.isPending.value"
            @click="confirmResolve"
          >
            Mark verified
          </AppButton>
        </div>
      </AppModal>
    </div>
  </AsyncState>
</template>
