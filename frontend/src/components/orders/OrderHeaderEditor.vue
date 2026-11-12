<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import {
  useOrderFflContext,
  useShipTos,
  useUpdateDraftOrder,
  type OrderLineRow,
  type OrderRow,
} from '@/composables/useOrders'
import { checkEnteredFfl, orderableShipTos, shipDateError } from '@/lib/orderShipTo'
import { customerPoOf, noPoHint, PO_MAX_LENGTH, poForSave, poInputError, rpcErrorText } from '@/lib/mcpOrders'
import { useSessionStore } from '@/stores/session'

/**
 * A draft's details, edited on the order page: customer PO, requested ship
 * date, notes, and the FFL it ships under. For the drafts the order writer
 * must not open (hand-priced or unmatched lines, which it would reprice
 * from the lists): without this, a PO the customer sends later, a lapsed
 * licence or a moved ship date could only be fixed by having Claude resend
 * the whole draft.
 *
 * It patches exactly those orders columns (useUpdateDraftOrder, the
 * writer's own header update under the same RLS: the draft's owner or an
 * admin) and never touches a line. The checks are the writer's: a PO is
 * optional but not a PORTAL- reference, a ship date that has passed is
 * refused at submit (ship_date_past), and an FFL is asked for and checked
 * only where the server will want one (order_ffl_context).
 */
const props = defineProps<{ order: OrderRow; lines: OrderLineRow[] }>()

const session = useSessionStore()
const update = useUpdateDraftOrder()

const po = ref('')
const shipDate = ref('')
const notes = ref('')
const fflNumber = ref('')
const fflExpiresOn = ref('')
/** Giving a licence other than the current one on file. */
const useDifferentFfl = ref(false)
const dirty = ref(false)
const error = ref('')
const saved = ref(false)

/** Load the stored values: on open, and after any save or refetch while untouched. */
let loading = false
function load(o: OrderRow) {
  loading = true
  po.value = customerPoOf(o.po_number, o.id)
  shipDate.value = o.requested_ship_date ?? ''
  notes.value = o.notes ?? ''
  fflNumber.value = o.ffl_license_number ?? ''
  fflExpiresOn.value = o.ffl_expires_on ?? ''
  useDifferentFfl.value = !!o.ffl_license_number
  loading = false
  dirty.value = false
}
// Synchronous, so loading the stored values is told apart from typing.
watch(
  [po, shipDate, notes, fflNumber, fflExpiresOn, useDifferentFfl],
  () => {
    if (loading) return
    dirty.value = true
    saved.value = false
  },
  { flush: 'sync' },
)
// Another order (the page can reuse this component): always start from its
// stored values, so nothing typed for one order can be saved onto another.
// The same order refetched: reload only while untouched.
watch(
  () => [props.order.id, props.order.updated_at] as const,
  ([id], prev) => {
    if (prev && id !== prev[0]) {
      error.value = ''
      saved.value = false
      load(props.order)
    } else if (!dirty.value) {
      load(props.order)
    }
  },
  { immediate: true },
)

/**
 * Unsaved or still-saving details, for the page: Submit sends what is
 * stored, so it waits until these are saved or undone.
 */
const emit = defineEmits<{ busy: [busy: boolean] }>()
watch(
  () => dirty.value || update.isPending.value,
  (busy) => emit('busy', busy),
  { immediate: true },
)

// ----------------------------------------------------------- the FFL, as the writer asks
const customerKey = computed(() => props.order.customer_key)
const shipTos = useShipTos(customerKey)
const shipTo = computed(
  () =>
    orderableShipTos(shipTos.data.value ?? []).find((r) => r.ship_to_key === props.order.ship_to_key) ??
    null,
)
const partIds = computed(() =>
  [...new Set(props.lines.filter((l) => !l.part_unresolved).map((l) => l.part_id))].sort(),
)
const fflContext = useOrderFflContext(customerKey, partIds)
/** Not known yet is never "no FFL needed": nothing is cleared on a guess. */
const fflKnown = computed(
  () => !!fflContext.data.value && !fflContext.isError.value && !fflContext.isPlaceholderData.value,
)
const requiresFfl = computed(() => fflContext.data.value?.requires_ffl ?? false)
const onFile = computed(
  () => fflContext.data.value?.ship_tos.find((s) => s.ship_to_key === props.order.ship_to_key) ?? null,
)
const onFileCurrent = computed(() => onFile.value?.ffl_current ?? false)
const showFflInputs = computed(
  () => requiresFfl.value && !!shipTo.value && (!onFileCurrent.value || useDifferentFfl.value),
)
const fflCheck = computed(() =>
  checkEnteredFfl({
    shipTo: shipTo.value,
    requiresFfl: requiresFfl.value,
    onFileCurrent: onFileCurrent.value,
    fflNumber: showFflInputs.value ? fflNumber.value : '',
    fflExpiresOn: showFflInputs.value ? fflExpiresOn.value : '',
  }),
)

const poHint = computed(() => noPoHint(po.value, props.order.id, props.order.status))

/**
 * A stored ship date that has passed is said, not refused: submit_order()
 * will refuse it (ship_date_past), but it must not stop the PO being saved.
 * A date typed here is checked.
 */
