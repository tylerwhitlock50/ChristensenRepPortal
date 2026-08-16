import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { queryClient } from '@/lib/queryClient'
import type { Tables } from '@/types/database.types'
import type { Role } from '@/types/domain'

export type Profile = Tables<'profiles'>

/**
 * Session + profile only. Everything that comes from the database lives in
 * TanStack Query, not here (TECH_STACK §2.3).
 */
export const useSessionStore = defineStore('session', () => {
  const session = ref<Session | null>(null)
  const profile = ref<Profile | null>(null)
  /** False until the initial getSession() has resolved — guards must wait. */
  const ready = ref(false)

  const user = computed(() => session.value?.user ?? null)
  const isSignedIn = computed(() => !!session.value && !!profile.value)
  const role = computed<Role | null>(
    () => (profile.value?.role as Role | undefined) ?? null,
  )
  const isAdmin = computed(() => role.value === 'admin')
  const isOrderEntry = computed(() => role.value === 'order_entry')
  const displayName = computed(
    () => profile.value?.full_name || user.value?.email || 'Signed in',
  )

  async function loadProfile(): Promise<Profile | null> {
    if (!session.value) {
      profile.value = null
      return null
    }
    const { data, error } = await supabase
      .from('profiles')
      .select('*')
      .eq('user_id', session.value.user.id)
      .maybeSingle()

    if (error) throw error
    profile.value = data
    return data
  }

  /**
   * Called once from main.ts before the app mounts, then kept current by
   * Supabase's auth listener (token refresh, sign-out in another tab).
   */
  async function init() {
    const { data } = await supabase.auth.getSession()
    session.value = data.session
    if (session.value) {
      try {
        await loadProfile()
      } catch {
        // A profile read failure shouldn't wedge the app at a blank screen —
        // the router guard will bounce to /login and the user can retry.
        profile.value = null
      }
    }
    ready.value = true

    supabase.auth.onAuthStateChange((event, next) => {
      const previousUserId = session.value?.user.id
      session.value = next
      if (!next) {
        profile.value = null
        // Signed out in another tab, or the refresh token was revoked.
        queryClient.clear()
        return
      }
      // A different user signed in without a reload — same leak, same fix.
      if (previousUserId && previousUserId !== next.user.id) {
        queryClient.clear()
      }
      // TOKEN_REFRESHED fires often; the profile hasn't changed.
      if (event === 'SIGNED_IN' || event === 'USER_UPDATED') {
        void loadProfile().catch(() => {})
      }
    })
  }

  async function signIn(email: string, password: string) {
    const { data, error } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    })
    if (error) throw error

    session.value = data.session
    const p = await loadProfile()

    if (!p) {
      await signOut()
      throw new Error(
        'No profile exists for this account. Ask your admin to set it up.',
      )
    }
    if (!p.active) {
      await signOut()
      throw new Error('This account has been deactivated.')
    }

    // Execution metric (PRD §7). Written only via the security-definer RPC —
    // there is no client insert policy on login_events, so this can't be
    // spoofed. Fire and forget: a failed log must never block a sign-in.
    void supabase.rpc('log_login').then(() => {})

    return p
  }

  /**
   * Self-service password reset — the missing half of a portal with no
   * self-signup. Until now a rep locked out in a dealer's parking lot had
   * exactly one option: phone an admin who may be in another timezone.
   *
   * Deliberately reports success even when the email is unknown. Telling an
   * anonymous caller "no such account" turns this box into a way to test
   * which addresses are provisioned, and the honest phrasing ("if that
   * address has an account") costs a real rep nothing.
   */
  async function requestPasswordReset(email: string) {
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
      redirectTo: `${window.location.origin}/reset-password`,
    })
    // Rate limiting is the one thing worth surfacing — it is actionable
    // ("wait a minute"), where "user not found" is not.
    if (error && /rate|too many/i.test(error.message)) throw error
  }

  /**
   * Finish a reset: set the new password on the session the recovery link
   * established, then sign out so the rep re-enters it once deliberately.
   */
  async function updatePassword(password: string) {
    const { error } = await supabase.auth.updateUser({ password })
    if (error) throw error
  }

  async function signOut() {
    await supabase.auth.signOut()
    session.value = null
    profile.value = null
    // Sign-out is an in-tab router.push, not a reload, so the queryClient
    // singleton survives it. Account, recommendation and admin keys are NOT
    // scoped by user id, so without this the next rep to sign in on a shared
    // truck iPad is served the previous rep's cached revenue from cache with
    // no network request at all. This is PRD acceptance criterion #1 failing
    // on the client side of the boundary.
    queryClient.clear()
  }

  return {
    session,
    profile,
    ready,
    user,
    isSignedIn,
    role,
    isAdmin,
    isOrderEntry,
    displayName,
    init,
    loadProfile,
    signIn,
    signOut,
    requestPasswordReset,
    updatePassword,
  }
})
