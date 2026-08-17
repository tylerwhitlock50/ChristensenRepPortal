<script setup lang="ts">
import { computed } from 'vue'
import { useDataFreshness } from '@/composables/useDataFreshness'
import { daysAgo, shortDate } from '@/lib/format'

/**
 * "Invoiced through Aug 13 · Orders through Aug 17 · Loaded today".
 * Design principle: freshness is visible on every intel surface. Renders
 * nothing until the freshness row arrives — a stamp that says "—" is worse
 * than no stamp.
 *
 * Two dates on purpose: revenue figures stop at the newest invoice, but the
 * ERP can lag billing behind shipping by days. "Data through Aug 13" on an
 * Aug 17 load read as a stale warehouse when the load was current. The
 * orders date is elided when it doesn't add anything (same day as invoiced).
 *
 * An optional `asOf` (e.g. an AI brief's generated_at) prepends
 * "As of yesterday · " for surfaces whose content has its own age.
 */
const props = defineProps<{ asOf?: string | null }>()

const { loadedAt, dataThrough, ordersThrough } = useDataFreshness()

const text = computed(() => {
  const parts: string[] = []
  if (props.asOf) parts.push(`As of ${daysAgo(props.asOf)}`)
  if (dataThrough.value) parts.push(`Invoiced through ${shortDate(dataThrough.value)}`)
  if (ordersThrough.value && ordersThrough.value !== dataThrough.value)
    parts.push(`Orders through ${shortDate(ordersThrough.value)}`)
  if (loadedAt.value) parts.push(`Loaded ${daysAgo(loadedAt.value)}`)
  return parts.join(' · ')
})
</script>

<template>
  <p v-if="text" class="text-muted text-xs">{{ text }}</p>
</template>
