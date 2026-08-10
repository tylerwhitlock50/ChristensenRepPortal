<script setup lang="ts">
import { ref, useId } from 'vue'

/**
 * AppCard's chrome with a disclosure header: the whole header is the toggle,
 * the body only exists while it's open.
 *
 * Collapsed by default. Use it for the long, scannable-on-demand blocks on the
 * account page — a rep arrives wanting the summary, and a card that renders 20
 * table rows the moment the page loads pushes everything under it off screen.
 * The `hint` is what they read to decide whether to open it, so give it a
 * count and a date rather than a static label.
 *
 * The body is v-if, not v-show: collapsed means no rows in the DOM at all. The
 * panel div itself stays mounted so `aria-controls` always resolves, and it
 * drops its padding while empty so a closed card is exactly its header tall.
 */
withDefaults(
  defineProps<{
    title: string
    /** Right-aligned summary in the header — a count, a date, a status. */
    hint?: string
    padded?: boolean
  }>(),
  { padded: true },
)

const open = ref(false)
const panelId = useId()
</script>

<template>
  <section class="border-line bg-surface border">
    <h2>
      <!-- Negative-margin-free: this button IS the header, so it owns the
           padding and the hover/tap area covers the full width. The bottom
           rule only exists when there is something below it to separate. -->
      <button
        type="button"
        class="tap-target hover:bg-canvas flex w-full items-center justify-between gap-3 px-4 py-3 text-left"
        :class="open ? 'border-line border-b' : ''"
        :aria-expanded="open"
        :aria-controls="panelId"
        @click="open = !open"
      >
        <!-- The hint is the shorter, denser string and the reason to open the
             card at all, so it keeps its width and the title truncates. -->
        <span class="u-label text-ink truncate">{{ title }}</span>
        <span class="flex shrink-0 items-center gap-2">
          <span v-if="hint" class="font-label text-muted text-xs tracking-[0.08em]">
            {{ hint }}
          </span>
          <svg
            class="text-muted size-4 transition-transform"
            :class="open ? 'rotate-180' : ''"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <path d="M6 9l6 6 6-6" />
          </svg>
        </span>
      </button>
    </h2>
    <div :id="panelId" :class="open && padded ? 'p-4' : ''">
      <slot v-if="open" />
    </div>
  </section>
</template>
