<script setup lang="ts">
import { computed, ref, useId, watch } from 'vue'
import { useForm } from 'vee-validate'
import { toTypedSchema } from '@vee-validate/zod'
import { z } from 'zod'
import AppButton from '@/components/ui/AppButton.vue'
import { useSessionStore } from '@/stores/session'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import { useAccount } from '@/composables/useAccounts'
import {
  currentGoalYear,
  paceBasisLabel,
  paceLabel,
  useAccountGoal,
  useRemoveAccountGoal,
  useSetAccountGoal,
} from '@/composables/useAccountGoals'
import { money, shortDate } from '@/lib/format'

/**
 * The rep's own goal for this account, and how the year is going against it.
 *
 * Lives inside the Performance card rather than in a card of its own: the
 * goal is only meaningful next to the revenue it is measured against, and a
 * rep should never have to scroll between the two to know where they stand.
 *
 * Editing happens INLINE, never in a modal — a sheet that covers the account
 * is the wrong thing on a phone in a store (TECH_STACK §2.4, style.css).
 *
 * Current year only, on purpose. The table (023) will hold a goal for any
 * year, but every number on this page — revenue YTD, prior YTD, pace — is
 * about this calendar year, and a card that could be showing next year's
 * target beside this year's revenue would be worse than no card.
 */
const props = defineProps<{ customerKey: string }>()

const session = useSessionStore()

const key = computed(() => props.customerKey)
const year = currentGoalYear()

const query = useAccountGoal(key, year)
const goal = computed(() => query.data.value ?? null)

/**
 * The ERP's own yearly_sales_goal. Read from the account detail query the
 * page already runs (vue-query dedupes on the key, so this costs nothing) —
 * the progress view carries it too, but only once a rep goal exists, and the
 * empty state is exactly where the ERP number is most useful.
 */
const account = useAccount(key)
const erpGoal = computed(
  () => goal.value?.erp_yearly_sales_goal ?? account.data.value?.yearly_sales_goal ?? null,
)

/* ---- inline editor ------------------------------------------------------ */
const editing = ref(false)
const confirmingRemove = ref(false)
const uid = useId()

const save = useSetAccountGoal()
const remove = useRemoveAccountGoal()
const serverError = ref('')

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

const { defineField, errors, handleSubmit, isSubmitting, resetForm } = useForm({
  validationSchema: schema,
  initialValues: { amount: '', note: '' },
})

const [amount, amountAttrs] = defineField('amount')
const [note, noteAttrs] = defineField('note')

/**
 * Seeds the form when the panel opens: the existing goal, or the ERP's number
 * as a starting point. A rep who agrees with the ERP figure should be able to
 * commit to it in one tap rather than retyping it.
 */
function startEdit() {
  const seed = goal.value?.target_amount ?? erpGoal.value ?? null
  resetForm({
    values: {
      amount: seed != null ? String(Math.round(seed)) : '',
      note: goal.value?.note ?? '',
    },
  })
  serverError.value = ''
  confirmingRemove.value = false
  editing.value = true
}

function cancelEdit() {
  editing.value = false
  serverError.value = ''
}

// Navigating between accounts reuses this component; a half-typed goal must
// not follow the rep to the next dealer.
watch(key, () => {
  editing.value = false
  confirmingRemove.value = false
  serverError.value = ''
})

const onSubmit = handleSubmit(async (values) => {
  const targetAmount = parseAmount(values.amount)
  if (targetAmount == null) return
  serverError.value = ''
  try {
    await save.mutateAsync({
      customerKey: props.customerKey,
      values: { targetAmount, periodYear: year, note: values.note },
    })
    editing.value = false
  } catch (e) {
    serverError.value = (e as Error).message || 'Could not save that goal.'
  }
})

async function confirmRemove() {
  serverError.value = ''
  try {
    await remove.mutateAsync({ customerKey: props.customerKey, periodYear: year })
    confirmingRemove.value = false
    editing.value = false
  } catch (e) {
    serverError.value = (e as Error).message || 'Could not remove that goal.'
  }
}

/* ---- display ------------------------------------------------------------ */

