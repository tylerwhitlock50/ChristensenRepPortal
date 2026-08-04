<script setup lang="ts">
/**
 * The count chip on a nav item.
 *
 * Extracted because this markup already existed twice in AppShell — once in the
 * md+ header, once in the phone bottom bar — and the two had already drifted
 * apart (`bg-canvas text-ink` against `bg-ink text-canvas`). Both sat on the
 * dark header and the light bottom bar respectively, so both were right; there
 * was just nothing keeping them deliberately different. Now there is.
 *
 * `late` is the only thing that turns it ember. That is the style.css contract:
 * accent means late, never decorative, never "high priority".
 */
withDefaults(
  defineProps<{
    count: number
    late?: boolean
    /** Accessible name — the digits alone don't say what they count. */
    label: string
    /** Where it sits, which decides the resting (not-late) colours. */
    variant?: 'header' | 'bar'
  }>(),
  { late: false, variant: 'header' },
)
</script>

<template>
  <span
    v-if="count > 0"
    class="inline-grid min-w-5 place-items-center px-1 py-0.5 text-[11px] leading-none font-bold"
    :class="[
      late
        ? 'bg-accent text-[#20100A]'
        : variant === 'header'
          ? 'bg-canvas text-ink'
          : 'bg-ink text-canvas',
    ]"
    :aria-label="label"
  >
    {{ count }}
  </span>
</template>
