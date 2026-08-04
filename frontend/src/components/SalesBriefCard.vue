<script setup lang="ts">
import { computed } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppButton from '@/components/ui/AppButton.vue'
import FreshnessStamp from '@/components/FreshnessStamp.vue'
import { parseBrief, type AiBriefRow } from '@/composables/useAiBrief'

/**
 * The Sales Brief — the analyst's read on whatever data the page is showing.
 * HEADLINES first (Bloomberg-style scannability), analysis below, freshness
 * in the footer. Shared by the Overview today and by future AI Actions on
 * the intel pages; keep it dumb — all data comes in as props.
 */
const props = defineProps<{
  brief: AiBriefRow | null
  /** True while the Edge Function call is in flight. */
  generating?: boolean
  /** Non-error status line ("Just refreshed…", "Nothing has changed…"). */
  notice?: string
  /** Generation failed; the cached brief (if any) still renders below. */
  error?: string
}>()

defineEmits<{ regenerate: [] }>()

const parsed = computed(() =>
  props.brief ? parseBrief(props.brief.content) : { headlines: [], body: '' },
)
const paragraphs = computed(() =>
  parsed.value.body.split(/\n{2,}/).map((p) => p.trim()).filter(Boolean),
)
</script>

<template>
  <AppCard title="Sales Brief">
    <template #header>
      <h2 class="u-label text-ink">Sales Brief</h2>
      <AppButton
        variant="ghost"
        :loading="generating"
        @click="$emit('regenerate')"
      >
        {{ brief ? 'Regenerate' : 'Generate' }}
      </AppButton>
    </template>

    <p v-if="error" role="alert" class="text-accent mb-3 text-sm">
      {{ error }}
    </p>
    <p v-else-if="notice" class="text-muted mb-3 text-sm" aria-live="polite">
      {{ notice }}
    </p>

    <!-- First generation: flat placeholder, no shimmer (design system). -->
    <div v-if="!brief && generating" class="space-y-2" aria-busy="true">
      <span class="sr-only">Writing the brief</span>
      <div v-for="i in 4" :key="i" class="h-5 bg-[#E6E3DC]" />
    </div>

    <template v-else-if="brief">
      <ul v-if="parsed.headlines.length" class="mb-4 space-y-2">
        <li
          v-for="(h, i) in parsed.headlines"
          :key="i"
          class="text-ink flex gap-2.5 text-[17px] leading-snug font-semibold"
        >
          <span class="bg-accent mt-[7px] block h-[3px] w-3 shrink-0" aria-hidden="true" />
          {{ h }}
        </li>
      </ul>
      <div class="space-y-3">
        <p
          v-for="(p, i) in paragraphs"
          :key="i"
          class="text-ink-2 text-[15px] leading-relaxed whitespace-pre-line"
        >
          {{ p }}
        </p>
      </div>
    </template>

    <p v-else class="text-muted text-[15px]">
      No brief yet — it generates automatically each morning, or press
      Generate.
    </p>

    <template v-if="brief" #footer>
      <FreshnessStamp :as-of="brief.generated_at" />
    </template>
  </AppCard>
</template>
