<script setup lang="ts">
/**
 * The admin section shell: one nav entry ("Admin") fans out here into four
 * tabs. A tab bar instead of more top-nav items because the phone bottom bar
 * is already full at four entries.
 */
const tabs = [
  { to: { name: 'admin-execution' }, label: 'Execution' },
  { to: { name: 'admin-users' }, label: 'Users' },
  { to: { name: 'admin-missions' }, label: 'Missions' },
  { to: { name: 'admin-activity' }, label: 'Activity' },
] as const
</script>

<template>
  <div class="space-y-5">
    <nav
      class="border-line -mx-4 flex overflow-x-auto border-b px-4"
      aria-label="Admin sections"
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
