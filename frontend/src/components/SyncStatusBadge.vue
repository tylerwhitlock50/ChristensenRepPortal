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
 *
 * ── The compact chip has to carry that sentence ───────────────────────────
 * `compact` is the only variant the app actually mounts (AppShell, on every
 * screen). It used to be an inert AppBadge whose message was `sr-only` and
 * whose Retry button lived in the full variant nothing rendered — so a
 * sighted rep saw "2 waiting", could not tap it, could not learn why, and
 * could not force a send. It is a button now, opening the same sentence and
 * the same Try now in a panel under the header. That is still one badge; the
 * §2.5 budget is about not building a sync console, not about hiding the one
 * fact the rep needs.
 *
 * It also styles its own chip rather than using AppBadge: AppBadge's tones
 * are drawn for white cards, and `neutral` on the ink header measured 3.4:1.
 * `bg-ink-2 text-canvas` matches the initials chip beside it and clears AA.
 */
import { computed, ref, watch } from 'vue'
import { onClickOutside, onKeyStroke } from '@vueuse/core'
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

/** Same two tones as `tone`, drawn for the ink header instead of a card. */
const chipClass = computed(() =>
  stuck.value > 0 ? 'bg-accent text-[#20100A]' : 'bg-ink-2 text-canvas',
)

const canRetry = computed(
  () => online.value && !isFlushing.value && pending.value > 0,
)

const open = ref(false)
const root = ref<HTMLElement | null>(null)
onClickOutside(root, () => (open.value = false))
onKeyStroke('Escape', () => {
  open.value = false
})

// The wrapper unmounts the moment the queue drains, taking an open panel with
// it — but reset anyway so it doesn't reappear open on the next queued visit.
watch(pending, (n) => {
  if (n === 0) open.value = false
})
</script>

<template>
  <div v-if="pending > 0" ref="root" class="relative">
    <!-- The announcement lives here rather than on the button: the button's
         accessible name is static ("Sync status"), so a message that changes
         under it still has to reach a screen reader on its own. -->
    <span class="sr-only" role="status" aria-live="polite">{{ message }}</span>

    <template v-if="compact">
      <button
        type="button"
        class="tap-target flex items-center"
        aria-label="Sync status"
        :aria-expanded="open"
        aria-haspopup="dialog"
        @click="open = !open"
      >
        <span
          class="font-label inline-flex items-center gap-1.5 px-2.5 py-[5px] text-[13px] font-semibold tracking-[0.1em] uppercase"
          :class="chipClass"
        >
          {{ pending }}
          <span aria-hidden="true">waiting</span>
        </span>
      </button>

      <div
        v-if="open"
        role="dialog"
        aria-label="Sync status"
        class="border-line bg-surface text-ink absolute right-0 z-40 mt-2 w-72 border p-3 shadow-lg"
      >
        <p class="text-ink text-sm leading-snug">{{ message }}</p>
        <button
          v-if="canRetry"
          type="button"
          class="font-label text-ink tap-target mt-1 text-[13px] font-semibold tracking-[0.1em] uppercase underline underline-offset-4"
          @click="flush({ force: true })"
        >
          Try now
        </button>
      </div>
    </template>

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
