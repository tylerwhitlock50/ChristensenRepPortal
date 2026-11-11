<script setup lang="ts">
import { computed, ref } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import { useRemoveOrderLine, useSetLinePrice, type OrderLineRow } from '@/composables/useOrders'
import {
  FLAG_LABEL,
  lineFlags,
  parsePriceInput,
  pricingSummary,
} from '@/lib/adminPricing'
import { moneyCents, shortDate } from '@/lib/format'
import { rpcErrorText } from '@/lib/mcpOrders'

/**
 * The review block for an order staged with admin pricing (20261111170000):
 * a customer PO taken as sent — parts on no price list, prices that are not
 * the published price, item numbers that match no part. Every flagged line is
 * listed with what to compare: the PO's item number and description beside
 * the part's, and the list / admin / last-paid prices.
 *
 * `editable` (an admin, on a draft) adds the overrides: set a price, reset it
 * to the list price, or remove the line. The database re-checks all of it.
 */
const props = defineProps<{
  lines: OrderLineRow[]
  reason: string | null | undefined
  editable: boolean
}>()

const summary = computed(() => pricingSummary(props.lines))
const flagged = computed(() =>
  props.lines
    .map((line) => ({ line, flags: lineFlags(line) }))
    .filter((x) => x.flags.length > 0),
)

const setPrice = useSetLinePrice()
const removeLine = useRemoveOrderLine()

const drafts = ref<Record<number, string>>({})
const reasonDraft = ref('')
const busyId = ref<number | null>(null)
const error = ref('')

const needsReason = computed(() => !props.reason)

async function run(lineId: number, action: () => Promise<unknown>) {
  error.value = ''
  busyId.value = lineId
  try {
    await action()
    delete drafts.value[lineId]
  } catch (err) {
    error.value = rpcErrorText((err as { message?: string }).message) || 'That failed.'
  } finally {
    busyId.value = null
  }
}

function savePrice(line: OrderLineRow) {
  const price = parsePriceInput(drafts.value[line.id] ?? '')
  if (price === null) {
    error.value = 'Type a price like 1655.99 (two decimals at most).'
    return
  }
  const reason = reasonDraft.value.trim()
  if (needsReason.value && !reason) {
    error.value = 'Say why this order is priced by hand first.'
    return
  }
  void run(line.id, () =>
    setPrice.mutateAsync({ lineId: line.id, unitPrice: price, reason: reason || null }),
  )
}

function resetToList(line: OrderLineRow) {
  void run(line.id, () => setPrice.mutateAsync({ lineId: line.id, unitPrice: null }))
}

function remove(line: OrderLineRow) {
  if (!window.confirm(`Remove ${line.customer_part_ref || line.part_id} from this order?`)) return
  void run(line.id, () => removeLine.mutateAsync(line.id))
}

const money = (v: number | null | undefined) => (v == null ? '—' : moneyCents(Number(v)))
</script>

