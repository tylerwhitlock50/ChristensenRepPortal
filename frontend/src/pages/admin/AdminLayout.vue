<script setup lang="ts">
import { computed } from 'vue'
import { useFeatureFlags } from '@/composables/useAppSettings'

/**
 * The admin section shell: one nav entry ("Admin") fans out here into tabs.
 * A tab bar instead of more top-nav items because the phone bottom bar is
 * already full at four entries. Missions rides the recommendations flag —
 * composing missions nobody can see would just be confusing.
 */
const flags = useFeatureFlags()

const tabs = computed(() => {
  const items: { to: { name: string }; label: string }[] = [
    { to: { name: 'admin-execution' }, label: 'Execution' },
    { to: { name: 'admin-users' }, label: 'Users' },
  ]
  if (flags.recommendations.value) {
    items.push({ to: { name: 'admin-missions' }, label: 'Missions' })
  }
  items.push(
    { to: { name: 'admin-activity' }, label: 'Activity' },
    { to: { name: 'admin-settings' }, label: 'Settings' },
  )
  return items
})
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
