<script setup lang="ts">
import { computed } from 'vue'
import AppButton from './AppButton.vue'
import { isSchemaNotExposed } from '@/lib/supabase'

const props = withDefaults(
  defineProps<{
    loading?: boolean
    error?: unknown
    /** True when the query succeeded but returned nothing. */
    empty?: boolean
    emptyTitle?: string
    emptyBody?: string
    /** Skeleton rows to show while loading. */
    rows?: number
  }>(),
  { emptyTitle: 'Nothing here', rows: 3 },
)

defineEmits<{ retry: [] }>()

const message = computed(() => {
  const e = props.error as { message?: string } | null
  if (!e) return ''
  if (isSchemaNotExposed(e)) {
    return 'The ERP read models are not published to the API yet. An admin needs to add the `erp` schema under Settings → API → Exposed schemas in Supabase.'
  }
  return e.message || 'Something went wrong.'
})
</script>

<template>
  <div v-if="loading" class="space-y-2" aria-busy="true" aria-live="polite">
    <span class="sr-only">Loading</span>
    <div
      v-for="i in rows"
      :key="i"
      class="h-16 animate-pulse rounded-lg bg-zinc-100"
    />
  </div>

  <div
    v-else-if="error"
    role="alert"
    class="rounded-lg border border-red-200 bg-red-50 p-4"
  >
    <p class="text-sm font-medium text-red-900">Couldn't load this</p>
    <p class="mt-1 text-sm text-red-800">{{ message }}</p>
    <AppButton
      variant="secondary"
      size="md"
      class="mt-3"
      @click="$emit('retry')"
    >
      Try again
    </AppButton>
  </div>

  <div v-else-if="empty" class="px-4 py-10 text-center">
    <p class="text-sm font-medium text-zinc-900">{{ emptyTitle }}</p>
    <p v-if="emptyBody" class="mx-auto mt-1 max-w-xs text-sm text-zinc-500">
      {{ emptyBody }}
    </p>
    <div class="mt-4">
      <slot name="empty-action" />
    </div>
  </div>

  <slot v-else />
</template>
