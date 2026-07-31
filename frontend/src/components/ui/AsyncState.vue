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
  <!-- Skeletons are flat blocks at the real row height — no shimmer. -->
  <div v-if="loading" class="space-y-2" aria-busy="true" aria-live="polite">
    <span class="sr-only">Loading</span>
    <div v-for="i in rows" :key="i" class="h-16 bg-[#E6E3DC]" />
  </div>

  <!-- Error gets the ember rail and a Retry button. -->
  <div
    v-else-if="error"
    role="alert"
    class="border-line bg-surface border-l-accent border border-l-[3px] p-4"
  >
    <p class="text-ink text-[17px] font-semibold">Couldn't load this</p>
    <p class="text-ink-2 mt-1 text-[15px] leading-relaxed">{{ message }}</p>
    <AppButton variant="secondary" size="md" class="mt-3" @click="$emit('retry')">
      Try again
    </AppButton>
  </div>

  <!-- Empty states: a headline in display caps and one sentence. -->
  <div v-else-if="empty" class="px-4 py-10 text-center">
    <p class="u-display text-ink text-2xl">{{ emptyTitle }}</p>
    <p v-if="emptyBody" class="text-muted mx-auto mt-2 max-w-xs text-[15px] leading-relaxed">
      {{ emptyBody }}
    </p>
    <div class="mt-5">
      <slot name="empty-action" />
    </div>
  </div>

  <slot v-else />
</template>
