<script setup lang="ts">
import { computed, ref } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import { useSessionStore } from '@/stores/session'
import {
  friendlyRecError,
  isMission,
  useLogAction,
  useResolveRecommendation,
  type Recommendation,
} from '@/composables/useRecommendations'
import {
  ACTION_LABELS,
  ACTION_TYPES,
  OUTCOME_LABELS,
  REC_OUTCOMES,
  type ActionType,
  type RecOutcome,
  type RecPriority,
} from '@/types/domain'
import { daysUntilDue, dueLabel } from '@/lib/format'

const props = defineProps<{
  rec: Recommendation
  /** Shown instead of the raw customer_key when the ERP name resolved. */
  accountName?: string
  /** Hide the account link when the card is already on that account's page. */
  hideAccountLink?: boolean
  /** Recent pre-generated AI headline; falls back to `reason` when absent. */
  headline?: string
}>()

const session = useSessionStore()
const body = computed(() => props.headline || props.rec.reason)

type Panel = 'none' | 'act' | 'close'
const panel = ref<Panel>('none')
const actionType = ref<ActionType>('call')
const note = ref('')
const outcome = ref<RecOutcome | null>(null)
const errorMessage = ref('')

const logAction = useLogAction()
const resolve = useResolveRecommendation()

const overdue = computed(() => {
  const d = daysUntilDue(props.rec.due_date)
  return d != null && d < 0
})

const badgeTone = computed(() => {
  if (overdue.value) return 'late'
  const p = props.rec.priority as RecPriority
  return p === 'high' ? 'high' : 'neutral'
})

/* Ember rail = late, ink rail = acted/needs outcome, hairline otherwise. */
const rail = computed(() => {
  if (overdue.value) return 'bg-accent'
  if (props.rec.status === 'acted') return 'bg-ink'
  return 'bg-line-2'
})

const label = computed(() => props.accountName || props.rec.customer_key)

/* A visit-required mission is cleared by the survey, not the plain close
   panel — the DB trigger enforces it, this just routes the rep to the right
   path first. Once it's 'acted' (a survey happened) close opens as usual. */
const needsSurvey = computed(
  () => !!props.rec.requires_visit && props.rec.status === 'open',
)
const surveyTo = computed(() => ({
  name: 'account' as const,
  params: { customerKey: props.rec.customer_key },
  query: { survey: String(props.rec.id) },
}))

function reset() {
  panel.value = 'none'
  note.value = ''
  outcome.value = null
  errorMessage.value = ''
}

async function submitAction() {
  errorMessage.value = ''
  try {
    await logAction.mutateAsync({
      customerKey: props.rec.customer_key,
      actionType: actionType.value,
      note: note.value,
      recommendationId: props.rec.id,
    })
    reset()
  } catch (e) {
    errorMessage.value = friendlyRecError(e)
  }
}

async function submitClose(status: 'closed' | 'dismissed') {
  if (!outcome.value) {
    errorMessage.value = 'Pick an outcome first.'
    return
  }
  errorMessage.value = ''
  try {
    await resolve.mutateAsync({
      id: props.rec.id,
      customerKey: props.rec.customer_key,
      status,
      outcome: outcome.value,
      outcomeNote: note.value,
    })
    reset()
  } catch (e) {
    errorMessage.value = friendlyRecError(e)
  }
}
</script>

