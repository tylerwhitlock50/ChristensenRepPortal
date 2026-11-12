<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppModal from '@/components/ui/AppModal.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import OrderStatusBadge from '@/components/orders/OrderStatusBadge.vue'
import QcResultsCard from '@/components/orders/QcResultsCard.vue'
import McpDraftReview from '@/components/orders/McpDraftReview.vue'
import AdminPricingReview from '@/components/orders/AdminPricingReview.vue'
import OrderDocumentsCard from '@/components/orders/OrderDocumentsCard.vue'
import OrderSourceBadge from '@/components/orders/OrderSourceBadge.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import {
  blocksWriterEdit,
  FLAG_LABEL,
  lineFlags,
  needsPricingReview,
  pricingSubmitBlock,
} from '@/lib/adminPricing'
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
import { moneyCents, shortDate } from '@/lib/format'
import { fflNumbersMatch } from '@/lib/orderShipTo'
import {
  canSubmitWithAck,
  handEntryAllows,
  needsAcknowledgement,
  noPoHint,
  priceMismatch,
  rpcErrorText,
} from '@/lib/mcpOrders'
import { useFeatureFlags } from '@/composables/useAppSettings'

/**
 * One order, for all three audiences. Everyone sees the same facts — the
 * status timeline, the lines, the QC findings, the documents — and the
 * action row is the only role-dependent part. Every action is a transition
 * RPC; the database re-checks role and status, so a stale button click fails
 * loudly instead of corrupting anything.
 *
 * Lines are keyed by their id throughout: a hand-priced order may carry the
 * same part twice at different prices (10 paid, 1 free).
 */
const props = defineProps<{ id: string }>()
const orderId = computed(() => Number(props.id))

const session = useSessionStore()
const detail = useOrderDetail(orderId)

const order = computed(() => detail.data.value?.order ?? null)

/**
 * What inside sales has to do in the ERP before entering it: the order loader
 * refuses to write an order whose FFL doesn't match the ship-to's licence on
 * file. Only meaningful once submitted (the snapshot is stamped then).
 */
const fflOnFileNote = computed(() => {
  const o = order.value
  if (!o || o.status === 'draft' || o.requires_ffl === false || !o.ffl_license_number) return ''
  if (!o.ffl_on_file_number) {
    return `The ERP has no FFL on file for ship-to ${o.ship_to_id ?? ''}: add ${o.ffl_license_number} to it before entering this order.`
  }
  if (!fflNumbersMatch(o.ffl_license_number, o.ffl_on_file_number)) {
    return `The ERP's FFL for ship-to ${o.ship_to_id ?? ''} is ${o.ffl_on_file_number}: update it to ${o.ffl_license_number} before entering this order.`
  }
  return ''
})
const lines = computed(() => detail.data.value?.lines ?? [])
const qc = computed(() => detail.data.value?.qc ?? [])

const isOwner = computed(() => order.value?.user_id === session.user?.id)
const canEnter = computed(() => session.isOrderEntry || session.isAdmin)

/** A draft with no customer PO: what it will be submitted as (PORTAL-<id>). */
const poHint = computed(() =>
  order.value ? noPoHint(order.value.po_number, order.value.id, order.value.status) : '',
)

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
    actionError.value = rpcErrorText((err as { message?: string }).message) || 'That failed.'
  }
}

// ------------------------------------------- Claude-drafted orders (MCP)
/** Not written by hand here: show the review block, require the tick. */
const isMcp = computed(() => needsAcknowledgement(order.value?.source))
const acknowledged = ref(false)

// ------------------------------- hand pricing (20261112120000, 20261113090000)
/** Lines staged from a PO as sent: hand prices, unmatched items, checks. */
const pricingReview = computed(() => needsPricingReview(lines.value))
/** The writer reprices every line from the lists; it must not open these. */
const writerBlocked = computed(() => blocksWriterEdit(lines.value))
/**
 * Why submit_order() would refuse on pricing grounds, or ''. Hand-priced
 * lines need an admin or inside sales (can_price_orders()). Ownership is the
 * other half and is the action row's own `isOwner`: the server takes a
 * submit only from the order's owner or an admin, so inside sales submits a
 * hand-priced order only when it is their own draft.
 */
