<script setup lang="ts">
import { computed } from 'vue'
import { useDataFreshness } from '@/composables/useDataFreshness'
import { daysAgo, shortDate } from '@/lib/format'

/**
 * "Data through Aug 3 · Loaded today". Design principle: freshness is
 * visible on every intel surface. Renders nothing until the freshness row
 * arrives — a stamp that says "—" is worse than no stamp.
 *
 * An optional `asOf` (e.g. an AI brief's generated_at) prepends
 * "As of yesterday · " for surfaces whose content has its own age.
 */
const props = defineProps<{ asOf?: string | null }>()

const { loadedAt, dataThrough } = useDataFreshness()

const text = computed(() => {
  const parts: string[] = []
  if (props.asOf) parts.push(`As of ${daysAgo(props.asOf)}`)
  if (dataThrough.value) parts.push(`Data through ${shortDate(dataThrough.value)}`)
  if (loadedAt.value) parts.push(`Loaded ${daysAgo(loadedAt.value)}`)
  return parts.join(' · ')
})
</script>

<template>
  <p v-if="text" class="text-muted text-xs">{{ text }}</p>
</template>
