import { createRouter, createWebHistory } from 'vue-router'
import { until } from '@vueuse/core'
import { useSessionStore } from '@/stores/session'
import {
  ensureSettings,
  isFeatureEnabled,
  type FeatureKey,
} from '@/composables/useAppSettings'

declare module 'vue-router' {
  interface RouteMeta {
    /** Reachable without a session. Everything else requires one. */
    public?: boolean
    adminOnly?: boolean
    /**
     * Route exists only while this app_settings flag is enabled; disabled
     * flags redirect to the Overview. Lets hidden capture features (Today,
     * Tasks) come back with a toggle instead of a deploy.
     */
    feature?: FeatureKey
    title?: string
  }
}

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  scrollBehavior: (_to, _from, saved) => saved ?? { top: 0 },
  routes: [
    {
      path: '/login',
      name: 'login',
      component: () => import('@/pages/LoginView.vue'),
      meta: { public: true, title: 'Sign in' },
    },
    {
      // The morning briefing IS the app's front door (data-first restructure):
      // territory health, the AI sales brief, movers, worth-investigating.
      path: '/',
      name: 'overview',
      component: () => import('@/pages/OverviewView.vue'),
      meta: { title: 'Overview' },
    },
    {
      // The old landing page, kept intact behind the recommendations flag.
      path: '/today',
      name: 'today',
      component: () => import('@/pages/TodayView.vue'),
      meta: { title: 'Today', feature: 'feature.recommendations' },
    },
    {
      path: '/tasks',
      name: 'tasks',
      component: () => import('@/pages/TasksView.vue'),
      meta: { title: 'Tasks', feature: 'feature.tasks' },
    },
    {
      path: '/accounts',
      name: 'accounts',
      component: () => import('@/pages/AccountsView.vue'),
      meta: { title: 'Accounts' },
    },
    {
      path: '/accounts/:customerKey',
      name: 'account',
      component: () => import('@/pages/AccountView.vue'),
      props: true,
      meta: { title: 'Account' },
    },
    {
      path: '/intel',
      component: () => import('@/pages/intel/SalesIntelLayout.vue'),
      redirect: { name: 'intel-sku' },
      children: [
        {
          path: 'sku-sales',
          name: 'intel-sku',
          component: () => import('@/pages/intel/SkuSalesIntel.vue'),
          meta: { title: 'SKU Sales' },
        },
        {
          path: 'backlog',
          name: 'intel-backlog',
          component: () => import('@/pages/intel/BacklogIntel.vue'),
          meta: { title: 'Backlog' },
        },
        {
          path: 'ats',
          name: 'intel-ats',
          component: () => import('@/pages/intel/AtsIntel.vue'),
          meta: { title: 'ATS' },
        },
        {
          path: 'global',
          name: 'intel-global',
          component: () => import('@/pages/intel/GlobalIntel.vue'),
          meta: { title: 'Global' },
        },
      ],
    },
    {
      path: '/admin',
      component: () => import('@/pages/admin/AdminLayout.vue'),
      // adminOnly on the parent covers every child — vue-router merges parent
      // meta into to.meta, so the guard below keeps working unchanged.
      meta: { adminOnly: true },
      redirect: { name: 'admin-execution' },
      children: [
        {
          path: 'execution',
          name: 'admin-execution',
          component: () => import('@/pages/admin/AdminExecutionView.vue'),
          meta: { title: 'Execution' },
        },
        {
          path: 'users',
          name: 'admin-users',
          component: () => import('@/pages/admin/AdminUsersView.vue'),
          meta: { title: 'Users' },
        },
        {
          path: 'missions',
          name: 'admin-missions',
          component: () => import('@/pages/admin/AdminMissionsView.vue'),
          meta: { title: 'Missions', feature: 'feature.recommendations' },
        },
        {
          path: 'activity',
          name: 'admin-activity',
          component: () => import('@/pages/admin/AdminActivityView.vue'),
          meta: { title: 'Activity' },
        },
        {
          path: 'settings',
          name: 'admin-settings',
          component: () => import('@/pages/admin/AdminSettingsView.vue'),
          meta: { title: 'Settings' },
        },
      ],
    },
    {
      path: '/:pathMatch(.*)*',
      name: 'not-found',
      component: () => import('@/pages/NotFoundView.vue'),
      meta: { public: true, title: 'Not found' },
    },
  ],
})

router.beforeEach(async (to) => {
  const session = useSessionStore()

  // main.ts awaits init() before mounting, but a deep link that arrives during
  // a token refresh can still reach the guard first.
  if (!session.ready) await until(() => session.ready).toBe(true)

  if (to.meta.public) {
    // Don't strand a signed-in user on the login screen.
    if (to.name === 'login' && session.isSignedIn) return { name: 'overview' }
    return true
  }

  if (!session.isSignedIn) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }

  if (to.meta.adminOnly && !session.isAdmin) {
    return { name: 'overview' }
  }

  if (to.meta.feature) {
    // One round trip per session (ensureQueryData caches); a disabled feature
    // lands on the Overview rather than a dead page. If the settings table
    // itself is unreachable, fail closed to the Overview too.
    try {
      const settings = await ensureSettings()
      if (!isFeatureEnabled(settings, to.meta.feature)) {
        return { name: 'overview' }
      }
    } catch {
      return { name: 'overview' }
    }
  }

  return true
})

router.afterEach((to) => {
  document.title = to.meta.title ? `${to.meta.title} · Rep Portal` : 'Rep Portal'
})

export default router
