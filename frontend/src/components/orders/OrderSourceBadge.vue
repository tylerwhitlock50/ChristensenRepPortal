<script setup lang="ts">
import { computed } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import { sourceBadgeLabel } from '@/lib/mcpOrders'

/**
 * "Drafted by Claude" next to any order that was not written by hand in the
 * portal (orders.source <> 'portal'). Renders nothing for a portal order.
 */
const props = defineProps<{ source: string | null | undefined }>()
const label = computed(() => sourceBadgeLabel(props.source))
</script>

<template>
  <AppBadge v-if="label" tone="neutral">{{ label }}</AppBadge>
</template>
