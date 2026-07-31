<script setup lang="ts">
import { computed } from 'vue'

const props = withDefaults(
  defineProps<{
    tone?: 'neutral' | 'high' | 'warn' | 'good' | 'info'
    dot?: boolean
  }>(),
  { tone: 'neutral', dot: false },
)

const tones = {
  neutral: 'bg-zinc-100 text-zinc-700 ring-zinc-200',
  high: 'bg-red-50 text-red-700 ring-red-200',
  warn: 'bg-amber-50 text-amber-800 ring-amber-200',
  good: 'bg-emerald-50 text-emerald-700 ring-emerald-200',
  info: 'bg-blue-50 text-blue-700 ring-blue-200',
} as const

const dots = {
  neutral: 'bg-zinc-400',
  high: 'bg-red-500',
  warn: 'bg-amber-500',
  good: 'bg-emerald-500',
  info: 'bg-blue-500',
} as const

const classes = computed(() => tones[props.tone])
</script>

<template>
  <span
    class="inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset"
    :class="classes"
  >
    <span
      v-if="dot"
      class="size-1.5 rounded-full"
      :class="dots[tone]"
      aria-hidden="true"
    />
    <slot />
  </span>
</template>
