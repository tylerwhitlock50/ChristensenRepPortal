<script setup lang="ts">
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useSessionStore } from '@/stores/session'
import AppButton from '@/components/ui/AppButton.vue'

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
  <div class="grid min-h-svh place-items-center bg-zinc-50 px-4 py-10">
    <div class="w-full max-w-sm">
      <div class="mb-8 text-center">
        <span
          class="mx-auto mb-3 block size-3 rounded-sm bg-amber-500"
          aria-hidden="true"
        />
        <h1 class="text-xl font-semibold tracking-tight text-zinc-900">
          Rep Portal
        </h1>
        <p class="mt-1 text-sm text-zinc-500">
          Sign in to see today's accounts.
        </p>
      </div>

      <form
        class="space-y-4 rounded-xl border border-zinc-200 bg-white p-5"
        novalidate
        @submit.prevent="submit"
      >
        <div>
          <label
            for="email"
            class="mb-1 block text-sm font-medium text-zinc-700"
          >
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
            class="tap-target w-full rounded-lg border border-zinc-300 px-3 outline-none focus:border-zinc-900"
          />
        </div>

        <div>
          <label
            for="password"
            class="mb-1 block text-sm font-medium text-zinc-700"
          >
            Password
          </label>
          <input
            id="password"
            v-model="password"
            type="password"
            autocomplete="current-password"
            required
            class="tap-target w-full rounded-lg border border-zinc-300 px-3 outline-none focus:border-zinc-900"
          />
        </div>

        <p
          v-if="error"
          role="alert"
          class="rounded-lg bg-red-50 px-3 py-2 text-sm text-red-800"
        >
          {{ error }}
        </p>

        <AppButton
          type="submit"
          size="lg"
          block
          :loading="busy"
          :disabled="!email || !password"
        >
          Sign in
        </AppButton>
      </form>

      <p class="mt-4 text-center text-xs text-zinc-500">
        Accounts are created by your sales ops admin. There is no self-signup.
      </p>
    </div>
  </div>
</template>