const pricingBlock = computed(() => pricingSubmitBlock(lines.value, session.canPriceOrders))
/**
 * The per-line price controls: a Claude-drafted draft, for whoever may price
 * (admin_set_order_line_price() re-checks all three). Not while viewing as
 * someone or offline, where every write is refused.
 */
const canEditPricing = computed(
  () =>
    order.value?.status === 'draft' &&
    order.value.source !== 'portal' &&
    session.canWrite &&
    session.canPriceOrders,
)
/**
 * Removing a line sits with the price controls, but it is a plain delete
 * under order_lines RLS, which is narrower than pricing: the draft's owner
 * or an admin. So inside sales can reprice a colleague's draft but is only
 * offered Remove on their own.
 */
const canRemoveLines = computed(
  () => canEditPricing.value && (session.isAdmin || isOwner.value),
)

const canSubmit = computed(
  () =>
    canSubmitWithAck(order.value?.source, acknowledged.value, order.value?.is_test === true) &&
    !pricingBlock.value,
)

/**
 * Hand entry (feature.orders) off: a hand-typed order can't be edited,
 * submitted or recalled here (the server refuses to submit it, so a recall
 * would strand it as a draft). Cancel stays. Flags load as false, so this
 * fails closed while they load.
 */
const featureFlags = useFeatureFlags()
const handEntryOk = computed(() =>
  handEntryAllows(featureFlags.orders.value, order.value?.source),
)

async function onSubmit() {
  if (pricingBlock.value) {
    actionError.value = pricingBlock.value
    return
  }
  if (!canSubmit.value) {
    actionError.value = order.value?.is_test
      ? 'This is a test order. It cannot be submitted; cancel it instead.'
      : "Tick \"I've reviewed this order and it is correct\" first."
    return
  }
  await act(() =>
    submitOrder.mutateAsync({ id: orderId.value, acknowledged: isMcp.value && acknowledged.value }),
  )
}

