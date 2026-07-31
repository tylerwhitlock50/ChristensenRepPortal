<script setup lang="ts">
withDefaults(
  defineProps<{
    title?: string
    /** Right-aligned hint in the header — a count, a date, a status. */
    hint?: string
    padded?: boolean
  }>(),
  { padded: true },
)
</script>

<template>
  <!-- No shadow, no radius: 1px line, white fill, uppercase label title. -->
  <section class="border-line bg-surface border">
    <header
      v-if="title || $slots.header"
      class="border-line flex items-center justify-between gap-3 border-b px-4 py-3"
    >
      <slot name="header">
        <h2 class="u-label text-ink">
          {{ title }}
        </h2>
        <span v-if="hint" class="font-label text-muted text-xs tracking-[0.08em]">
          {{ hint }}
        </span>
      </slot>
    </header>
    <div :class="padded ? 'p-4' : ''">
      <slot />
    </div>
    <footer v-if="$slots.footer" class="border-line border-t px-4 py-3">
      <slot name="footer" />
    </footer>
  </section>
</template>
