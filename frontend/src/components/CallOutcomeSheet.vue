<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import AppModal from '@/components/ui/AppModal.vue'
import AppButton from '@/components/ui/AppButton.vue'
import {
  CALL_OUTCOMES,
  CALL_OUTCOME_LABELS,
  useQuickCallLog,
  type CallOutcome,
} from '@/composables/useQuickCallLog'

/**
 * "How did the call go?" — the second half of the quick call log
 * (useQuickCallLog.ts). Mounted once, in App.vue, so it can finish an
 * attempt started on any page.
 *
 * Two taps at most: an optional "Remind me next week", then an outcome.
 * Every choice is optional — "Not now" logs nothing — because this is a
 * convenience for the rep, not a form they owe anyone.
 */
const log = useQuickCallLog()
const remind = ref(false)
const choosing = ref<CallOutcome | null>(null)

onMounted(() => log.install())
// A restored attempt (tab reloaded mid-call) waits for the flags to load.
watch(log.enabled, (on) => {
  if (on) log.recheckRestored()
})
watch(log.sheetOpen, (open) => {
  if (open) {
    remind.value = false
    choosing.value = null
  }
})

const open = computed({
  get: () => log.sheetOpen.value && (log.enabled.value || !!log.error.value),
  set: (v: boolean) => {
    if (!v) log.dismiss()
  },
})

const subtitle = computed(() => {
  const p = log.pending.value
  if (!p) return undefined
  return p.contactLabel ? `${p.customerName} · ${p.contactLabel}` : p.customerName
})

async function choose(outcome: CallOutcome) {
  choosing.value = outcome
  await log.logOutcome(outcome, remind.value)
  choosing.value = null
}
</script>

<template>
  <AppModal v-model:open="open" title="How did the call go?" :subtitle="subtitle">
    <p v-if="log.error.value" role="alert" class="text-danger mb-3 text-[15px] font-medium">
      {{ log.error.value }}
    </p>

    <template v-if="log.pending.value">
      <p class="text-ink-2 text-[15px] leading-relaxed">
        One tap adds it to the account's history. Skip it if you didn't get to call.
      </p>

      <!-- Optional, and only where reminders exist (feature.tasks). -->
      <button
        v-if="log.remindAvailable.value"
        type="button"
        role="switch"
        :aria-checked="remind"
        class="tap-target border-line mt-4 flex w-full items-center justify-between gap-3 border px-4 text-left"
        @click="remind = !remind"
      >
        <span class="text-ink text-[15px] font-semibold">Remind me next week</span>
        <span
          class="font-label text-[13px] font-semibold tracking-[0.12em] uppercase"
          :class="remind ? 'text-brand' : 'text-muted'"
        >
          {{ remind ? 'On' : 'Off' }}
        </span>
      </button>

      <div class="mt-4 grid gap-2">
        <AppButton
          v-for="o in CALL_OUTCOMES"
          :key="o"
          block
          :loading="log.saving.value && choosing === o"
          :disabled="log.saving.value"
          @click="choose(o)"
        >
          {{ CALL_OUTCOME_LABELS[o] }}
        </AppButton>
      </div>
    </template>

    <AppButton variant="ghost" block class="mt-4" :disabled="log.saving.value" @click="log.dismiss()">
      {{ log.pending.value ? "Not now — don't log it" : 'Close' }}
    </AppButton>
  </AppModal>
</template>
