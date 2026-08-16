<script setup lang="ts">
import FreshnessStamp from '@/components/FreshnessStamp.vue'

/**
 * The Sales Intel shell — one nav entry fans out into four report tabs, the
 * same shape as AdminLayout. "Intel", not "Reports": reports are accounting;
 * this section exists to make a rep smarter before a customer conversation.
 * Every child page follows the same flow: metrics up top, then the detail
 * grid — with a slot in the middle where per-report Sales Briefs (AI
 * Actions) land as they ship.
 */
const tabs = [
  { to: { name: 'intel-sku' }, label: 'SKU Sales' },
  { to: { name: 'intel-backlog' }, label: 'Backlog' },
  { to: { name: 'intel-ats' }, label: 'ATS' },
  { to: { name: 'intel-global' }, label: 'Global' },
  { to: { name: 'intel-price-lists' }, label: 'Price Lists' },
] as const
</script>

<template>
  <div class="space-y-5">
    <header class="flex flex-wrap items-baseline justify-between gap-2">
      <h1 class="u-display text-ink text-3xl">Sales Intel</h1>
      <FreshnessStamp />
    </header>

    <nav
      class="border-line -mx-4 flex overflow-x-auto border-b px-4"
      aria-label="Sales intel sections"
    >
      <RouterLink
        v-for="tab in tabs"
        :key="tab.label"
        :to="tab.to"
        class="tap-target font-label text-muted hover:text-ink flex shrink-0 items-center border-b-2 border-transparent px-4 text-[13px] font-semibold tracking-[0.14em] uppercase"
        active-class="!text-ink !border-accent"
      >
        {{ tab.label }}
      </RouterLink>
    </nav>

    <RouterView />
  </div>
</template>
