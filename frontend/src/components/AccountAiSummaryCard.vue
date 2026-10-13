<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { useAiSummary, useGenerateAiSummary } from '@/composables/useAiSummary'

/**
 * The account Sales Brief — cached copy first, regeneration on request only.
 * HEADLINES-first structure comes from the prompt (v2).
 *
 * Cached row first, always. The button is an explicit choice — nothing fires
 * a generation on mount, and an account with too little history says so
 * instead of inventing a paragraph. AccountView's "Summary" chip only
 * scrolls here; it never generates either (a paid call).
 *
 * `canWrite` false (an admin viewing as a rep) hides the button: generating
 * caches the result to public.ai_summaries, and the database refuses that
 * write while impersonating (20260816140000) — the same reason the page
 * drops its write chips. The cached summary itself still shows.
 *
 * The `footer` slot is for things that hang off the summary shown — rating
 * it, say. It renders only while there is a summary, and gets that row.
 */
const props = withDefaults(
  defineProps<{
    customerKey: string
    canWrite?: boolean
  }>(),
  { canWrite: true },
)

const key = computed(() => props.customerKey)
const ai = useAiSummary(key)
const generate = useGenerateAiSummary()
const aiNotice = ref('')
const aiError = ref('')

async function runSummary() {
  aiNotice.value = ''
  aiError.value = ''
  try {
    const result = await generate.mutateAsync(props.customerKey)
    if (result.status === 'insufficient_data') {
      aiNotice.value =
        result.message ??
        "There isn't enough activity on this account to summarize yet. Log a visit or a call and try again."
    } else if (result.status === 'cooldown') {
      const mins = Math.max(1, Math.ceil((result.retry_after_seconds ?? 60) / 60))
      aiNotice.value = `Just refreshed. You can regenerate in about ${mins} minute${mins === 1 ? '' : 's'}.`
    } else if (result.status === 'cached') {
      aiNotice.value = 'Nothing has changed since the last summary.'
    }
  } catch (e) {
    aiError.value =
      (e as Error).message || 'Could not build the summary right now.'
  }
}

// The router reuses the account page across /accounts/:customerKey changes:
// account A's notice must not read as account B's.
watch(key, () => {
  aiNotice.value = ''
  aiError.value = ''
})
</script>

<template>
  <AppCard>
    <template #header>
      <h2 class="u-label text-ink">Sales Brief</h2>
      <AppButton
        v-if="canWrite"
        variant="ghost"
        :loading="generate.isPending.value"
        @click="runSummary"
      >
        {{ ai.hasSummary.value ? 'Regenerate' : 'Summarize' }}
      </AppButton>
    </template>

    <AsyncState
      :loading="ai.isPending.value"
      :error="ai.error.value"
      :has-data="ai.data.value !== undefined"
      :updated-at="ai.dataUpdatedAt.value"
      :rows="2"
      @retry="ai.refetch()"
    >
      <div>
        <template v-if="ai.hasSummary.value">
          <p class="text-ink-2 text-[15px] leading-relaxed whitespace-pre-wrap">
            {{ ai.summary.value?.content }}
          </p>
          <p class="text-muted mt-2 text-xs">{{ ai.asOf.value }}</p>
        </template>
        <p v-else-if="canWrite" class="text-muted text-[15px] leading-relaxed">
          No summary yet. Tap Summarize and we'll read this account's numbers,
          recent orders and your notes back to you in a few sentences.
        </p>
        <p v-else class="text-muted text-[15px] leading-relaxed">
          No summary yet.
        </p>

        <p v-if="aiNotice" class="text-muted mt-3 text-sm">{{ aiNotice }}</p>
        <p
          v-if="aiError"
          role="alert"
          class="text-danger mt-3 text-sm font-medium"
        >
          {{ aiError }}
        </p>
      </div>
    </AsyncState>

    <template v-if="$slots.footer && ai.summary.value" #footer>
      <slot name="footer" :summary="ai.summary.value" />
    </template>
  </AppCard>
</template>
