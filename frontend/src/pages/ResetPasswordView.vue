<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'
import AppButton from '@/components/ui/AppButton.vue'

/**
 * Where the "reset your password" email lands.
 *
 * The client is created with `detectSessionInUrl: false` (lib/supabase.ts), so
 * nothing parses the recovery credential for us — and that default is worth
 * keeping, because it means no other route in the app will ever silently
 * adopt a session out of a URL. This one route opts in explicitly.
 *
 * Both link shapes are handled, because which one arrives depends on the
 * project's auth settings rather than on anything in this repo:
 *
 *   PKCE     …/reset-password?code=<uuid>        → exchangeCodeForSession
 *   implicit …/reset-password#access_token=…&type=recovery → setSession
 *
 * The credential is scrubbed from the address bar either way once consumed —
 * a recovery token sitting in browser history on a shared truck iPad is the
 * same problem as the cached-revenue leak signOut() already guards against.
 */

const router = useRouter()
const session = useSessionStore()

type Phase = 'checking' | 'ready' | 'invalid' | 'done'
const phase = ref<Phase>('checking')

const password = ref('')
const confirm = ref('')
const error = ref('')
const busy = ref(false)

/** Matches the 12-character floor the admin-create-user function enforces. */
const MIN_LENGTH = 12

function clearCredentialFromUrl() {
  window.history.replaceState({}, '', window.location.pathname)
}

onMounted(async () => {
  // An admin who is already signed in can land here too; that session is fine
  // to change a password on, so don't fight it.
  const existing = await supabase.auth.getSession()
  if (existing.data.session) {
    phase.value = 'ready'
    return
  }

  const url = new URL(window.location.href)
  const code = url.searchParams.get('code')
  // The hash arrives as "#access_token=…&refresh_token=…&type=recovery".
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ''))
  const accessToken = hash.get('access_token')
  const refreshToken = hash.get('refresh_token')

  try {
    if (code) {
      const { error: e } = await supabase.auth.exchangeCodeForSession(code)
      if (e) throw e
    } else if (accessToken && refreshToken) {
      const { error: e } = await supabase.auth.setSession({
        access_token: accessToken,
        refresh_token: refreshToken,
      })
      if (e) throw e
    } else {
      phase.value = 'invalid'
      return
    }
    clearCredentialFromUrl()
    phase.value = 'ready'
  } catch {
    clearCredentialFromUrl()
    phase.value = 'invalid'
  }
})

async function submit() {
  error.value = ''
  if (password.value.length < MIN_LENGTH) {
    error.value = `Use at least ${MIN_LENGTH} characters.`
    return
  }
  if (password.value !== confirm.value) {
    error.value = 'Those two passwords do not match.'
    return
  }
  busy.value = true
  try {
    await session.updatePassword(password.value)
    // Sign out rather than dropping them straight in: the recovery link is a
    // credential in an inbox, and ending its session here means a forwarded
    // email cannot also be a live login.
    await session.signOut()
    phase.value = 'done'
  } catch (e) {
    error.value = (e as Error).message || 'Could not set that password.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="bg-canvas text-ink flex min-h-svh justify-center px-6 py-10">
    <div class="flex w-full max-w-sm flex-col">
      <h1 class="u-display text-[32px]">Set a new password</h1>

      <p v-if="phase === 'checking'" class="text-muted mt-4 text-[15px]">
        Checking your link…
      </p>

      <template v-else-if="phase === 'invalid'">
        <p class="text-ink-2 mt-4 text-[15px] leading-relaxed">
          That reset link has expired or has already been used. Reset links are
          good for one use and a short window — ask for a fresh one and open it
          on this device.
        </p>
        <RouterLink :to="{ name: 'login' }" class="mt-6">
          <AppButton variant="secondary" block>Back to sign in</AppButton>
        </RouterLink>
      </template>

      <template v-else-if="phase === 'done'">
        <p class="text-ink-2 mt-4 text-[15px] leading-relaxed">
          Password changed. Sign in with it now.
        </p>
        <AppButton
          variant="primary"
          size="lg"
          block
          class="mt-6"
          @click="router.replace({ name: 'login' })"
        >
          Sign in
        </AppButton>
      </template>

      <form v-else class="mt-5 space-y-4" novalidate @submit.prevent="submit">
        <div>
          <label for="new-password" class="u-label text-ink-2 mb-1.5 block">
            New password
          </label>
          <input
            id="new-password"
            v-model="password"
            type="password"
            autocomplete="new-password"
            required
            class="field"
          />
          <p class="text-muted mt-1.5 text-xs">
            At least {{ MIN_LENGTH }} characters.
          </p>
        </div>

        <div>
          <label for="confirm-password" class="u-label text-ink-2 mb-1.5 block">
            Confirm password
          </label>
          <input
            id="confirm-password"
            v-model="confirm"
            type="password"
            autocomplete="new-password"
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
          :disabled="!password || !confirm"
        >
          Save password
        </AppButton>
      </form>
    </div>
  </div>
</template>
