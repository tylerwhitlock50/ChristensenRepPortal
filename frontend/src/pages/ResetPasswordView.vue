<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { supabase } from '@/lib/supabase'
import { queryClient } from '@/lib/queryClient'
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
 * Three link shapes are handled, because which one arrives depends on the
 * project's email template and auth settings rather than on anything in
 * this repo:
 *
 *   token hash …/reset-password?token_hash=…&type=recovery → verifyOtp
 *   PKCE       …/reset-password?code=<uuid>                → exchangeCodeForSession
 *   implicit   …/reset-password#access_token=…&type=recovery → setSession
 *
 * The token-hash shape (supabase/templates/recovery.html) is the one the
 * project should be sending, and it is verified on SUBMIT rather than on
 * mount. The other two are consumed the moment the link is fetched, and the
 * auth logs show Outlook's link scanner fetching every reset link seconds
 * after it is sent — so by the time the rep tapped it, the one-time token
 * was already gone and they got "invalid or expired". A scanner can load
 * this page all it likes; nothing is spent until a person types a password
 * and presses Save.
 *
 * Supabase reports a link it could not honour as #error_code=otp_expired on
 * the same redirect; that lands here too (the router forwards it) and shows
 * the expired message instead of bouncing through /login.
 *
 * The credential is scrubbed from the address bar once consumed — a recovery
 * token sitting in browser history on a shared truck iPad is the same
 * problem as the cached-revenue leak signOut() already guards against. The
 * unconsumed token hash stays in the URL until then, so "open in Safari"
 * from a mail app's in-app browser still works.
 */

const router = useRouter()
const session = useSessionStore()

type Phase = 'checking' | 'ready' | 'invalid' | 'done'
const phase = ref<Phase>('checking')

/** Held from mount to submit; null for the two consumed-on-arrival shapes. */
const tokenHash = ref<string | null>(null)

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
  const url = new URL(window.location.href)
  const code = url.searchParams.get('code')
  const hashedToken = url.searchParams.get('token_hash')
  const linkType = url.searchParams.get('type')
  // The hash arrives as "#access_token=…&refresh_token=…&type=recovery", or
  // as "#error=access_denied&error_code=otp_expired&error_description=…".
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ''))
  const accessToken = hash.get('access_token')
  const refreshToken = hash.get('refresh_token')
  const authError = hash.get('error_code') ?? hash.get('error')

  if (authError) {
    clearCredentialFromUrl()
    phase.value = 'invalid'
    return
  }

  if (hashedToken && linkType === 'recovery') {
    tokenHash.value = hashedToken
    phase.value = 'ready'
    return
  }

  const hasCredential = !!code || !!(accessToken && refreshToken)

  // No credential in the URL: an admin who is already signed in can navigate
  // here on purpose, and that session is theirs to change a password on.
  // Only in that case — a recovery link must never be ignored in favour of
  // whoever happens to be signed in on this device, or the form below would
  // silently change the WRONG account's password.
  if (!hasCredential) {
    const existing = await supabase.auth.getSession()
    clearCredentialFromUrl()
    phase.value = existing.data.session ? 'ready' : 'invalid'
    return
  }

  try {
    // The recovery token always wins. Shared truck iPad, rep A still signed
    // in, rep B opens their reset email: without this the exchange below is
    // skipped and rep B types a new password onto rep A's session. Local
    // scope — the lingering session's refresh token is not ours to revoke.
    await supabase.auth.signOut({ scope: 'local' })
    queryClient.clear()

    if (code) {
      const { error: e } = await supabase.auth.exchangeCodeForSession(code)
      if (e) throw e
    } else {
      const { error: e } = await supabase.auth.setSession({
        access_token: accessToken!,
        refresh_token: refreshToken!,
      })
      if (e) throw e
    }
    phase.value = 'ready'
  } catch {
    phase.value = 'invalid'
  } finally {
    clearCredentialFromUrl()
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
    if (tokenHash.value) {
      // Same rule as the on-mount exchange: the recovery token always wins
      // over whoever is still signed in on this device.
      await supabase.auth.signOut({ scope: 'local' })
      queryClient.clear()
      const { error: e } = await supabase.auth.verifyOtp({
        token_hash: tokenHash.value,
        type: 'recovery',
      })
      tokenHash.value = null
      clearCredentialFromUrl()
      if (e) {
        phase.value = 'invalid'
        return
      }
    }
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
