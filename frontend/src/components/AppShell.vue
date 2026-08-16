<script setup lang="ts">
import { computed, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { onClickOutside } from '@vueuse/core'
import { useSessionStore } from '@/stores/session'
import { isMission, useNeedsAttention } from '@/composables/useRecommendations'
import { useFeatureFlags } from '@/composables/useAppSettings'
import { useMyDueTasks } from '@/composables/useTasks'
import SyncStatusBadge from '@/components/SyncStatusBadge.vue'
import NavBadge from '@/components/NavBadge.vue'
import ViewAsBanner from '@/components/ViewAsBanner.vue'
import { daysUntilDue } from '@/lib/format'

const session = useSessionStore()
const router = useRouter()
const route = useRoute()
const flags = useFeatureFlags()

/* Open-mission count on the Today tab. Shares the Today page's query key, so
   when Today has loaded this costs nothing extra. Gated off for admins: their
   unscoped needs-attention select is the whole company's list, and the shell
   must not fire that on every page. Also gated on the recommendations flag —
   while the feature is hidden there is no Today tab to badge, so the shell
   must not poll for it. */
const needsAttention = useNeedsAttention({
  enabled: computed(
    () => session.isSignedIn && !session.isAdmin && flags.recommendations.value,
  ),
})
const missionCount = computed(
  () => (needsAttention.data.value ?? []).filter((r) => isMission(r)).length,
)
const missionsLate = computed(() =>
  (needsAttention.data.value ?? []).some((r) => {
    if (!isMission(r)) return false
    const d = daysUntilDue(r.due_date)
    return d != null && d < 0
  }),
)

/* Due follow-ups on the Tasks tab. Deliberately NOT gated off for admins the
   way the mission query above is: `tasks` is user-scoped and the composable
   always sends `.eq('user_id', …)`, so an admin sees their own list, not the
   company's. Gating it would hide an admin's own overdue follow-ups. */
const dueTasks = useMyDueTasks()
const tasksDue = computed(() => dueTasks.data.value?.due ?? 0)
const tasksOverdue = computed(() => dueTasks.data.value?.overdue ?? 0)

const menuOpen = ref(false)
const menuRef = ref<HTMLElement | null>(null)
onClickOutside(menuRef, () => (menuOpen.value = false))

type Badge = { count: number; late: boolean; label: string }
type NavItem = {
  to: string | { name: string }
  label: string
  icon: string
  badge?: Badge
}

/* Data-first nav: Overview, Sales Intel, Accounts always; the capture
   features (Today, Tasks) appear only while their flags are on — with their
   badges, which hang off the item rather than being matched by icon name at
   the two render sites. Flags load as false, so the bar renders the lean
   set first and never flashes a hidden feature. */
const nav = computed<NavItem[]>(() => {
  const items: NavItem[] = [
    { to: { name: 'overview' }, label: 'Overview', icon: 'overview' },
    // Path, not name, for section parents: keeps the item active on every
    // child tab.
    { to: '/intel', label: 'Intel', icon: 'intel' },
    { to: { name: 'accounts' }, label: 'Accounts', icon: 'accounts' },
    // "Where's my order?" is the most common call a rep takes; it earns a
    // permanent tab rather than living inside one account's page.
    { to: { name: 'lookup' }, label: 'Find', icon: 'lookup' },
  ]
  if (flags.recommendations.value) {
    items.splice(0, 0, {
      to: { name: 'today' },
      label: 'Today',
      icon: 'today',
      badge: {
        count: missionCount.value,
        late: missionsLate.value,
        label: `${missionCount.value} open missions`,
      },
    })
  }
  if (flags.tasks.value) {
    items.push({
      to: { name: 'tasks' },
      label: 'Tasks',
      icon: 'tasks',
      badge: {
        count: tasksDue.value,
        late: tasksOverdue.value > 0,
        label:
          tasksOverdue.value > 0
            ? `${tasksDue.value} follow-ups due, ${tasksOverdue.value} overdue`
            : `${tasksDue.value} follow-ups due`,
      },
    })
  }
  if (session.isAdmin) {
    items.push({ to: '/admin', label: 'Admin', icon: 'admin' })
  }
  return items
})

// Admin and Sales Intel widen past 1024px — grids of SKUs earn the room.
const wide = computed(
  () => route.path.startsWith('/admin') || route.path.startsWith('/intel'),
)

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
          <!-- tap-target, not just the text box: as a bare flex row the wordmark
               was a 26px-tall tap target. h-full doesn't help here — the parent
               is itself a content-height flex item, so 100% of it is still 26px. -->
          <RouterLink
            :to="{ name: 'overview' }"
            class="tap-target flex items-center gap-2.5"
          >
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
              <NavBadge
                v-if="item.badge"
                class="ml-1"
                variant="header"
                :count="item.badge.count"
                :late="item.badge.late"
                :label="item.badge.label"
              />
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
              <RouterLink
                :to="{ name: 'connect' }"
                role="menuitem"
                class="tap-target font-label hover:bg-canvas flex w-full items-center px-3 text-left text-[13px] font-semibold tracking-[0.12em] uppercase"
                @click="menuOpen = false"
              >
                Connect Claude
              </RouterLink>
              <button
                type="button"
                role="menuitem"
                class="tap-target font-label border-line w-full border-t px-3 text-left text-[13px] font-semibold tracking-[0.12em] uppercase hover:bg-canvas"
                @click="signOut"
              >
                Sign out
              </button>
            </div>
          </div>
        </div>
      </div>
    </header>

    <!-- Below the sticky header rather than inside it: the header is a fixed
         56px and this bar wraps to two lines on a phone. Renders nothing at
         all unless a view-as is live. -->
    <ViewAsBanner />

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
          class="font-label relative flex min-h-[66px] flex-1 flex-col items-center justify-center gap-1 border-t-2 border-transparent text-xs font-semibold tracking-[0.1em] text-[#8E8A80] uppercase"
          active-class="!text-ink !border-ink -mt-px"
        >
          <NavBadge
            v-if="item.badge"
            class="absolute top-2 left-1/2 ml-1.5"
            variant="bar"
            :count="item.badge.count"
            :late="item.badge.late"
            :label="item.badge.label"
          />
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
            <!-- Sunrise: the morning briefing. -->
            <template v-if="item.icon === 'overview'">
              <path d="M3 17h18" />
              <path d="M7 17a5 5 0 0 1 10 0" />
              <path d="M12 6v3M5 9l1.5 1.5M19 9l-1.5 1.5" />
            </template>
            <!-- Trend line: sales intel. -->
            <template v-else-if="item.icon === 'intel'">
              <path d="M3 3v18h18" />
              <path d="M7 15l4-5 3 3 4-6" />
            </template>
            <template v-else-if="item.icon === 'today'">
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
            <!-- Magnifier: find an order by number. -->
            <template v-else-if="item.icon === 'lookup'">
              <circle cx="11" cy="11" r="7" />
              <path d="M20 20l-3.5-3.5" />
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
