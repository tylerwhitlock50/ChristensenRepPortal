<script setup lang="ts">
/**
 * Sits in a 1px-gap grid on a line-colored background — the parent provides
 * the shared hairline (`grid gap-px bg-line border border-line`), so the tile
 * itself is just white fill. No rounded boxes floating on canvas.
 */
defineProps<{
  label: string
  value: string | number
  sub?: string
  tone?: 'default' | 'alert'
}>()
</script>

<template>
  <div class="bg-surface px-3 py-2.5">
    <p class="font-label text-muted text-[11px] font-semibold tracking-[0.14em] uppercase">
      {{ label }}
    </p>
    <p
      class="u-display mt-1 text-3xl tabular-nums"
      :class="tone === 'alert' ? 'text-accent' : 'text-ink'"
    >
      {{ value }}
    </p>
    <p v-if="sub" class="text-muted mt-0.5 text-xs">{{ sub }}</p>
  </div>
</template>
