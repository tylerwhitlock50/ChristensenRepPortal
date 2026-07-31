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
    variant: 'primary',
    size: 'md',
    block: false,
    loading: false,
    disabled: false,
    type: 'button',
  },
)

const variants = {
  primary: 'bg-zinc-900 text-white hover:bg-zinc-800 active:bg-zinc-950',
  secondary:
    'bg-white text-zinc-900 border border-zinc-300 hover:bg-zinc-50 active:bg-zinc-100',
  ghost: 'bg-transparent text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200',
  danger: 'bg-red-600 text-white hover:bg-red-700 active:bg-red-800',
} as const

// min-h-11 = 44px, the field-UI floor from TECH_STACK §2.4.
const sizes = {
  md: 'min-h-11 px-4 text-sm',
  lg: 'min-h-13 px-5 text-base',
} as const

const classes = computed(() => [
  'tap-target inline-flex items-center justify-center gap-2 rounded-lg font-medium',
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
    <svg
      v-if="loading"
      class="size-4 animate-spin"
      viewBox="0 0 24 24"
      fill="none"
      aria-hidden="true"
    >
      <circle
        class="opacity-25"
        cx="12"
        cy="12"
        r="10"
        stroke="currentColor"
        stroke-width="4"
      />
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8v4a4 4 0 00-4 4H4z"
      />
    </svg>
    <slot />
  </button>
</template>
