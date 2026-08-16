<script setup lang="ts">
import { computed } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import { ORDER_STATUS_LABELS, type OrderStatus } from '@/types/domain'

/**
 * One badge per order, everywhere an order is listed. Ember (`late`) is
 * reserved for discrepancy — the one state that means "someone must act".
 */
const props = defineProps<{ status: OrderStatus }>()

const tone = computed(() => {
  switch (props.status) {
    case 'discrepancy':
      return 'late' as const
    case 'verified':
      return 'good' as const
    case 'submitted':
    case 'entered':
      return 'high' as const
    default:
      return 'neutral' as const
  }
})
</script>

<template>
  <AppBadge :tone="tone">{{ ORDER_STATUS_LABELS[status] }}</AppBadge>
</template>
