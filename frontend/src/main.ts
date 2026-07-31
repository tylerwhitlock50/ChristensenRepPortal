import { createApp } from 'vue'
import { createPinia } from 'pinia'
import { VueQueryPlugin } from '@tanstack/vue-query'

import './style.css'
import App from './App.vue'
import router from './router'
import { queryClient } from './lib/queryClient'
import { useSessionStore } from './stores/session'

async function bootstrap() {
  const app = createApp(App)

  app.use(createPinia())
  app.use(VueQueryPlugin, { queryClient })

  // Resolve the session before the router mounts, so a deep link never flashes
  // the login screen on its way to the page the user actually asked for.
  await useSessionStore().init()

  app.use(router)
  await router.isReady()
  app.mount('#app')
}

void bootstrap()
