<script setup lang="ts">
import { ref } from 'vue'
import { useSessionStore } from '@/stores/session'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'

/**
 * Change password, for someone who is signed in and knows their current one.
 * The locked-out case is the "Forgot your password?" link on the sign-in
 * screen and lands at /reset-password; this page never handles a recovery
 * link, so a credential in the URL is simply ignored here.
 *
 * Reached from the account menu, like Connect Claude: a once-in-a-while
 * chore, not a tab.
 */
const session = useSessionStore()

/** Matches the 12-character floor the admin-create-user function enforces. */
const MIN_LENGTH = 12

const current = ref('')
const password = ref('')
const confirm = ref('')
const error = ref('')
const busy = ref(false)
const done = ref(false)

async function submit() {
  error.value = ''
  if (password.value.length < MIN_LENGTH) {
    error.value = `Use at least ${MIN_LENGTH} characters.`
    return
  }
  if (password.value === current.value) {
    error.value = 'The new password is the same as the current one.'
    return
  }
  if (password.value !== confirm.value) {
    error.value = 'Those two passwords do not match.'
    return
  }
  busy.value = true
  try {
    await session.changePassword(current.value, password.value)
    current.value = ''
    password.value = ''
    confirm.value = ''
    done.value = true
  } catch (e) {
    error.value = (e as Error).message || 'Could not change the password.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div class="space-y-4">
    <header>
      <h1 class="font-display text-ink text-xl font-bold tracking-[0.06em] uppercase">
        Change password
      </h1>
      <p class="text-muted mt-1 max-w-2xl text-sm">
        For <strong class="text-ink">{{ session.user?.email }}</strong>. You stay
        signed in on this device; any other device signed in to this account is
        signed out.
      </p>
    </header>

    <AppCard title="New password">
      <template v-if="done">
        <p class="text-ink-2 text-[15px] leading-relaxed">
          Password changed. Use the new one next time you sign in.
        </p>
        <AppButton variant="secondary" class="mt-4" @click="done = false">
          Change it again
        </AppButton>
      </template>

      <form v-else class="max-w-sm space-y-4" novalidate @submit.prevent="submit">
        <!-- The browser must not treat this as a sign-in form: the email is
             present only so password managers can file the new entry under
             the right account. -->
        <input
          type="email"
          name="username"
          autocomplete="username"
          :value="session.user?.email ?? ''"
          readonly
          hidden
          tabindex="-1"
          aria-hidden="true"
        />

        <div>
          <label for="current-password" class="u-label text-ink-2 mb-1.5 block">
            Current password
          </label>
          <input
            id="current-password"
            v-model="current"
            type="password"
            autocomplete="current-password"
            required
            class="field"
          />
        </div>

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
          <p class="text-muted mt-1.5 text-xs">At least {{ MIN_LENGTH }} characters.</p>
        </div>

        <div>
          <label for="confirm-password" class="u-label text-ink-2 mb-1.5 block">
            Confirm new password
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
          :disabled="!current || !password || !confirm"
        >
          Change password
        </AppButton>
      </form>
    </AppCard>

    <p class="text-muted max-w-2xl text-sm">
      Forgot the current one? Sign out, then use
      <strong class="text-ink">Forgot your password?</strong> on the sign-in
      screen to get a reset link by email.
    </p>
  </div>
</template>
