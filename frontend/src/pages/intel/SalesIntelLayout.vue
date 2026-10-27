<script setup lang="ts">
import { useRoute } from 'vue-router'
import FreshnessStamp from '@/components/FreshnessStamp.vue'

/**
 * The Sales Intel shell — one nav entry fans out into the report tabs, the
 * same shape as AdminLayout. "Intel", not "Reports": reports are accounting;
 * this section exists to make a rep smarter before a customer conversation.
 * Every child page follows the same flow: metrics up top, then the detail
 * grid — with a slot in the middle where per-report Sales Briefs (AI
 * Actions) land as they ship.
 *
 * Open orders and Shipments are the two book lists outside reps used to pull
 * from Tableau (G03, G04): every open line and every packlist in the book,
 * filterable and exportable, so Tableau can go away for them.
 */
const tabs = [
  { to: { name: 'intel-sku' }, label: 'SKU Sales' },
  { to: { name: 'intel-backlog' }, label: 'Backlog' },
  { to: { name: 'intel-open-orders' }, label: 'Open orders' },
  { to: { name: 'intel-shipments' }, label: 'Shipments' },
  // "ATS" is the ERP's word; reps read "In stock". The route keeps 'ats'.
  { to: { name: 'intel-ats' }, label: 'In stock' },
  { to: { name: 'intel-global' }, label: 'Global' },
  { to: { name: 'intel-price-lists' }, label: 'Price Lists' },
] as const

/* The question every rep coming off Tableau asks first (G10). Opens the help
   article in place, the same way the header's "?" reaches Help: ?article=
   expands it, ?from= keeps the way back. */
const route = useRoute()
</script>

<template>
  <div class="space-y-5">
    <header class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
      <h1 class="u-display text-ink text-3xl">Sales Intel</h1>
      <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
        <FreshnessStamp />
        <RouterLink
          :to="{
            name: 'help',
            query: { article: 'portal-vs-tableau-numbers', from: route.fullPath },
          }"
          class="text-ink-2 text-xs underline decoration-dotted underline-offset-2"
        >
          Why don't these match Tableau?
        </RouterLink>
      </div>
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
