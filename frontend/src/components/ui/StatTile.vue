<script setup lang="ts">
defineProps<{
  label: string
  value: string | number
  sub?: string
  tone?: 'default' | 'alert'
}>()
</script>

<template>
  <div class="rounded-xl border border-zinc-200 bg-white p-4">
    <p class="text-xs font-medium tracking-wide text-zinc-500 uppercase">
      {{ label }}
    </p>
    <p
      class="mt-1 text-2xl font-semibold tabular-nums"
      :class="tone === 'alert' ? 'text-red-600' : 'text-zinc-900'"
    >
      {{ value }}
    </p>
    <p v-if="sub" class="mt-0.5 text-xs text-zinc-500">{{ sub }}</p>
  </div>
</template>
