<script setup lang="ts">
import { computed, ref } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import {
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
}>()

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

const priorityTone = computed(() => {
  if (overdue.value) return 'high'
  const p = props.rec.priority as RecPriority
  return p === 'high' ? 'high' : p === 'low' ? 'neutral' : 'warn'
})

const label = computed(() => props.accountName || props.rec.customer_key)

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
    errorMessage.value = (e as Error).message || 'Could not save that.'
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
    errorMessage.value = (e as Error).message || 'Could not save that.'
  }
}
</script>

<template>
  <article class="rounded-xl border border-zinc-200 bg-white">
    <div class="p-4">
      <div class="mb-2 flex flex-wrap items-center gap-2">
        <AppBadge :tone="priorityTone" dot>
          {{ overdue ? dueLabel(rec.due_date) : rec.priority }}
        </AppBadge>
        <AppBadge v-if="rec.status === 'acted'" tone="info">
          Acted — needs outcome
        </AppBadge>
        <AppBadge v-if="rec.source === 'admin'" tone="neutral">
          From sales ops
        </AppBadge>
        <span
          v-if="rec.due_date && !overdue"
          class="text-xs text-zinc-500"
        >
          {{ dueLabel(rec.due_date) }}
        </span>
      </div>

      <h3 class="text-base font-semibold text-zinc-900">{{ rec.title }}</h3>
      <p v-if="rec.reason" class="mt-1 text-sm leading-relaxed text-zinc-600">
        {{ rec.reason }}
      </p>

      <RouterLink
        v-if="!hideAccountLink"
        :to="{ name: 'account', params: { customerKey: rec.customer_key } }"
        class="mt-2 inline-block text-sm font-medium text-zinc-900 underline underline-offset-2"
      >
        {{ label }}
      </RouterLink>
    </div>

    <!-- Inline panels, never a modal (TECH_STACK §2.4) -->
    <div v-if="panel === 'act'" class="border-t border-zinc-100 p-4">
      <fieldset>
        <legend class="mb-2 text-sm font-medium text-zinc-700">
          What did you do?
        </legend>
        <div class="flex flex-wrap gap-2">
          <button
            v-for="t in ACTION_TYPES"
            :key="t"
            type="button"
            class="tap-target rounded-lg border px-3 text-sm font-medium"
            :class="
              actionType === t
                ? 'border-zinc-900 bg-zinc-900 text-white'
                : 'border-zinc-300 bg-white text-zinc-700'
            "
            :aria-pressed="actionType === t"
            @click="actionType = t"
          >
            {{ ACTION_LABELS[t] }}
          </button>
        </div>
      </fieldset>

      <label class="mt-3 block">
        <span class="mb-1 block text-sm font-medium text-zinc-700">
          Note <span class="font-normal text-zinc-500">(optional)</span>
        </span>
        <textarea
          v-model="note"
          rows="3"
          class="w-full rounded-lg border border-zinc-300 p-3 text-sm outline-none focus:border-zinc-900"
          placeholder="What came out of it?"
        />
      </label>

      <p v-if="errorMessage" role="alert" class="mt-2 text-sm text-red-700">
        {{ errorMessage }}
      </p>

      <div class="mt-3 flex gap-2">
        <AppButton :loading="logAction.isPending.value" @click="submitAction">
          Save
        </AppButton>
        <AppButton variant="ghost" @click="reset">Cancel</AppButton>
      </div>
    </div>

    <div v-else-if="panel === 'close'" class="border-t border-zinc-100 p-4">
      <fieldset>
        <legend class="mb-2 text-sm font-medium text-zinc-700">
          What was the outcome?
        </legend>
        <div class="grid gap-2 sm:grid-cols-2">
          <button
            v-for="o in REC_OUTCOMES"
            :key="o"
            type="button"
            class="tap-target rounded-lg border px-3 text-left text-sm font-medium"
            :class="
              outcome === o
                ? 'border-zinc-900 bg-zinc-900 text-white'
                : 'border-zinc-300 bg-white text-zinc-700'
            "
            :aria-pressed="outcome === o"
            @click="outcome = o"
          >
            {{ OUTCOME_LABELS[o] }}
          </button>
        </div>
      </fieldset>

      <label class="mt-3 block">
        <span class="mb-1 block text-sm font-medium text-zinc-700">
          Note <span class="font-normal text-zinc-500">(optional)</span>
        </span>
        <textarea
          v-model="note"
          rows="2"
          class="w-full rounded-lg border border-zinc-300 p-3 text-sm outline-none focus:border-zinc-900"
        />
      </label>

      <p v-if="errorMessage" role="alert" class="mt-2 text-sm text-red-700">
        {{ errorMessage }}
      </p>

      <div class="mt-3 flex flex-wrap gap-2">
        <AppButton
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

    <div v-else class="flex gap-2 border-t border-zinc-100 p-3">
      <AppButton variant="secondary" @click="panel = 'act'">
        Log action
      </AppButton>
      <AppButton variant="ghost" @click="panel = 'close'">
        Close with outcome
      </AppButton>
    </div>
  </article>
</template>
