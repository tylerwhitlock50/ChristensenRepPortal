<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { onClickOutside } from '@vueuse/core'
import { useSessionStore } from '@/stores/session'
import SyncStatusBadge from '@/components/SyncStatusBadge.vue'

const session = useSessionStore()
const router = useRouter()
const route = useRoute()

const menuOpen = ref(false)
const menuRef = ref<HTMLElement | null>(null)
onClickOutside(menuRef, () => (menuOpen.value = false))

const nav = computed(() => {
  const items = [
    { to: { name: 'today' }, label: 'Today', icon: 'today' },
    { to: { name: 'tasks' }, label: 'Tasks', icon: 'tasks' },
    { to: { name: 'accounts' }, label: 'Accounts', icon: 'accounts' },
  ]
  if (session.isAdmin) {
    items.push({ to: { name: 'admin' }, label: 'Execution', icon: 'admin' })
  }
  return items
})

// Execution is the only route that widens past 1024px — ops sits at a desk.
const wide = computed(() => route.name === 'admin')

const initials = computed(() => {
  const parts = (session.displayName || '?').trim().split(/\s+/)
  return parts
    .slice(0, 2)
    .map((p) => p.charAt(0).toUpperCase())
    .join('')
})

async function signOut() {
  menuOpen.value = false
  await session.signOut()
  await router.push({ name: 'login' })
}
</script>

<template>
  <div class="bg-canvas min-h-svh">
    <!-- Ink header, 56px: orange tick + wordmark left, initials right. -->
    <header class="bg-ink text-canvas sticky top-0 z-30">
      <div
        class="mx-auto flex h-14 items-center justify-between gap-3 px-4"
        :class="wide ? 'max-w-7xl' : 'max-w-5xl'"
      >
        <div class="flex items-center gap-6">
          <RouterLink :to="{ name: 'today' }" class="flex items-center gap-2.5">
            <span class="bg-accent block h-4 w-[3px]" aria-hidden="true" />
            <span
              class="font-display text-canvas text-[17px] font-bold tracking-[0.18em] uppercase"
            >
              Rep Portal
            </span>
          </RouterLink>

          <!-- Inline nav from md up; the bottom bar handles small screens -->
          <nav class="hidden items-center gap-5 md:flex" aria-label="Main">
            <RouterLink
              v-for="item in nav"
              :key="item.label"
              :to="item.to"
              class="font-label border-b-2 border-transparent pt-0.5 pb-0.5 text-[13px] font-semibold tracking-[0.14em] text-[#8E8A80] uppercase hover:text-canvas"
              active-class="!text-canvas !border-accent"
            >
              {{ item.label }}
            </RouterLink>
          </nav>
        </div>

        <div class="flex items-center gap-2">
          <!-- The whole sync UI budget (§2.5): renders nothing until a survey
               is actually waiting, and then it is visible on every screen. -->
          <SyncStatusBadge compact />

          <div ref="menuRef" class="relative">
            <!-- The initials chip is aria-hidden and the name span is
                 display:none below sm, so on a phone this button would compute
                 to no accessible name at all — and it is the only route to
                 Sign out. min-w-11 keeps it past 44px wide there too. -->
            <button
              type="button"
              class="tap-target flex min-w-11 items-center justify-center gap-2 px-2"
              :aria-label="`Account menu — ${session.displayName}`"
              :aria-expanded="menuOpen"
              aria-haspopup="menu"
              @click="menuOpen = !menuOpen"
            >
              <span
                class="bg-ink-2 text-canvas font-label grid size-8 place-items-center text-sm font-semibold"
                aria-hidden="true"
              >
                {{ initials }}
              </span>
              <span class="hidden max-w-32 truncate text-sm text-[#C9C5BB] sm:block">
                {{ session.displayName }}
              </span>
            </button>

            <div
              v-if="menuOpen"
              role="menu"
              class="border-line bg-surface text-ink absolute right-0 mt-2 w-56 border shadow-lg"
            >
              <div class="border-line border-b px-3 py-2.5">
                <p class="truncate text-sm font-semibold">
                  {{ session.displayName }}
                </p>
                <p class="text-muted truncate text-xs">
                  {{ session.user?.email }}
                </p>
                <p class="text-muted mt-1 text-xs capitalize">
                  {{ session.role }}
                  <template v-if="session.profile?.sales_rep_key">
                    · {{ session.profile.sales_rep_key }}
                  </template>
                </p>
              </div>
              <button
                type="button"
                role="menuitem"
                class="tap-target font-label w-full px-3 text-left text-[13px] font-semibold tracking-[0.12em] uppercase hover:bg-canvas"
                @click="signOut"
              >
                Sign out
              </button>
            </div>
          </div>
        </div>
      </div>
    </header>

    <!-- pb clears the fixed bottom nav on phones -->
    <main
      class="mx-auto px-4 pt-5 pb-28 md:pb-10"
      :class="wide ? 'max-w-7xl' : 'max-w-5xl'"
    >
      <slot />
    </main>

    <!-- Bottom bar stays on phones — 66px, 2px top rule marks the active tab. -->
    <nav
      class="border-line bg-surface fixed inset-x-0 bottom-0 z-30 border-t pb-[env(safe-area-inset-bottom)] md:hidden"
      aria-label="Main"
    >
      <div class="mx-auto flex max-w-5xl">
        <RouterLink
          v-for="item in nav"
          :key="item.label"
          :to="item.to"
          class="font-label flex min-h-[66px] flex-1 flex-col items-center justify-center gap-1 border-t-2 border-transparent text-xs font-semibold tracking-[0.1em] text-[#8E8A80] uppercase"
          active-class="!text-ink !border-ink -mt-px"
        >
          <svg
            class="size-5"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <template v-if="item.icon === 'today'">
              <path d="M9 11l3 3 5-6" />
              <rect x="3" y="4" width="18" height="17" rx="0" />
              <path d="M8 2v4M16 2v4" />
            </template>
            <!-- Checklist: three rules and a tick, distinct from Today's
                 calendar at a glance and at 20px. -->
            <template v-else-if="item.icon === 'tasks'">
              <path d="M4 6h9M4 12h9M4 18h6" />
              <path d="M16 16l2.2 2.2L22 14" />
            </template>
            <template v-else-if="item.icon === 'accounts'">
              <path d="M3 21h18" />
              <path d="M5 21V7l7-4 7 4v14" />
              <path d="M10 21v-5h4v5" />
            </template>
            <template v-else>
              <path d="M3 3v18h18" />
              <path d="M7 15l4-5 3 3 4-6" />
            </template>
          </svg>
          {{ item.label }}
        </RouterLink>
      </div>
    </nav>
  </div>
</template>
