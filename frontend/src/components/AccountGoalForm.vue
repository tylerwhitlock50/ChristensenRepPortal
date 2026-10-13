<script setup lang="ts">
import { ref, useId } from 'vue'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import { z } from 'zod'
import AppButton from '@/components/ui/AppButton.vue'
import {
  useRemoveAccountGoal,
  useSetAccountGoal,
  type AccountGoalProgress,
} from '@/composables/useAccountGoals'
import { money } from '@/lib/format'

/**
 * The inline goal editor from AccountGoalPanel, in its own file so the
 * account page does not download zod and vee-validate (about half of its
 * code) for a form that is closed on arrival. The panel loads this only
 * when the rep taps Edit or Set a goal, and unmounts it to close it — so a
 * half-typed goal never follows the rep to the next dealer.
 */
const props = defineProps<{
  customerKey: string
  year: number
  /** The goal being edited, or null when setting a first one. */
  goal: AccountGoalProgress | null
  /** The ERP's yearly_sales_goal, offered as the starting number. */
  erpGoal: number | null
}>()

const emit = defineEmits<{ close: [] }>()

const uid = useId()
const save = useSetAccountGoal()
const remove = useRemoveAccountGoal()
const serverError = ref('')
const confirmingRemove = ref(false)

/** ERP-sourced goals have no account_goals row, so nothing to remove. */
const isErpGoal = props.goal?.goal_source === 'erp'

/**
 * Reps type "85,000" and "$85k" as readily as "85000". Strip the money
 * punctuation before validating rather than rejecting a number the rep
 * plainly meant — this is the field they'll fill in standing at a counter.
 */
function parseAmount(raw: string): number | null {
  const cleaned = raw.replace(/[$,\s]/g, '').replace(/k$/i, '000')
  if (!cleaned) return null
  const n = Number(cleaned)
  return Number.isFinite(n) ? n : null
}

const schema = toTypedSchema(
  z.object({
    amount: z
      .string()
      .trim()
      .min(1, 'Enter a dollar amount')
      .refine((v) => parseAmount(v) != null, "That doesn't look like an amount")
      .refine((v) => (parseAmount(v) ?? 0) > 0, 'A goal has to be more than zero')
      .refine(
        (v) => (parseAmount(v) ?? 0) < 1_000_000_000,
        'That is larger than this account could plausibly buy',
      ),
    note: z.string().trim().max(500, 'Keep the note under 500 characters'),
  }),
)

/**
 * Seeded on open: the existing goal, or the ERP's number as a starting
 * point. A rep who agrees with the ERP figure should be able to commit to it
 * in one tap rather than retyping it.
 */
const seed = props.goal?.target_amount ?? props.erpGoal ?? null
const { defineField, errors, handleSubmit, isSubmitting } = useForm({
  validationSchema: schema,
  initialValues: {
    amount: seed != null ? String(Math.round(seed)) : '',
    note: props.goal?.note ?? '',
  },
})

const [amount, amountAttrs] = defineField('amount')
const [note, noteAttrs] = defineField('note')

const onSubmit = handleSubmit(async (values) => {
  const targetAmount = parseAmount(values.amount)
  if (targetAmount == null) return
  serverError.value = ''
  try {
    await save.mutateAsync({
      customerKey: props.customerKey,
      values: { targetAmount, periodYear: props.year, note: values.note },
    })
    emit('close')
  } catch (e) {
    serverError.value = (e as Error).message || 'Could not save that goal.'
  }
})

async function confirmRemove() {
  serverError.value = ''
  try {
    await remove.mutateAsync({ customerKey: props.customerKey, periodYear: props.year })
    emit('close')
  } catch (e) {
    serverError.value = (e as Error).message || 'Could not remove that goal.'
  }
}
</script>

<template>
  <form
    class="border-line bg-canvas mt-3 rounded-[2px] border p-4"
    novalidate
    @submit="onSubmit"
  >
    <div class="space-y-3">
      <div>
        <label :for="`${uid}-amount`" class="text-ink-2 mb-1 block text-sm font-medium">
          {{ year }} revenue goal
        </label>
        <div class="flex items-center gap-2">
          <span class="u-display text-ink-2 text-xl">$</span>
          <input
            :id="`${uid}-amount`"
            v-model="amount"
            v-bind="amountAttrs"
            type="text"
            inputmode="decimal"
            autocomplete="off"
            spellcheck="false"
            enterkeyhint="done"
            placeholder="85,000"
            class="tap-target border-line-2 bg-surface focus:border-brand w-full rounded-[2px] border px-3 py-2 text-base tabular-nums outline-none"
            :aria-invalid="!!errors.amount || undefined"
            :aria-describedby="errors.amount ? `${uid}-amount-err` : undefined"
          />
        </div>
        <p v-if="errors.amount" :id="`${uid}-amount-err`" class="text-danger mt-1 text-sm">
          {{ errors.amount }}
        </p>
        <p v-else-if="erpGoal != null" class="text-muted mt-1 text-[13px]">
          The ERP has {{ money(erpGoal) }} for this account.
        </p>
      </div>

      <div>
        <label :for="`${uid}-note`" class="text-ink-2 mb-1 block text-sm font-medium">
          Why this number <span class="text-muted font-normal">(optional)</span>
        </label>
        <textarea
          :id="`${uid}-note`"
          v-model="note"
          v-bind="noteAttrs"
          rows="2"
          placeholder="Adding the ATV line in Q2 — owner committed to a spring order."
          class="border-line-2 bg-surface focus:border-brand w-full rounded-[2px] border p-3 text-base outline-none"
          :aria-invalid="!!errors.note || undefined"
          :aria-describedby="errors.note ? `${uid}-note-err` : undefined"
        />
        <p v-if="errors.note" :id="`${uid}-note-err`" class="text-danger mt-1 text-sm">
          {{ errors.note }}
        </p>
      </div>
    </div>

    <p v-if="serverError" role="alert" class="text-danger mt-3 text-sm">
      {{ serverError }}
    </p>

    <div class="mt-4 flex flex-wrap gap-2">
      <AppButton type="submit" :loading="isSubmitting">
        {{ goal ? 'Save goal' : 'Set goal' }}
      </AppButton>
      <AppButton variant="ghost" @click="emit('close')">Cancel</AppButton>
      <AppButton
        v-if="goal && !isErpGoal && !confirmingRemove"
        variant="ghost"
        class="ml-auto"
        @click="confirmingRemove = true"
      >
        Remove
      </AppButton>
    </div>

    <!-- Confirm in place. Removing a goal loses the note and the history of
         what was committed to, so it asks once. -->
    <div v-if="confirmingRemove" class="border-line mt-3 border-t pt-3">
      <p class="text-ink-2 text-sm">
        Remove the {{ year }} goal for this account? Reporting falls back to
        the ERP's number.
      </p>
      <div class="mt-2 flex gap-2">
        <AppButton
          variant="danger"
          :loading="remove.isPending.value"
          @click="confirmRemove"
        >
          Remove goal
        </AppButton>
        <AppButton variant="ghost" @click="confirmingRemove = false">Keep it</AppButton>
      </div>
    </div>
  </form>
</template>
