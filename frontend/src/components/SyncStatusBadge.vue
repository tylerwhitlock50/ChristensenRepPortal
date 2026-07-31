<script setup lang="ts">
/**
 * The entire sync UI budget — TECH_STACK §2.5 caps this at "a single
 * pending-count badge", and this is it. No sync log, no per-item drawer, no
 * progress bars.
 *
 * It renders nothing when the queue is empty, which is almost always. When it
 * does appear it says the true thing in the rep's words: the survey is saved,
 * it is on this phone, and it goes up on its own. That sentence is the whole
 * point of the offline work — a rep who thinks a survey vanished stops using
 * the app and never tells anyone.
 */
import { computed } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import { useSubmitQueue } from '@/lib/submitQueue'

withDefaults(
  defineProps<{
    /** Chip only, for a header or nav bar. Full sentence everywhere else. */
    compact?: boolean
  }>(),
  { compact: false },
)

const { pending, stuck, isFlushing, online, flush } = useSubmitQueue()

const message = computed(() => {
  const n = pending.value
  const thing = n === 1 ? 'visit' : 'visits'
  if (!online.value) {
    return `Saved — ${n} ${thing} will sync when you're back online.`
  }
  if (isFlushing.value) return `Syncing ${n} ${thing}…`
  if (stuck.value > 0) {
    return `${n} ${thing} still waiting to sync. Nothing is lost — they're saved on this phone.`
  }
  return `${n} ${thing} waiting to sync.`
})

// Ember is reserved for "late". A survey that has failed repeatedly qualifies;
// one sitting in the queue on a dead LTE cell does not.
const tone = computed(() => (stuck.value > 0 ? 'late' : 'neutral'))

const canRetry = computed(
  () => online.value && !isFlushing.value && pending.value > 0,
)
</script>

<template>
  <div v-if="pending > 0" role="status" aria-live="polite">
    <AppBadge v-if="compact" :tone="tone">
      {{ pending }}
      <span class="sr-only">{{ message }}</span>
      <span aria-hidden="true">waiting</span>
    </AppBadge>

    <div
      v-else
      class="border-line bg-surface flex flex-wrap items-center gap-x-3 gap-y-1 border px-3 py-2"
    >
      <AppBadge :tone="tone">{{ pending }}</AppBadge>
      <p class="text-ink min-w-0 flex-1 text-sm leading-snug">{{ message }}</p>
      <button
        v-if="canRetry"
        type="button"
        class="font-label text-ink tap-target text-[13px] font-semibold tracking-[0.1em] uppercase underline underline-offset-4"
        @click="flush({ force: true })"
      >
        Try now
      </button>
    </div>
  </div>
</template>
