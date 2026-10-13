<script setup lang="ts">
import { computed } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppButton from '@/components/ui/AppButton.vue'
import FreshnessStamp from '@/components/FreshnessStamp.vue'
import AiFeedbackThumbs from '@/components/AiFeedbackThumbs.vue'
import { briefHeadlines, parseBrief, type AiBriefRow } from '@/composables/useAiBrief'

/**
 * The Sales Brief — the analyst's read on whatever data the page is showing.
 * HEADLINES first (Bloomberg-style scannability), analysis below, freshness
 * in the footer. Shared by the Overview today and by future AI Actions on
 * the intel pages; keep it dumb — all data comes in as props.
 *
 * Tappable headlines: a brief written since ai-brief 2.0.0 carries its
 * headlines tagged with the account each is about (ai_briefs.items, keys
 * checked server-side against the brief's own data). Those headlines get a
 * chip that opens the account. Anything older, or a database without the
 * column, renders the prose headlines exactly as before.
 */
const props = defineProps<{
  brief: AiBriefRow | null
  /** True while the Edge Function call is in flight. */
  generating?: boolean
  /** Non-error status line ("Just refreshed…", "Nothing has changed…"). */
  notice?: string
  /** Generation failed; the cached brief (if any) still renders below. */
  error?: string
  /**
   * Hide Regenerate. Generating writes a cached row, so an admin viewing as
   * a rep gets the rep's existing brief and no button — the same gate the
   * account page's Summarize chip sits behind.
   */
  readOnly?: boolean
}>()

defineEmits<{ regenerate: [] }>()

const parsed = computed(() =>
  props.brief ? parseBrief(props.brief.content) : { headlines: [], body: '' },
)
const tagged = computed(() => briefHeadlines(props.brief))
const headlines = computed(
  () =>
    tagged.value ??
    parsed.value.headlines.map((text) => ({ text, customerKey: null, accountName: null })),
)
/** Feedback is about a territory brief; other actions would pass their own. */
const surface = computed(() =>
  props.brief?.action === 'territory.brief' ? ('territory_brief' as const) : null,
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
        v-if="!readOnly"
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
      <ul v-if="headlines.length" class="mb-4 space-y-2">
        <li
          v-for="(h, i) in headlines"
          :key="i"
          class="text-ink flex gap-2.5 text-[17px] leading-snug font-semibold"
        >
          <span class="bg-accent mt-[7px] block h-[3px] w-3 shrink-0" aria-hidden="true" />
          <span class="min-w-0">
            {{ h.text }}
            <!-- The chip is the headline's door into the account: a full
                 48px row of its own under the sentence, not an inline link
                 a thumb has to hit between words. -->
            <RouterLink
              v-if="h.customerKey"
              :to="{ name: 'account', params: { customerKey: h.customerKey } }"
              class="tap-target border-line-2 text-ink-2 hover:border-ink hover:text-ink mt-1.5 flex w-fit max-w-full items-center gap-1.5 border px-3 text-[14px] font-normal"
            >
              <span class="truncate">{{ h.accountName || h.customerKey }}</span>
              <span aria-hidden="true" class="shrink-0">→</span>
            </RouterLink>
          </span>
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

      <AiFeedbackThumbs
        v-if="surface"
        :surface="surface"
        :generated-at="brief.generated_at"
        :prompt-version="brief.prompt_version"
        :read-only="readOnly"
      />
    </template>

    <p v-else class="text-muted text-[15px]">
      No brief yet — it generates automatically each morning<template
        v-if="!readOnly"
      >, or press Generate</template>.
    </p>

    <template v-if="brief" #footer>
      <FreshnessStamp :as-of="brief.generated_at" />
    </template>
  </AppCard>
</template>
