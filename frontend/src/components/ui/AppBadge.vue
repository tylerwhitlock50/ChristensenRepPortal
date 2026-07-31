<script setup lang="ts">
import { computed } from 'vue'

/**
 * Solid fills read further away than dots, so there is no `dot` prop.
 * `late` (ember) is reserved for overdue — never decorative, never more
 * than one per card.
 */
const props = withDefaults(
  defineProps<{
    tone?: 'late' | 'high' | 'good' | 'neutral'
  }>(),
  { tone: 'neutral' },
)

const tones = {
  late: 'bg-accent text-[#20100A] px-2.5 py-[5px]',
  high: 'bg-ink text-canvas px-2.5 py-[5px]',
  good: 'bg-[#E6EBE5] text-brand px-2.5 py-[5px]',
  neutral: 'border border-line text-muted px-2 py-1',
} as const

const classes = computed(() => tones[props.tone])
</script>

<template>
  <span
    class="font-label inline-flex items-center gap-1.5 text-[13px] font-semibold tracking-[0.1em] uppercase"
    :class="classes"
  >
    <slot />
  </span>
</template>
