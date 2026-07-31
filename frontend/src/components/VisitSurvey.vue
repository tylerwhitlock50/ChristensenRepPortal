<script setup lang="ts">
/**
 * Structured visit survey — PRD §7, acceptance criterion #5: complete and
 * submit from a phone, with a photo, in under 60 seconds.
 *
 * Everything here serves that clock:
 *   - visit type is pre-filled ("In person"), so the fastest valid survey is
 *     one tap: Save.
 *   - every answer is a 48px button. No selects, no sliders, no keyboard
 *     except the comments box.
 *   - tapping a chosen answer again clears it — no "n/a" option to hunt for.
 *   - one screen, one column, no modal. Confirmation lands inline.
 *
 * Not this component's job (by design):
 *   - photos → the `photos` slot, just above the submit button.
 *   - offline drafts → `initialValues` in, `change` out. The parent debounces
 *     and persists; this component never touches IndexedDB.
 */
import { computed, ref, useId, watch, type Ref } from 'vue'
import { useField, useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import AppButton from '@/components/ui/AppButton.vue'
import { useSubmitVisit, type VisitSubmitError } from '@/composables/useVisits'
import {
  COMPETITOR_BRANDS,
  COMPETITOR_PROMO_OPTIONS,
  INVENTORY_LEVEL_OPTIONS,
  RATING_VALUES,
  STORE_TRAFFIC_OPTIONS,
  VISIT_TYPE_OPTIONS,
  makeVisitFormValues,
  visitFormSchema,
  visitTypeLabel,
  type CompetitorBrand,
  type RatingValue,
  type VisitFormValues,
} from '@/lib/visitSchema'
import type {
  CompetitorPromos,
  InventoryLevel,
  StoreTraffic,
  VisitType,
} from '@/types/domain'
import { shortDate } from '@/lib/format'

const props = withDefaults(
  defineProps<{
    customerKey: string
    /** Set when the survey was opened from a recommendation. */
    recommendationId?: number | null
    /** Restored draft. Applied while the form is still untouched. */
    initialValues?: Partial<VisitFormValues> | null
  }>(),
  { recommendationId: null, initialValues: null },
)

const emit = defineEmits<{
  submitted: [visitId: number]
  cancel: []
  /** Fires on every edit. Debounce it in the parent — this side is raw. */
  change: [values: VisitFormValues]
}>()

defineSlots<{
  /** Photo capture, dropped in just above Save. `visitId` is null until saved. */
  photos?(props: { customerKey: string; visitId: number | null }): any
}>()

const uid = useId()

/* ---- form ---------------------------------------------------------------- */

const { handleSubmit, meta, resetForm } = useForm({
  validationSchema: toTypedSchema(visitFormSchema),
  initialValues: makeVisitFormValues(props.initialValues),
})

const { value: visitType, errorMessage: visitTypeError } =
  useField<VisitType>('visit_type')
const { value: visitDate, errorMessage: visitDateError } =
  useField<string>('visit_date')
const { value: inventoryLevel } = useField<InventoryLevel | null>(
  'inventory_level',
)
const { value: storeCondition } = useField<number | null>('store_condition')
const { value: displayQuality } = useField<number | null>('display_quality')
const { value: staffKnowledge } = useField<number | null>('staff_knowledge')
const { value: storeTraffic } = useField<StoreTraffic | null>('store_traffic')
const { value: competitorPromos } = useField<CompetitorPromos | null>(
  'competitor_promos',
)
const { value: competitionSeen } =
  useField<CompetitorBrand[]>('competition_seen')
const { value: comments, errorMessage: commentsError } = useField<
  string | null
>('comments')

interface RatingField {
  key: string
  label: string
  hint: string
  model: Ref<number | null>
}

const ratingFields: RatingField[] = [
  {
    key: 'store_condition',
    label: 'Store condition',
    hint: '1 = rough · 5 = spotless',
    model: storeCondition,
  },
  {
    key: 'display_quality',
    label: 'Our display',
    hint: '1 = buried · 5 = front and center',
    model: displayQuality,
  },
  {
    key: 'staff_knowledge',
    label: 'Staff knowledge',
    hint: '1 = blank stare · 5 = sells it for us',
    model: staffKnowledge,
  },
]

/* ---- pickers (tap the same answer again to clear it) --------------------- */

function pickVisitType(value: VisitType) {
  visitType.value = value
}
function pickInventory(value: InventoryLevel) {
  inventoryLevel.value = inventoryLevel.value === value ? null : value
}
function pickTraffic(value: StoreTraffic) {
  storeTraffic.value = storeTraffic.value === value ? null : value
}
function pickPromos(value: CompetitorPromos) {
  competitorPromos.value = competitorPromos.value === value ? null : value
}
function pickRating(field: RatingField, value: RatingValue) {
  field.model.value = field.model.value === value ? null : value
}
function toggleBrand(brand: CompetitorBrand) {
  const list = competitionSeen.value ?? []
  competitionSeen.value = list.includes(brand)
    ? list.filter((b) => b !== brand)
    : [...list, brand]
}
function isBrandOn(brand: CompetitorBrand): boolean {
  return (competitionSeen.value ?? []).includes(brand)
}

const segClass = (on: boolean) =>
  on
    ? 'border-zinc-900 bg-zinc-900 text-white'
    : 'border-zinc-300 bg-white text-zinc-700'

/* ---- draft plumbing ------------------------------------------------------ */

const current = computed<VisitFormValues>(() => ({
  visit_type: visitType.value,
  visit_date: visitDate.value,
  inventory_level: inventoryLevel.value,
  store_condition: storeCondition.value,
  display_quality: displayQuality.value,
  staff_knowledge: staffKnowledge.value,
  store_traffic: storeTraffic.value,
  competitor_promos: competitorPromos.value,
  competition_seen: competitionSeen.value ?? [],
  comments: comments.value,
}))

const savedVisitId = ref<number | null>(null)
const saved = computed(() => savedVisitId.value !== null)

watch(
  current,
  (values) => {
    if (saved.value) return
    // A plain, proxy-free copy — the parent may put this straight in IndexedDB.
    emit('change', { ...values, competition_seen: [...values.competition_seen] })
  },
  { deep: true },
)

/**
 * A draft read off disk lands after mount. Adopt it only while the rep hasn't
 * typed anything, and only when it actually differs — otherwise the parent
 * echoing our own `change` back would bounce forever.
 */
watch(
  () => props.initialValues,
  (next) => {
    if (!next || saved.value || meta.value.dirty) return
    const merged = makeVisitFormValues(next)
    if (JSON.stringify(merged) === JSON.stringify(current.value)) return
    resetForm({ values: merged })
  },
  { deep: true },
)

/* ---- submit -------------------------------------------------------------- */

const submitVisit = useSubmitVisit()
const serverError = ref('')
/** Kept when the action landed but the survey insert didn't, so a retry reuses it. */
const retryActionId = ref<number | null>(null)

const onSubmit = handleSubmit(async (values) => {
  serverError.value = ''
  try {
    const visit = await submitVisit.mutateAsync({
      customerKey: props.customerKey,
      recommendationId: props.recommendationId,
      values: values as VisitFormValues,
      actionId: retryActionId.value,
    })
    retryActionId.value = null
    savedVisitId.value = visit.id
    emit('submitted', visit.id)
  } catch (e) {
    const err = e as VisitSubmitError
    retryActionId.value = err.actionId ?? null
    serverError.value = err.message || 'Could not save that visit. Try again.'
  }
})

function startAnother() {
  savedVisitId.value = null
  serverError.value = ''
  resetForm({ values: makeVisitFormValues() })
}
</script>

<template>
  <!-- Saved: inline confirmation, never a modal (TECH_STACK §2.4) -->
  <section
    v-if="saved"
    class="rounded-lg border border-emerald-200 bg-emerald-50 p-4"
    role="status"
  >
    <h3 class="text-base font-semibold text-emerald-900">Visit saved</h3>
    <p class="mt-1 text-sm text-emerald-800">
      {{ visitTypeLabel(current.visit_type) }} ·
      {{ shortDate(current.visit_date) }}. It counts toward coverage.
    </p>

    <div class="mt-3">
      <slot name="photos" :customer-key="customerKey" :visit-id="savedVisitId" />
    </div>

    <div class="mt-4">
      <AppButton variant="secondary" @click="startAnother">
        Log another visit
      </AppButton>
    </div>
  </section>

  <form v-else class="space-y-5" novalidate @submit="onSubmit">
    <!-- Visit type + date: the only two things that are always answered -->
    <fieldset>
      <legend class="mb-2 text-sm font-medium text-zinc-700">
        How did you contact them?
      </legend>
      <div class="flex gap-2">
        <button
          v-for="o in VISIT_TYPE_OPTIONS"
          :key="o.value"
          type="button"
          class="tap-target flex-1 rounded-lg border px-2 text-sm font-medium"
          :class="segClass(visitType === o.value)"
          :aria-pressed="visitType === o.value"
          @click="pickVisitType(o.value)"
        >
          {{ o.label }}
        </button>
      </div>
      <p v-if="visitTypeError" class="mt-1 text-sm text-red-700">
        {{ visitTypeError }}
      </p>
    </fieldset>

    <div>
      <label
        :for="`${uid}-date`"
        class="mb-1 block text-sm font-medium text-zinc-700"
      >
        Date
      </label>
      <input
        :id="`${uid}-date`"
        v-model="visitDate"
        type="date"
        class="tap-target w-full rounded-lg border border-zinc-300 bg-white px-3 text-base outline-none focus:border-zinc-900"
        :aria-invalid="!!visitDateError || undefined"
      />
      <p v-if="visitDateError" class="mt-1 text-sm text-red-700">
        {{ visitDateError }}
      </p>
    </div>

    <!-- Inventory: the single most useful answer on the form -->
    <fieldset>
      <legend class="mb-2 text-sm font-medium text-zinc-700">
        How much of our product is on the shelf?
      </legend>
      <div class="grid grid-cols-4 gap-2">
        <button
          v-for="o in INVENTORY_LEVEL_OPTIONS"
          :key="o.value"
          type="button"
          class="tap-target rounded-lg border px-1 text-sm font-medium"
          :class="segClass(inventoryLevel === o.value)"
          :aria-pressed="inventoryLevel === o.value"
          @click="pickInventory(o.value)"
        >
          {{ o.label }}
        </button>
      </div>
    </fieldset>

    <!-- 1–5 scales: five big buttons each, never a select or a slider -->
    <fieldset v-for="f in ratingFields" :key="f.key">
      <legend class="mb-1 flex w-full items-baseline gap-2 text-sm font-medium text-zinc-700">
        <span>{{ f.label }}</span>
        <span class="text-xs font-normal text-zinc-500">{{ f.hint }}</span>
      </legend>
      <div class="flex gap-2">
        <button
          v-for="n in RATING_VALUES"
          :key="n"
          type="button"
          class="tap-target flex-1 rounded-lg border text-base font-semibold"
          :class="segClass(f.model.value === n)"
          :aria-pressed="f.model.value === n"
          :aria-label="`${f.label}: ${n} out of 5`"
          @click="pickRating(f, n)"
        >
          {{ n }}
        </button>
      </div>
    </fieldset>

    <fieldset>
      <legend class="mb-2 text-sm font-medium text-zinc-700">
        Store traffic while you were there
      </legend>
      <div class="flex gap-2">
        <button
          v-for="o in STORE_TRAFFIC_OPTIONS"
          :key="o.value"
          type="button"
          class="tap-target flex-1 rounded-lg border px-2 text-sm font-medium"
          :class="segClass(storeTraffic === o.value)"
          :aria-pressed="storeTraffic === o.value"
          @click="pickTraffic(o.value)"
        >
          {{ o.label }}
        </button>
      </div>
    </fieldset>

    <fieldset>
      <legend class="mb-2 text-sm font-medium text-zinc-700">
        Competitor promotions
      </legend>
      <div class="flex gap-2">
        <button
          v-for="o in COMPETITOR_PROMO_OPTIONS"
          :key="o.value"
          type="button"
          class="tap-target flex-1 rounded-lg border px-2 text-sm font-medium"
          :class="segClass(competitorPromos === o.value)"
          :aria-pressed="competitorPromos === o.value"
          @click="pickPromos(o.value)"
        >
          {{ o.label }}
        </button>
      </div>
    </fieldset>

    <fieldset>
      <legend class="mb-2 text-sm font-medium text-zinc-700">
        Competition on the rack
        <span class="font-normal text-zinc-500">(tap all you saw)</span>
      </legend>
      <div class="grid grid-cols-2 gap-2 sm:grid-cols-3">
        <button
          v-for="brand in COMPETITOR_BRANDS"
          :key="brand"
          type="button"
          class="tap-target rounded-lg border px-2 text-sm font-medium"
          :class="segClass(isBrandOn(brand))"
          :aria-pressed="isBrandOn(brand)"
          @click="toggleBrand(brand)"
        >
          {{ brand }}
        </button>
      </div>
    </fieldset>

    <div>
      <label
        :for="`${uid}-comments`"
        class="mb-1 block text-sm font-medium text-zinc-700"
      >
        Anything else?
        <span class="font-normal text-zinc-500">(optional)</span>
      </label>
      <textarea
        :id="`${uid}-comments`"
        v-model="comments"
        rows="3"
        enterkeyhint="done"
        placeholder="What did the buyer say?"
        class="w-full rounded-lg border border-zinc-300 bg-white p-3 text-base outline-none focus:border-zinc-900"
        :aria-invalid="!!commentsError || undefined"
      />
      <p v-if="commentsError" class="mt-1 text-sm text-red-700">
        {{ commentsError }}
      </p>
    </div>

    <!-- Photo capture is another agent's component; it drops in here. -->
    <slot name="photos" :customer-key="customerKey" :visit-id="null" />

    <p v-if="serverError" role="alert" class="text-sm text-red-700">
      {{ serverError }}
    </p>

    <div class="flex flex-col gap-2">
      <AppButton
        type="submit"
        size="lg"
        block
        :loading="submitVisit.isPending.value"
      >
        Save visit
      </AppButton>
      <AppButton variant="ghost" block @click="emit('cancel')">
        Cancel
      </AppButton>
    </div>
  </form>
</template>
