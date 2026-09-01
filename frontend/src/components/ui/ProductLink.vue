<script setup lang="ts">
import { computed } from 'vue'
import { productFamilyUrl } from '@/lib/productLinks'

/**
 * A SKU (or any text) that links out to the family's page on
 * christensenarms.com — the closest thing to a product photo the portal
 * has. Renders the slot as plain text when the family can't be resolved to
 * a URL, so a dead family never produces a dead link.
 *
 * One component instead of six hand-rolled anchors across the intel pages:
 * the URL resolves once, the new-tab/rel/tooltip treatment can't drift
 * between tables, and their phone cards.
 */
const props = withDefaults(
  defineProps<{
    family: string | null | undefined
    /**
     * What to render when there is no URL: 'text' keeps the slot as plain
     * text (a SKU must still show), 'none' drops it entirely (a "see it"
     * affordance with nowhere to go should not exist).
     */
    fallback?: 'text' | 'none'
  }>(),
  { fallback: 'text' },
)

const url = computed(() => productFamilyUrl(props.family))
</script>

<template>
  <a
    v-if="url"
    :href="url"
    target="_blank"
    rel="noopener noreferrer"
    class="text-ink underline decoration-dotted underline-offset-2"
    :title="`${family} on christensenarms.com`"
  >
    <slot />
  </a>
  <slot v-else-if="fallback === 'text'" />
</template>