/** Who acknowledged it, in words: "you" or the stamp's id. */
const acknowledgedByLabel = computed(() => {
  const by = order.value?.acknowledged_by
  if (!by) return ''
  return by === session.user?.id ? 'you' : `user ${by.slice(0, 8)}`
})

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
  if (o.acknowledged_at) {
    steps.push({
      label: 'Reviewed and confirmed',
      at: o.acknowledged_at,
      detail: acknowledgedByLabel.value ? `by ${acknowledgedByLabel.value}` : undefined,
    })
  }
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
    :has-data="detail.data.value !== undefined"
    :updated-at="detail.dataUpdatedAt.value"
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
          <!-- A PO is optional: say what a blank one becomes on submit. -->
          <p v-if="poHint" class="text-muted text-[13px]">{{ poHint }}</p>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <OrderSourceBadge :source="order.source" :is-test="order.is_test" />
          <OrderStatusBadge :status="order.status" />
        </div>
      </header>

      <!-- Where it ships and under which licence (submit_order snapshots both). -->
      <div class="border-line bg-surface border px-4 py-3 text-[14px]">
        <p class="text-ink">
          <span class="u-label text-muted mr-2">Ship to</span>
          <template v-if="order.ship_to_id">
            {{ order.ship_to_id }}<template v-if="order.ship_to_name"> — {{ order.ship_to_name }}</template>
            <span v-if="order.ship_to_address" class="text-muted"> · {{ order.ship_to_address }}</span>
          </template>
          <template v-else-if="order.ship_to_key">{{ order.ship_to_key }}</template>
          <span v-else class="text-muted">not chosen</span>
        </p>
        <p class="text-ink mt-1">
          <span class="u-label text-muted mr-2">FFL</span>
          <template v-if="order.ffl_license_number">
            {{ order.ffl_license_number }}
            <span v-if="order.ffl_expires_on" class="text-muted">· expires {{ shortDate(order.ffl_expires_on) }}</span>
          </template>
          <span v-else-if="order.requires_ffl === false" class="text-muted">not needed (no firearms)</span>
          <span v-else-if="order.status === 'draft'" class="text-muted">the licence on file, if current</span>
          <span v-else class="text-muted">none</span>
        </p>
        <p v-if="fflOnFileNote" class="text-ink-2 border-l-accent mt-2 border-l-[3px] pl-2 text-[13px]">
          {{ fflOnFileNote }}
        </p>
      </div>

      <!-- A PO staged as sent: hand prices and unmatched items, line by line,
           with the overrides for an admin or inside sales while it is a draft. -->
      <AdminPricingReview
        v-if="pricingReview"
        :lines="lines"
        :reason="order.price_override_reason"
        :editable="canEditPricing"
        :can-remove="canRemoveLines"
      />

      <!-- Claude-drafted: warnings, the source email, and the acknowledgement
           that gates Submit (right above the button, phone-first). -->
      <p
        v-if="order.is_test"
        role="note"
        class="border-danger text-ink border-l-[3px] bg-surface px-3 py-2 text-[14px] font-semibold"
      >
        Test order — Claude drafted this as a test. It cannot be submitted.
      </p>
      <McpDraftReview
        v-if="isMcp"
        v-model:acknowledged="acknowledged"
        :source="order.source"
        :warnings="order.mcp_warnings"
        :source-ref="order.source_ref"
        :po-hint="poHint"
        :show-ack="order.status === 'draft' && isOwner"
      />
      <p v-if="order.acknowledged_at" class="text-ink-2 text-[14px]">
        <span class="u-label text-muted mr-2">Confirmed</span>
        {{ shortDate(order.acknowledged_at) }}<template v-if="acknowledgedByLabel">
          by {{ acknowledgedByLabel }}</template>
      </p>

      <p v-if="actionError" role="alert" class="text-danger text-sm font-medium">
        {{ actionError }}
      </p>

      <!-- Actions, by role and status. -->
      <div class="flex flex-wrap gap-2">
        <p
          v-if="!handEntryOk && ['draft', 'submitted'].includes(order.status) && isOwner"
          class="text-muted w-full text-[13px]"
        >
          Writing orders in the portal is turned off, so this hand-written order can't be
          <template v-if="order.status === 'draft'">edited or submitted</template>
          <template v-else>recalled to draft</template>.
        </p>
        <p
          v-if="order.status === 'draft' && pricingBlock"
          class="text-danger w-full text-[14px] font-medium"
        >
          {{ pricingBlock }}
        </p>
        <template v-if="order.status === 'draft' && isOwner && handEntryOk">
          <RouterLink
            v-if="!writerBlocked"
            :to="{ name: 'order-edit', params: { id: order.id } }"
          >
            <AppButton :variant="isMcp ? 'secondary' : 'primary'">Edit draft</AppButton>
          </RouterLink>
          <p v-else class="text-muted w-full text-[13px]">
            This draft has hand-priced or unmatched lines, which the order writer would
            reprice: change them above, or ask Claude to update the draft.
          </p>
          <AppButton
            :variant="isMcp ? 'primary' : 'secondary'"
            :loading="submitOrder.isPending.value"
            :disabled="!canSubmit"
            @click="onSubmit"
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
            v-if="isOwner && handEntryOk"
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

      <!-- The customer's PO and anything else filed with the order: every
           status, everyone who can open it. Beside the lines it is checked
           against. -->
      <OrderDocumentsCard :order-id="order.id" />

      <!-- Lines -->
      <AppCard title="Lines" :hint="`${lines.length} lines`">
        <!-- Phone: one stacked row per line (the review link opens here). -->
        <ul class="divide-line divide-y sm:hidden">
          <li v-for="line in lines" :key="line.id" class="py-2.5">
            <div class="flex items-baseline justify-between gap-3">
              <span class="text-ink min-w-0 font-medium break-words">{{ line.part_id }}</span>
              <span class="text-ink shrink-0 font-semibold">{{ moneyCents(line.line_total) }}</span>
            </div>
            <div v-if="lineFlags(line).length" class="flex flex-wrap gap-1 py-1">
              <AppBadge
                v-for="f in lineFlags(line)"
                :key="f"
                :tone="f === 'unmatched' || f === 'check_description' ? 'late' : 'high'"
              >
                {{ FLAG_LABEL[f] }}
              </AppBadge>
            </div>
            <p v-if="line.description" class="text-muted text-[13px] break-words">
              {{ line.description }}
            </p>
            <p class="text-ink-2 text-[13px]">
              {{ line.qty }} × {{ moneyCents(line.effective_unit_price) }}
              <template v-if="line.discount_pct > 0">
                ({{ moneyCents(line.unit_price) }} less {{ line.discount_pct }}%)</template
              >
            </p>
            <p v-if="priceMismatch(line)" class="text-danger text-[13px] font-medium">
              Customer expected {{ moneyCents(priceMismatch(line)!.expected) }} each
            </p>
          </li>
          <li v-if="order.total_amount != null" class="flex justify-between py-3">
            <span class="text-ink font-semibold">Order total</span>
            <span class="text-ink text-[16px] font-bold">{{ moneyCents(order.total_amount) }}</span>
          </li>
        </ul>
        <div class="-mx-4 hidden overflow-x-auto px-4 sm:block">
          <table class="w-full min-w-[480px] text-[14px]">
            <thead>
              <tr class="text-muted border-line border-b text-left">
                <th class="py-2 pr-3 font-semibold">Part</th>
                <th class="py-2 pr-3 text-right font-semibold">Qty</th>
                <th class="py-2 pr-3 text-right font-semibold">Price</th>
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
                  <span v-if="priceMismatch(line)" class="text-danger block text-[12px] font-medium">
                    Customer expected {{ moneyCents(priceMismatch(line)!.expected) }}
                  </span>
                  <span v-if="lineFlags(line).length" class="flex flex-wrap gap-1 pt-1">
                    <AppBadge
                      v-for="f in lineFlags(line)"
                      :key="f"
                      :tone="f === 'unmatched' || f === 'check_description' ? 'late' : 'high'"
                    >
                      {{ FLAG_LABEL[f] }}
                    </AppBadge>
                  </span>
                </td>
                <td class="text-ink py-2 pr-3 text-right">{{ line.qty }}</td>
                <td class="text-ink py-2 pr-3 text-right">
                  {{ moneyCents(line.unit_price) }}
                  <span
                    v-if="line.price_source === 'admin' && line.list_unit_price != null"
                    class="text-muted block text-[12px]"
                  >
                    list {{ moneyCents(line.list_unit_price) }}
                  </span>
                </td>
                <td class="text-ink-2 py-2 pr-3 text-right">
                  {{ line.discount_pct > 0 ? `${line.discount_pct}%` : '—' }}
                </td>
                <td class="text-ink py-2 pr-3 text-right font-medium">
                  {{ moneyCents(line.effective_unit_price) }}
                </td>
                <td class="text-ink py-2 text-right font-semibold">
                  {{ moneyCents(line.line_total) }}
                </td>
              </tr>
            </tbody>
            <tfoot v-if="order.total_amount != null">
              <tr>
                <td colspan="5" class="text-ink py-3 pr-3 text-right font-semibold">
                  Order total
                </td>
                <td class="text-ink py-3 text-right text-[16px] font-bold">
                  {{ moneyCents(order.total_amount) }}
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
