<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { onClickOutside } from '@vueuse/core'
import { useSessionStore } from '@/stores/session'

const session = useSessionStore()
const router = useRouter()

const menuOpen = ref(false)
const menuRef = ref<HTMLElement | null>(null)
onClickOutside(menuRef, () => (menuOpen.value = false))

const nav = computed(() => {
  const items = [
    { to: { name: 'today' }, label: 'Today', icon: 'today' },
    { to: { name: 'accounts' }, label: 'Accounts', icon: 'accounts' },
  ]
  if (session.isAdmin) {
    items.push({ to: { name: 'admin' }, label: 'Execution', icon: 'admin' })
  }
  return items
})

async function signOut() {
  menuOpen.value = false
  await session.signOut()
  await router.push({ name: 'login' })
}
</script>

<template>
  <div class="min-h-svh bg-zinc-50">
    <header
      class="sticky top-0 z-30 border-b border-zinc-200 bg-white/95 backdrop-blur"
    >
      <div
        class="mx-auto flex h-14 max-w-5xl items-center justify-between gap-3 px-4"
      >
        <RouterLink
          :to="{ name: 'today' }"
          class="flex items-center gap-2 font-semibold tracking-tight text-zinc-900"
        >
          <span class="size-2.5 rounded-sm bg-amber-500" aria-hidden="true" />
          Rep Portal
        </RouterLink>

        <!-- Inline nav from md up; the bottom bar handles small screens -->
        <nav class="hidden items-center gap-1 md:flex" aria-label="Main">
          <RouterLink
            v-for="item in nav"
            :key="item.label"
            :to="item.to"
            class="tap-target inline-flex items-center rounded-lg px-3 text-sm font-medium text-zinc-600 hover:bg-zinc-100"
            active-class="bg-zinc-100 text-zinc-900"
          >
            {{ item.label }}
          </RouterLink>
        </nav>

        <div ref="menuRef" class="relative">
          <button
            type="button"
            class="tap-target flex items-center gap-2 rounded-lg px-2 text-sm text-zinc-700 hover:bg-zinc-100"
            :aria-expanded="menuOpen"
            aria-haspopup="menu"
            @click="menuOpen = !menuOpen"
          >
            <span
              class="grid size-8 place-items-center rounded-full bg-zinc-900 text-xs font-semibold text-white"
              aria-hidden="true"
            >
              {{ (session.displayName || '?').charAt(0).toUpperCase() }}
            </span>
            <span class="hidden max-w-32 truncate sm:block">
              {{ session.displayName }}
            </span>
          </button>

          <div
            v-if="menuOpen"
            role="menu"
            class="absolute right-0 mt-1 w-56 rounded-xl border border-zinc-200 bg-white p-1 shadow-lg"
          >
            <div class="px-3 py-2">
              <p class="truncate text-sm font-medium text-zinc-900">
                {{ session.displayName }}
              </p>
              <p class="truncate text-xs text-zinc-500">
                {{ session.user?.email }}
              </p>
              <p class="mt-1 text-xs text-zinc-500 capitalize">
                {{ session.role }}
                <template v-if="session.profile?.sales_rep_key">
                  · {{ session.profile.sales_rep_key }}
                </template>
              </p>
            </div>
            <hr class="my-1 border-zinc-100" />
            <button
              type="button"
              role="menuitem"
              class="tap-target w-full rounded-lg px-3 text-left text-sm text-zinc-700 hover:bg-zinc-100"
              @click="signOut"
            >
              Sign out
            </button>
          </div>
        </div>
      </div>
    </header>

    <!-- pb clears the fixed bottom nav on phones -->
    <main class="mx-auto max-w-5xl px-4 pt-4 pb-28 md:pb-10">
      <slot />
    </main>

    <nav
      class="fixed inset-x-0 bottom-0 z-30 border-t border-zinc-200 bg-white/95 pb-[env(safe-area-inset-bottom)] backdrop-blur md:hidden"
      aria-label="Main"
    >
      <div class="mx-auto flex max-w-5xl">
        <RouterLink
          v-for="item in nav"
          :key="item.label"
          :to="item.to"
          class="tap-target flex flex-1 flex-col items-center justify-center gap-1 py-2 text-xs font-medium text-zinc-500"
          active-class="text-zinc-900"
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
              <rect x="3" y="4" width="18" height="17" rx="2" />
              <path d="M8 2v4M16 2v4" />
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