const shipDateNote = computed(() =>
  shipDate.value === (props.order.requested_ship_date ?? '') ? shipDateError(shipDate.value) : '',
)

async function save() {
  const typedDate = shipDate.value !== (props.order.requested_ship_date ?? '')
  error.value =
    poInputError(po.value, props.order.id) || (typedDate ? shipDateError(shipDate.value) : '')
  if (!error.value) error.value = fflCheck.value.errors[0] ?? ''
  if (error.value) return
  // As the writer: blank means the licence on file. A stored licence is
  // dropped only when it is known not to be wanted (the server has answered
  // and the ship-to is loaded); otherwise whatever is there is kept.
  const keepFfl = !(fflKnown.value && !!shipTo.value && !showFflInputs.value)
  try {
    await update.mutateAsync({
      id: props.order.id,
      po_number: poForSave(po.value, props.order.id),
      requested_ship_date: shipDate.value || null,
      notes: notes.value.trim() || null,
      ffl_license_number: (keepFfl && fflNumber.value.trim()) || null,
      ffl_expires_on: (keepFfl && fflExpiresOn.value) || null,
    })
    dirty.value = false
    saved.value = true
  } catch (err) {
    error.value = rpcErrorText((err as { message?: string }).message) || "The details weren't saved."
  }
}

function revert() {
  error.value = ''
  load(props.order)
}

const notesLabel = computed(() => (session.isOrderEntry ? 'Notes' : 'Notes for inside sales'))
</script>

<template>
  <AppCard title="Order details">
    <div class="space-y-4">
      <div class="grid gap-3 md:grid-cols-3">
        <label class="block">
          <span class="u-label text-ink block pb-2">Customer PO #</span>
          <input
            v-model="po"
            :maxlength="PO_MAX_LENGTH"
            class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
          />
          <span v-if="poHint" class="text-muted block pt-1 text-[13px]">{{ poHint }}</span>
        </label>
        <label class="block">
          <span class="u-label text-ink block pb-2">Requested ship date</span>
          <input
            v-model="shipDate"
            type="date"
            class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
          />
          <span v-if="shipDateNote" class="text-danger block pt-1 text-[13px]">
            {{ shipDateNote }} It can't be submitted with this date.
          </span>
        </label>
        <label class="block">
          <span class="u-label text-ink block pb-2">{{ notesLabel }}</span>
          <input v-model="notes" class="border-line text-ink min-h-12 w-full border px-3 text-[15px]" />
        </label>
      </div>

      <!-- FFL: only for firearms, typed only when no current licence is on file. -->
      <template v-if="shipTo">
        <p v-if="fflContext.isError.value" role="alert" class="text-danger text-[14px]">
          Couldn't check whether this order needs an FFL.
          <button type="button" class="underline" @click="fflContext.refetch()">Try again</button>
        </p>
        <p v-else-if="fflContext.isLoading.value" class="text-muted text-[14px]">Checking FFL…</p>
        <div v-else-if="requiresFfl && onFileCurrent && !useDifferentFfl" class="text-ink-2 text-[14px]">
          Ships under the FFL on file for {{ shipTo.ship_to_id }}:
          <strong class="text-ink">{{ shipTo.ffl_license_number }}</strong>, expires
          {{ onFile?.ffl_expires_on }}.
          <button type="button" class="text-muted ml-1 underline" @click="useDifferentFfl = true">
            Use a different FFL
          </button>
        </div>
        <template v-else-if="showFflInputs">
          <p class="text-ink-2 text-[14px]">
            <template v-if="onFileCurrent">Giving a different FFL than the one on file.</template>
            <template v-else>
              This order has firearms and {{ shipTo.ship_to_id }} has no current FFL on file: enter
              the licence it ships under before submitting.
            </template>
            <button
              v-if="onFileCurrent"
              type="button"
              class="text-muted ml-1 underline"
              @click="useDifferentFfl = false; fflNumber = ''; fflExpiresOn = ''"
            >
              Use the one on file
            </button>
          </p>
          <div class="grid gap-3 md:grid-cols-2">
            <label class="block">
              <span class="u-label text-ink block pb-2">FFL number</span>
              <input
                v-model="fflNumber"
                class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
                placeholder="1-23-456-78-9A-12345"
                autocomplete="off"
              />
            </label>
            <label class="block">
              <span class="u-label text-ink block pb-2">FFL expires</span>
              <input
                v-model="fflExpiresOn"
                type="date"
                class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              />
            </label>
          </div>
        </template>
        <ul
          v-if="fflCheck.warnings.length"
          class="border-line border-l-accent text-ink-2 space-y-1 border border-l-[3px] p-3 text-[14px]"
        >
          <li v-for="(w, i) in fflCheck.warnings" :key="i">{{ w }}</li>
        </ul>
      </template>

      <p v-if="error" role="alert" class="text-danger text-sm font-medium">{{ error }}</p>
      <p v-else-if="saved" role="status" class="text-ink-2 text-[14px]">Details saved.</p>

      <div class="flex flex-wrap gap-2">
        <AppButton variant="secondary" :loading="update.isPending.value" :disabled="!dirty" @click="save">
          Save details
        </AppButton>
        <AppButton v-if="dirty" variant="ghost" @click="revert">Undo changes</AppButton>
      </div>
    </div>
  </AppCard>
</template>