<template>
  <article class="border-line bg-surface flex border">
    <span class="w-[3px] shrink-0" :class="rail" aria-hidden="true" />
    <div class="min-w-0 flex-1">
      <div class="p-4">
        <div class="mb-2 flex flex-wrap items-center gap-2">
          <AppBadge :tone="badgeTone">
            {{ overdue ? dueLabel(rec.due_date) : rec.priority }}
          </AppBadge>
          <AppBadge v-if="rec.status === 'acted'" tone="good">
            Acted — needs outcome
          </AppBadge>
          <AppBadge v-if="isMission(rec)" tone="neutral">Mission</AppBadge>
          <AppBadge v-if="rec.requires_visit" tone="neutral">
            Visit survey required
          </AppBadge>
          <span
            v-if="rec.due_date && !overdue"
            class="font-label text-muted text-xs tracking-[0.08em]"
          >
            {{ dueLabel(rec.due_date) }}
          </span>
        </div>

        <h3 class="text-ink text-[17px] font-semibold">{{ rec.title }}</h3>
        <p v-if="body" class="text-ink-2 mt-1 text-[15px] leading-relaxed">
          {{ body }}
        </p>

        <RouterLink
          v-if="!hideAccountLink"
          :to="{ name: 'account', params: { customerKey: rec.customer_key } }"
          class="text-ink mt-2 inline-block text-[15px] font-semibold underline underline-offset-4"
        >
          {{ label }}
        </RouterLink>
      </div>

      <!-- Inline panels, never a modal (TECH_STACK §2.4) -->
      <div v-if="panel === 'act'" class="border-line border-t p-4">
        <fieldset>
          <legend class="u-label mb-2">What did you do?</legend>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="t in ACTION_TYPES"
              :key="t"
              type="button"
              class="inline-flex min-h-11 items-center rounded-[2px] px-4 text-[15px] font-semibold"
              :class="
                actionType === t
                  ? 'bg-ink text-canvas'
                  : 'border-line-2 text-ink-2 border bg-transparent'
              "
              :aria-pressed="actionType === t"
              @click="actionType = t"
            >
              {{ ACTION_LABELS[t] }}
            </button>
          </div>
        </fieldset>

        <label class="mt-3 block">
          <span class="u-label mb-1.5 block">
            Note <span class="normal-case">(optional)</span>
          </span>
          <textarea
            v-model="note"
            rows="3"
            class="field h-auto p-3.5"
            placeholder="What came out of it?"
          />
        </label>

        <p v-if="errorMessage" role="alert" class="text-danger mt-2 text-sm font-medium">
          {{ errorMessage }}
        </p>

        <div class="mt-3 flex gap-2">
          <AppButton
            variant="primary"
            :loading="logAction.isPending.value"
            @click="submitAction"
          >
            Save
          </AppButton>
          <AppButton variant="ghost" @click="reset">Cancel</AppButton>
        </div>
      </div>

      <div v-else-if="panel === 'close'" class="border-line border-t p-4">
        <fieldset>
          <legend class="u-label mb-2">What was the outcome?</legend>
          <div class="grid gap-2 sm:grid-cols-2">
            <button
              v-for="o in REC_OUTCOMES"
              :key="o"
              type="button"
              class="inline-flex min-h-11 items-center rounded-[2px] px-4 text-left text-[15px] font-semibold"
              :class="
                outcome === o
                  ? 'bg-ink text-canvas'
                  : 'border-line-2 text-ink-2 border bg-transparent'
              "
              :aria-pressed="outcome === o"
              @click="outcome = o"
            >
              {{ OUTCOME_LABELS[o] }}
            </button>
          </div>
        </fieldset>

        <label class="mt-3 block">
          <span class="u-label mb-1.5 block">
            Note <span class="normal-case">(optional)</span>
          </span>
          <textarea v-model="note" rows="2" class="field h-auto p-3.5" />
        </label>

        <p v-if="errorMessage" role="alert" class="text-danger mt-2 text-sm font-medium">
          {{ errorMessage }}
        </p>

        <div class="mt-3 flex flex-wrap gap-2">
          <AppButton
            variant="primary"
            :loading="resolve.isPending.value"
            :disabled="!outcome"
            @click="submitClose('closed')"
          >
            Close it out
          </AppButton>
          <AppButton
            variant="secondary"
            :disabled="!outcome"
            @click="submitClose('dismissed')"
          >
            Dismiss
          </AppButton>
          <AppButton variant="ghost" @click="reset">Cancel</AppButton>
        </div>
      </div>

      <!-- A visit-required mission routes to the survey; the DB would reject
           a surveyless close anyway, so don't offer it. -->
      <div
        v-else-if="needsSurvey && session.canWrite"
        class="border-line flex gap-2 border-t p-3"
      >
        <RouterLink :to="surveyTo" class="btn-primary text-[15px]">
          Do the visit survey
        </RouterLink>
        <AppButton variant="ghost" @click="panel = 'act'">
          Log action
        </AppButton>
      </div>

      <div v-else-if="session.canWrite" class="border-line flex gap-2 border-t p-3">
        <AppButton variant="secondary" @click="panel = 'act'">
          Log action
        </AppButton>
        <AppButton variant="ghost" @click="panel = 'close'">
          Close out
        </AppButton>
      </div>
    </div>
  </article>
</template>
