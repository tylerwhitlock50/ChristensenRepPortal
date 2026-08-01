import { createRouter, createWebHistory } from 'vue-router'
import { until } from '@vueuse/core'
import { useSessionStore } from '@/stores/session'

declare module 'vue-router' {
  interface RouteMeta {
    /** Reachable without a session. Everything else requires one. */
    public?: boolean
    adminOnly?: boolean
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
      path: '/',
      name: 'today',
      component: () => import('@/pages/TodayView.vue'),
      meta: { title: 'Today' },
    },
    {
      path: '/tasks',
      name: 'tasks',
      component: () => import('@/pages/TasksView.vue'),
      meta: { title: 'Tasks' },
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
          meta: { title: 'Missions' },
        },
        {
          path: 'activity',
          name: 'admin-activity',
          component: () => import('@/pages/admin/AdminActivityView.vue'),
          meta: { title: 'Activity' },
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
    if (to.name === 'login' && session.isSignedIn) return { name: 'today' }
    return true
  }

  if (!session.isSignedIn) {
    return { name: 'login', query: { redirect: to.fullPath } }
  }

  if (to.meta.adminOnly && !session.isAdmin) {
    return { name: 'today' }
  }

  return true
})

router.afterEach((to) => {
  document.title = to.meta.title ? `${to.meta.title} · Rep Portal` : 'Rep Portal'
})

export default router