/** "$49,300 in · 58% of goal" — the one line that answers the question. */
const progressLine = computed(() => {
  const g = goal.value
  if (!g) return ''
  return `${money(g.revenue_to_date)} in · ${Math.round(g.attainment_pct)}% of goal`
})

const paceText = computed(() => paceLabel(goal.value))
const paceHelp = computed(() => paceBasisLabel(goal.value))

const behind = computed(() => goal.value?.on_track === false)

/** "$35,700 to go, 150 days left" — what is actually left to do. */
const remainingLine = computed(() => {
  const g = goal.value
  if (!g) return ''
  if (g.gap_to_goal <= 0) {
    return `Goal met · ${money(g.revenue_to_date - g.target_amount)} over`
  }
  return `${money(g.gap_to_goal)} to go · ${g.days_remaining} days left in ${g.period_year}`
})

const setByLine = computed(() => {
  const g = goal.value
  if (!g?.updated_at) return ''
  return `Set ${shortDate(g.updated_at)}`
})
</script>

<template>
  <section class="border-line border-t pt-4">
    <div class="flex items-baseline justify-between gap-3">
      <h3 class="u-label text-ink">Goal · {{ year }}</h3>
      <button
        v-if="!editing && goal && session.canWrite"
        type="button"
        class="tap-target text-ink-2 inline-flex items-center px-1 text-[13px] font-semibold underline underline-offset-2"
        @click="startEdit"
      >
        Edit
      </button>
    </div>

    <!-- Loading is quiet: the tiles above already told the rep the card is
         alive, and a second skeleton here would just flicker. -->
    <p v-if="query.isPending.value" class="text-muted mt-2 text-sm">Checking…</p>

    <!-- A goal is optional. An error reading it says so and gets out of the
         way rather than taking the Performance card down with it. -->
    <p v-else-if="query.error.value && !editing" class="text-muted mt-2 text-sm">
      Goal unavailable right now.
    </p>

    <template v-else-if="goal && !editing">
      <p class="u-display text-ink mt-1 text-3xl tabular-nums">
        {{ money(goal.target_amount) }}
      </p>

      <GoalProgressBar
        class="mt-2"
        :attainment-pct="goal.attainment_pct"
        :expected-pct="goal.expected_pct"
        :on-track="goal.on_track"
        :label="`Goal progress for ${goal.period_year}`"
      />

      <p class="text-ink-2 mt-2 text-[15px]">
        {{ progressLine }}
        <span v-if="paceText" :class="behind ? 'text-accent font-semibold' : 'text-muted'">
          · {{ paceText }}
        </span>
      </p>
      <p class="text-muted mt-0.5 text-[13px]">{{ remainingLine }}</p>
      <p v-if="paceHelp" class="text-muted mt-0.5 text-xs">{{ paceHelp }}</p>

      <p v-if="goal.note" class="text-ink-2 mt-2 text-sm italic">“{{ goal.note }}”</p>

      <!-- The ERP's number stays visible. The drift between the two is the
           interesting part, and it is what a push-back to Visual would
           reconcile (023 header). -->
      <p class="text-muted mt-2 text-[13px]">
        <template v-if="erpGoal != null">ERP goal {{ money(erpGoal) }}</template>
        <template v-else>No goal in the ERP</template>
        <template v-if="setByLine"> · {{ setByLine }}</template>
      </p>
    </template>

    <!-- Empty state: the ERP number is the anchor, and "Set a goal" is the
         one thing to do. -->
    <template v-else-if="!goal && !editing">
      <p class="text-muted mt-1 text-[15px]">
        <template v-if="erpGoal != null">
          No goal of your own yet. The ERP has {{ money(erpGoal) }} for
          {{ year }}.
        </template>
        <template v-else>
          No goal set for {{ year }} — here or in the ERP.
        </template>
      </p>
      <AppButton v-if="session.canWrite" class="mt-3" variant="secondary" @click="startEdit">
        Set a goal
      </AppButton>
    </template>

    <!-- Inline editor -->
    <form
      v-if="editing"
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
        <AppButton variant="ghost" @click="cancelEdit">Cancel</AppButton>
        <AppButton
          v-if="goal && !confirmingRemove"
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
  </section>
</template>
