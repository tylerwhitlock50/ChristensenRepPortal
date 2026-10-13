<script setup lang="ts">
import { computed } from 'vue'
import { format, isToday } from 'date-fns'
import AppButton from './AppButton.vue'
import { describeError } from '@/lib/supabase'

const props = withDefaults(
  defineProps<{
    loading?: boolean
    error?: unknown
    /** True when the query succeeded but returned nothing. */
    empty?: boolean
    emptyTitle?: string
    emptyBody?: string
    /** Skeleton rows to show while loading. */
    rows?: number
    /**
     * True once the data the slot renders has loaded at least once — usually
     * `query.data.value !== undefined`. TanStack keeps that data when a
     * background refetch fails and sets `error` beside it; with this set, the
     * rep keeps what is on screen (under a slim "Couldn't refresh" bar)
     * instead of losing it to the full error card. A refetch with data on
     * screen also skips the skeleton. Leave it unset and nothing changes.
     */
    hasData?: boolean
    /** When the shown data loaded, epoch ms — `query.dataUpdatedAt.value`. */
    updatedAt?: number
  }>(),
  { emptyTitle: 'Nothing here', rows: 3, hasData: false, updatedAt: undefined },
)

defineEmits<{ retry: [] }>()

/**
 * Every failed read in the app renders here, so this is the one place worth
 * translating Postgres into English. The branches live in lib/supabase.ts
 * because the composables' own `asDisplayError` helpers need the same
 * vocabulary.
 */
const message = computed(() => describeError(props.error))

/** "7:42 AM" today, "Oct 12, 7:42 AM" before that; null when unknown. */
const shownFrom = computed(() => {
  if (!props.updatedAt) return null
  const d = new Date(props.updatedAt)
  if (Number.isNaN(d.getTime())) return null
  return format(d, isToday(d) ? 'h:mm a' : 'MMM d, h:mm a')
})
</script>

<template>
  <!-- Skeletons are flat blocks at the real row height — no shimmer. -->
  <div v-if="loading && !hasData" class="space-y-2" aria-busy="true" aria-live="polite">
    <span class="sr-only">Loading</span>
    <div v-for="i in rows" :key="i" class="h-16 bg-[#E6E3DC]" />
  </div>

  <!-- Error gets the ember rail and a Retry button. -->
  <div
    v-else-if="error && !hasData"
    role="alert"
    class="border-line bg-surface border-l-accent border border-l-[3px] p-4"
  >
    <p class="text-ink text-[17px] font-semibold">Couldn't load this</p>
    <p class="text-ink-2 mt-1 text-[15px] leading-relaxed">{{ message }}</p>
    <AppButton variant="secondary" size="md" class="mt-3" @click="$emit('retry')">
      Try again
    </AppButton>
  </div>

  <template v-else>
    <!-- A failed refresh over good data: keep the data, say so quietly. No
         ember rail — nothing on screen is wrong, it is just older. The
         status role sits on the sentence alone, so a screen reader announces
         the message without reading the button into it. -->
    <div
      v-if="error"
      class="border-line bg-surface mb-2 flex items-center justify-between gap-3 border pl-3"
    >
      <p role="status" class="text-muted text-[13px] leading-snug">
        Couldn't refresh.<template v-if="shownFrom"> Showing data from {{ shownFrom }}</template>
      </p>
      <button
        type="button"
        class="tap-target font-label text-ink shrink-0 px-3 text-[13px] font-semibold tracking-[0.12em] uppercase hover:underline"
        @click="$emit('retry')"
      >
        Retry
      </button>
    </div>

    <!-- Empty states: a headline in display caps and one sentence. -->
    <div v-if="empty" class="px-4 py-10 text-center">
      <p class="u-display text-ink text-2xl">{{ emptyTitle }}</p>
      <p v-if="emptyBody" class="text-muted mx-auto mt-2 max-w-xs text-[15px] leading-relaxed">
        {{ emptyBody }}
      </p>
      <div class="mt-5">
        <slot name="empty-action" />
      </div>
    </div>

    <slot v-else />
  </template>
</template>
