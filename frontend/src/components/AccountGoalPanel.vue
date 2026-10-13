<script setup lang="ts">
import { computed, ref, shallowRef, watch } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import { useSessionStore } from '@/stores/session'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import { useAccount } from '@/composables/useAccounts'
import {
  currentGoalYear,
  paceBasisLabel,
  paceLabel,
  useAccountGoal,
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

/**
 * The form (and zod + vee-validate with it, about half of the account
 * page's code) downloads on the first tap of Edit or Set a goal, not with
 * the page. Most visits to an account never open it. Loaded by hand rather
 * than through defineAsyncComponent, whose failed load sticks for the life
 * of the page: here a tap after the signal comes back simply tries again.
 */
type GoalFormComponent = (typeof import('@/components/AccountGoalForm.vue'))['default']
const GoalForm = shallowRef<GoalFormComponent | null>(null)
const editing = ref(false)
const formUnavailable = ref(false)

async function startEdit() {
  formUnavailable.value = false
  editing.value = true
  if (GoalForm.value) return
  try {
    GoalForm.value = (await import('@/components/AccountGoalForm.vue')).default
  } catch {
    editing.value = false
    formUnavailable.value = true
  }
}

// Navigating between accounts reuses this component; a half-typed goal must
// not follow the rep to the next dealer. Closing unmounts the form, which
// drops whatever was typed.
watch(key, () => {
  editing.value = false
  formUnavailable.value = false
})

/* ---- display ------------------------------------------------------------ */

/** "$49,300 in · 58% of goal" — the one line that answers the question. */
const progressLine = computed(() => {
  const g = goal.value
  if (!g) return ''
  return `${money(g.revenue_to_date)} in · ${Math.round(g.attainment_pct)}% of goal`
})

const paceText = computed(() => paceLabel(goal.value))
const paceHelp = computed(() => paceBasisLabel(goal.value))

/**
 * ERP-sourced goals (dim_customer's USER_3 default, 20260817140000) have no
 * account_goals row: there is nothing to remove, and "Edit" means "set your
 * own number over the ERP's", not "change the ERP".
 */
const isErpGoal = computed(() => goal.value?.goal_source === 'erp')

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
         way rather than taking the Performance card down with it. A failed
         background refresh keeps the goal already on screen. -->
    <p
      v-else-if="query.error.value && query.data.value === undefined && !editing"
      class="text-muted mt-2 text-sm"
    >
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
           reconcile (023 header). When the ERP number IS the goal there is
           no drift to show — say where it came from instead. -->
      <p class="text-muted mt-2 text-[13px]">
        <template v-if="isErpGoal">This is the ERP's goal — edit to set your own.</template>
        <template v-else-if="erpGoal != null">ERP goal {{ money(erpGoal) }}</template>
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

    <p v-if="formUnavailable" role="alert" class="text-muted mt-2 text-sm">
      Couldn't open the goal editor. Check your signal and tap again.
    </p>

    <!-- Inline editor -->
    <template v-if="editing">
      <component
        :is="GoalForm"
        v-if="GoalForm"
        :customer-key="customerKey"
        :year="year"
        :goal="goal"
        :erp-goal="erpGoal"
        @close="editing = false"
      />
      <p v-else class="text-muted mt-3 text-sm">Opening…</p>
    </template>
  </section>
</template>
