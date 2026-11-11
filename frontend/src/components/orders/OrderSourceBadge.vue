<script setup lang="ts">
import { computed } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import { sourceBadgeLabel } from '@/lib/mcpOrders'

/**
 * "Drafted by Claude" next to any order that was not written by hand in the
 * portal (orders.source <> 'portal'), and "TEST" next to a Claude test
 * draft (orders.is_test). Renders nothing for an ordinary portal order.
 */
const props = defineProps<{ source: string | null | undefined; isTest?: boolean | null }>()
const label = computed(() => sourceBadgeLabel(props.source))
</script>

<template>
  <AppBadge v-if="isTest" tone="late">TEST</AppBadge>
  <AppBadge v-if="label" tone="neutral">{{ label }}</AppBadge>
</template>
