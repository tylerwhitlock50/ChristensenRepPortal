<script setup lang="ts">
import { computed, ref } from 'vue'
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
} from '@/types/domain'
import { daysUntilDue, dueLabel } from '@/lib/format'

/**
 * The top-ranked open recommendation. Ink-filled, full-bleed, only ever one
 * on screen — everything below it degrades to the compact RecommendationCard.
 */
const props = defineProps<{
  rec: Recommendation
  accountName?: string
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
  <article class="bg-ink text-canvas">
    <div class="p-4 sm:p-5">
      <div class="flex flex-wrap items-center gap-2">
        <span
          v-if="overdue"
          class="bg-accent font-label px-2 py-1 text-xs font-semibold tracking-[0.12em] text-[#20100A] uppercase"
        >
          {{ dueLabel(rec.due_date) }}
        </span>
        <span
          class="font-label text-xs font-semibold tracking-[0.14em] text-[#8E8A80] uppercase"
        >
          Do this first
        </span>
      </div>

      <h2 class="u-display mt-3 text-3xl">{{ rec.title }}</h2>
      <p v-if="rec.reason" class="mt-2 text-[15px] leading-relaxed text-[#B4B0A5]">
        {{ rec.reason }}
      </p>

      <RouterLink
        :to="{ name: 'account', params: { customerKey: rec.customer_key } }"
        class="text-canvas mt-2 inline-block text-[15px] font-semibold underline underline-offset-4"
      >
        {{ label }}
      </RouterLink>

      <div v-if="panel === 'none'" class="mt-4 flex gap-2">
        <AppButton variant="primary" class="flex-1" @click="panel = 'act'">
          Log action
        </AppButton>
        <button
          type="button"
          class="tap-target font-label rounded-[2px] border border-[#4A4D44] px-4 text-[15px] font-semibold tracking-[0.12em] uppercase hover:border-canvas"
          @click="panel = 'close'"
        >
          Close out
        </button>
      </div>
    </div>

    <!-- Panels open inline, in place, on a light surface — never a modal. -->
    <div v-if="panel === 'act'" class="bg-surface text-ink border-t-2 border-t-[#3A3D35] p-4">
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

    <div
      v-else-if="panel === 'close'"
      class="bg-surface text-ink border-t-2 border-t-[#3A3D35] p-4"
    >
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
  </article>
</template>
