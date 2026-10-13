<script setup lang="ts">
import { computed, ref, useId, watch } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import {
  useAiFeedback,
  type FeedbackSurface,
  type FeedbackVerdict,
} from '@/composables/useAiFeedback'
import { useSessionStore } from '@/stores/session'

/**
 * "Was this useful?" under an AI brief. Two answers, and an optional line
 * of why when the answer is "something's off" — the line an admin reads
 * when deciding whether a prompt change helped.
 *
 * Reusable: the territory brief mounts it today (SalesBriefCard); the
 * account summary card passes surface="account_summary" and the
 * customer_key. Renders nothing while viewing as a rep (the table refuses
 * those writes), without a brief to judge, or on a database without
 * public.ai_feedback.
 */
const props = withDefaults(
  defineProps<{
    surface: FeedbackSurface
    /** '' for the territory brief; the customer_key for an account summary. */
    subjectKey?: string
    /** The brief's generated_at and prompt_version. */
    generatedAt: string | null | undefined
    promptVersion?: string | null
    readOnly?: boolean
  }>(),
  { subjectKey: '', promptVersion: null, readOnly: false },
)

const session = useSessionStore()
const fb = useAiFeedback({
  surface: props.surface,
  subjectKey: () => props.subjectKey,
  generatedAt: () => props.generatedAt,
  promptVersion: () => props.promptVersion,
})

// Also hidden until the "did I already vote?" read answers: on a database
// without the table the row would otherwise flash up and vanish under the
// brief, and a tap before the answer would add a second vote.
const hidden = computed(
  () =>
    props.readOnly ||
    !session.canWrite ||
    !props.generatedAt ||
    fb.query.isPending.value ||
    fb.unavailable.value,
)

const verdict = computed(() => fb.current.value?.verdict ?? null)
const note = ref('')
const noteSent = ref(false)
const failed = ref('')

// A new brief is a new question.
watch(
  () => props.generatedAt,
  () => {
    note.value = ''
    noteSent.value = false
    failed.value = ''
  },
)

async function choose(v: FeedbackVerdict) {
  failed.value = ''
  if (verdict.value === v || fb.vote.isPending.value) return
  try {
    await fb.vote.mutateAsync(v)
  } catch {
    // A missing table hides the whole row (unavailable); anything else is
    // worth one quiet line — a lost thumb is not worth an error card.
    failed.value = "Couldn't save that. Try again in a moment."
  }
}

async function sendNote() {
  failed.value = ''
  if (!note.value.trim()) return
  try {
    await fb.addNote.mutateAsync(note.value)
    noteSent.value = true
  } catch {
    failed.value = "Couldn't save the note. Try again in a moment."
  }
}

const groupId = useId()
const noteId = useId()
const optionClass = (selected: boolean) =>
  selected
    ? 'bg-ink text-canvas border-ink'
    : 'border-line-2 text-ink-2 hover:border-ink bg-transparent'
</script>

<template>
  <div v-if="!hidden" class="border-line mt-4 border-t pt-3">
    <p :id="groupId" class="text-muted text-[13px]">Was this useful?</p>
    <div class="mt-2 flex flex-wrap gap-2" role="group" :aria-labelledby="groupId">
      <button
        type="button"
        class="tap-target font-label inline-flex items-center border px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
        :class="optionClass(verdict === 'helpful')"
        :aria-pressed="verdict === 'helpful'"
        :disabled="fb.vote.isPending.value"
        @click="choose('helpful')"
      >
        Helpful
      </button>
      <button
        type="button"
        class="tap-target font-label inline-flex items-center border px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
        :class="optionClass(verdict === 'wrong')"
        :aria-pressed="verdict === 'wrong'"
        :disabled="fb.vote.isPending.value"
        @click="choose('wrong')"
      >
        Something's off
      </button>
    </div>

    <p v-if="failed" role="status" class="text-muted mt-2 text-[13px]">{{ failed }}</p>
    <p v-else-if="verdict === 'helpful'" role="status" class="text-muted mt-2 text-[13px]">
      Thanks — noted.
    </p>

    <template v-if="verdict === 'wrong'">
      <p v-if="noteSent || fb.current.value?.note" role="status" class="text-muted mt-2 text-[13px]">
        Thanks — that goes to the people who tune the brief.
      </p>
      <form v-else class="mt-3 space-y-2" @submit.prevent="sendNote">
        <label :for="noteId" class="text-ink-2 block text-[13px]">
          What looked wrong? (optional)
        </label>
        <textarea
          :id="noteId"
          v-model="note"
          rows="2"
          maxlength="1000"
          class="field py-2.5"
          placeholder="e.g. the backlog figure is too high"
        />
        <AppButton
          type="submit"
          variant="ghost"
          :loading="fb.addNote.isPending.value"
          :disabled="!note.trim()"
        >
          Send
        </AppButton>
      </form>
    </template>
  </div>
</template>
