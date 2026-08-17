<script setup lang="ts">
import { computed } from 'vue'
import { useSessionStore } from '@/stores/session'

/**
 * The Orders shell — same tab-bar shape as AdminLayout/SalesIntelLayout.
 * The Entry Queue tab appears only for order_entry and admins; the rep's
 * pair is My Orders + New Order.
 */
const session = useSessionStore()

const tabs = computed(() => {
  const items: { to: { name: string }; label: string }[] = []
  items.push({ to: { name: 'orders' }, label: 'My Orders' })
  if (!session.isOrderEntry) {
    items.push({ to: { name: 'orders-new' }, label: 'New Order' })
  }
  if (session.isOrderEntry || session.isAdmin) {
    items.push({ to: { name: 'orders-queue' }, label: 'Entry Queue' })
  }
  return items
})
</script>

<template>
  <div class="space-y-5">
    <header class="flex flex-wrap items-baseline justify-between gap-2">
      <h1 class="u-display text-ink text-3xl">Orders</h1>
    </header>

    <nav
      class="border-line -mx-4 flex overflow-x-auto border-b px-4"
      aria-label="Order sections"
    >
      <!-- The index tab ('/orders') matches every child by prefix, so it
           lights only on exact match; the real tabs use normal matching. -->
      <RouterLink
        v-for="tab in tabs"
        :key="tab.label"
        :to="tab.to"
        class="tap-target font-label text-muted hover:text-ink flex shrink-0 items-center border-b-2 border-transparent px-4 text-[13px] font-semibold tracking-[0.14em] uppercase"
        :active-class="tab.to.name === 'orders' ? '' : '!text-ink !border-accent'"
        exact-active-class="!text-ink !border-accent"
      >
        {{ tab.label }}
      </RouterLink>
    </nav>

    <RouterView />
  </div>
</template>