<template>
  <section
    class="border-danger bg-surface space-y-3 border border-l-[6px] px-4 py-3"
    aria-label="Admin pricing to review"
  >
    <div>
      <p class="text-danger text-[17px] font-bold">
        <template v-if="summary.unmatched">
          {{ summary.unmatched }} line{{ summary.unmatched === 1 ? '' : 's' }} match no part ·
        </template>
        <template v-if="summary.adminLines">
          {{ summary.adminLines }} of {{ summary.lines }} lines are not at the published price
        </template>
        <template v-else-if="summary.descriptionChecks">
          {{ summary.descriptionChecks }} line{{ summary.descriptionChecks === 1 ? '' : 's' }} to check
        </template>
      </p>
      <p class="text-ink-2 text-[14px]">
        Staged from the customer's PO as it was sent. Check every flagged line against the PO
        before submitting<template v-if="summary.adminLines">; only an admin can submit it</template>.
      </p>
      <p v-if="summary.adminLines" class="text-ink-2 mt-1 text-[14px]">
        <span class="u-label text-muted mr-2">Admin-priced</span>{{ money(summary.adminValue) }}
        <template v-if="summary.notListPrice">
          · {{ money(summary.belowList) }} below list on the lines that have one
        </template>
        <template v-if="summary.offList"> · {{ summary.offList }} on no price list</template>
      </p>
      <p class="text-ink mt-1 text-[14px]">
        <span class="u-label text-muted mr-2">Reason</span>
        <template v-if="reason">{{ reason }}</template>
        <span v-else class="text-muted">none given</span>
      </p>
    </div>

    <label v-if="editable && needsReason" class="block">
      <span class="u-label text-ink block pb-1">Reason for hand pricing (needed to set a price)</span>
      <input
        v-model="reasonDraft"
        maxlength="500"
        class="border-line text-ink min-h-11 w-full border px-3 text-[15px]"
        placeholder="e.g. excess stock buy-in, approved by …"
      />
    </label>

    <p v-if="error" role="alert" class="text-danger text-sm font-medium">{{ error }}</p>

    <ul class="divide-line border-line divide-y border-t">
      <li v-for="{ line, flags } in flagged" :key="line.id" class="space-y-1.5 py-3">
        <div class="flex flex-wrap items-center gap-2">
          <span class="text-ink font-semibold break-all">{{ line.part_id }}</span>
          <span class="text-muted text-[13px]">× {{ line.qty }}</span>
          <AppBadge
            v-for="f in flags"
            :key="f"
            :tone="f === 'unmatched' || f === 'check_description' ? 'late' : 'high'"
          >
            {{ FLAG_LABEL[f] }}
          </AppBadge>
        </div>

        <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-[13px]">
          <template v-if="line.customer_part_ref || line.customer_description">
            <dt class="text-muted">PO says</dt>
            <dd class="text-ink min-w-0 break-words">
              <span v-if="line.customer_part_ref" class="font-medium">{{ line.customer_part_ref }}</span>
              <template v-if="line.customer_part_ref && line.customer_description"> — </template>
              {{ line.customer_description }}
            </dd>
          </template>
          <dt class="text-muted">Part</dt>
          <dd class="text-ink min-w-0 break-words">
            <span v-if="line.part_unresolved" class="text-danger">No ERP part has this number</span>
            <template v-else>{{ line.description || '—' }}</template>
          </dd>
          <dt class="text-muted">Price</dt>
          <dd class="text-ink">
            <strong>{{ money(line.unit_price) }}</strong>
            <span class="text-muted">
              · list {{ line.list_unit_price == null ? 'none' : money(line.list_unit_price) }}
              · last paid
              <template v-if="line.last_paid_price != null">
                {{ money(line.last_paid_price) }}<template v-if="line.last_paid_date">
                  ({{ shortDate(line.last_paid_date) }})</template
                >
              </template>
              <template v-else>never</template>
            </span>
          </dd>
        </dl>

        <div v-if="editable" class="flex flex-wrap items-center gap-2 pt-1">
          <template v-if="!line.part_unresolved">
            <input
              v-model="drafts[line.id]"
              inputmode="decimal"
              class="border-line text-ink min-h-10 w-32 border px-2 text-[15px]"
              :placeholder="String(line.unit_price)"
              :aria-label="`New price for ${line.part_id}`"
              @keydown.enter="savePrice(line)"
            />
            <AppButton
              variant="secondary"
              :loading="busyId === line.id && setPrice.isPending.value"
              :disabled="!drafts[line.id]"
              @click="savePrice(line)"
            >
              Set price
            </AppButton>
            <AppButton
              v-if="line.price_source === 'admin' && line.list_unit_price != null"
              variant="ghost"
              :loading="busyId === line.id && setPrice.isPending.value"
              @click="resetToList(line)"
            >
              Reset to list
            </AppButton>
          </template>
          <AppButton
            variant="ghost"
            :loading="busyId === line.id && removeLine.isPending.value"
            @click="remove(line)"
          >
            Remove line
          </AppButton>
        </div>
      </li>
    </ul>
  </section>
</template>
