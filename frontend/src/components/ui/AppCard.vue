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
  <section class="rounded-xl border border-zinc-200 bg-white">
    <header
      v-if="title || $slots.header"
      class="flex items-center justify-between gap-3 border-b border-zinc-100 px-4 py-3"
    >
      <slot name="header">
        <h2 class="text-sm font-semibold tracking-tight text-zinc-900">
          {{ title }}
        </h2>
        <span v-if="hint" class="text-xs text-zinc-500">{{ hint }}</span>
      </slot>
    </header>
    <div :class="padded ? 'p-4' : ''">
      <slot />
    </div>
    <footer v-if="$slots.footer" class="border-t border-zinc-100 px-4 py-3">
      <slot name="footer" />
    </footer>
  </section>
</template>
