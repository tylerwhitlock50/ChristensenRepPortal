<script setup lang="ts">
import { computed } from 'vue'

const props = withDefaults(
  defineProps<{
    variant?: 'primary' | 'secondary' | 'ghost' | 'danger'
    size?: 'md' | 'lg'
    block?: boolean
    loading?: boolean
    disabled?: boolean
    type?: 'button' | 'submit'
  }>(),
  {
    // Secondary by default — primary (the one green) is rationed to one per view.
    variant: 'secondary',
    size: 'md',
    block: false,
    loading: false,
    disabled: false,
    type: 'button',
  },
)

const variants = {
  primary: 'bg-brand text-canvas hover:bg-brand-hi active:bg-brand',
  secondary:
    'bg-transparent text-ink border-[1.5px] border-ink hover:bg-ink hover:text-canvas',
  ghost: 'bg-transparent text-muted border border-line hover:text-ink hover:border-ink',
  danger: 'bg-danger text-canvas hover:opacity-90',
} as const

// 48px is the field-UI floor; lg is the 52px full-width form action.
const sizes = {
  md: 'min-h-12 px-4 text-[15px]',
  lg: 'min-h-13 px-5 text-base',
} as const

const classes = computed(() => [
  'tap-target inline-flex items-center justify-center gap-2 rounded-[2px]',
  'font-label font-semibold uppercase tracking-[0.12em]',
  'transition-colors disabled:opacity-50 disabled:pointer-events-none',
  variants[props.variant],
  sizes[props.size],
  props.block ? 'w-full' : '',
])
</script>

<template>
  <button
    :type="type"
    :class="classes"
    :disabled="disabled || loading"
    :aria-busy="loading || undefined"
  >
    <!-- Loading swaps the label for a 2px bar, never a spinner — the button
         must stay 48px tall so the layout doesn't jump. -->
    <span v-if="loading" class="relative block h-0.5 w-10 overflow-hidden bg-current/25">
      <span class="btn-load-bar absolute inset-y-0 w-1/2 bg-current" />
      <span class="sr-only">Working</span>
    </span>
    <slot v-else />
  </button>
</template>

<style scoped>
.btn-load-bar {
  animation: btn-load 1s linear infinite;
}
@keyframes btn-load {
  from {
    left: -50%;
  }
  to {
    left: 100%;
  }
}
</style>
