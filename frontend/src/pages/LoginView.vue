<script setup lang="ts">
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useSessionStore } from '@/stores/session'
import AppButton from '@/components/ui/AppButton.vue'
import hero from '@/assets/hero.png'

const session = useSessionStore()
const router = useRouter()
const route = useRoute()

const email = ref('')
const password = ref('')
const error = ref('')
const busy = ref(false)

async function submit() {
  error.value = ''
  busy.value = true
  try {
    await session.signIn(email.value, password.value)
    const redirect = route.query.redirect
    await router.replace(
      typeof redirect === 'string' && redirect.startsWith('/')
        ? redirect
        : { name: 'today' },
    )
  } catch (e) {
    const message = (e as Error).message ?? ''
    // Supabase returns "Invalid login credentials"; say something a rep in a
    // parking lot can act on.
    error.value = /invalid login/i.test(message)
      ? 'That email and password combination did not work.'
      : message || 'Could not sign in. Try again.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="bg-ink flex min-h-svh flex-col">
    <!-- The only place photography earns its keep. -->
    <div
      class="relative flex min-h-[38svh] items-end bg-cover bg-center p-6 grayscale-[35%]"
      :style="{ backgroundImage: `url(${hero})` }"
    >
      <div
        class="absolute inset-0 bg-gradient-to-b from-transparent via-transparent to-[#12130F]"
        aria-hidden="true"
      />
      <div class="relative flex flex-col gap-2">
        <span
          class="font-label text-accent text-xs font-semibold tracking-[0.24em] uppercase"
        >
          Field Sales
        </span>
        <h1 class="u-display text-canvas text-[42px] leading-[0.95]">
          Christensen Arms<br />Rep Portal
        </h1>
      </div>
    </div>

    <div class="bg-canvas text-ink flex flex-1 justify-center px-6 py-7">
      <div class="flex w-full max-w-sm flex-col">
        <form class="space-y-4" novalidate @submit.prevent="submit">
          <div>
            <label for="email" class="u-label mb-1.5 block text-ink-2">
              Email
            </label>
            <input
              id="email"
              v-model="email"
              type="email"
              autocomplete="username"
              inputmode="email"
              autocapitalize="none"
              spellcheck="false"
              required
              class="field"
            />
          </div>

          <div>
            <label for="password" class="u-label mb-1.5 block text-ink-2">
              Password
            </label>
            <input
              id="password"
              v-model="password"
              type="password"
              autocomplete="current-password"
              required
              class="field"
            />
          </div>

          <p
            v-if="error"
            role="alert"
            class="border-line bg-surface border-l-accent border border-l-[3px] px-3 py-2.5 text-sm"
          >
            {{ error }}
          </p>

          <AppButton
            type="submit"
            variant="primary"
            size="lg"
            block
            :loading="busy"
            :disabled="!email || !password"
          >
            Sign in
          </AppButton>
        </form>

        <p class="text-muted mt-4 text-sm leading-relaxed">
          Sales ops makes accounts. There is no self-signup — if you can't get
          in, call your admin.
        </p>

        <div class="border-line mt-auto flex items-center gap-2.5 border-t pt-4">
          <span class="bg-accent block h-4 w-[3px]" aria-hidden="true" />
          <span class="font-label text-muted text-xs font-semibold tracking-[0.16em] uppercase">
            Rep Portal · Field Sales
          </span>
        </div>
      </div>
    </div>
  </div>
</template>
