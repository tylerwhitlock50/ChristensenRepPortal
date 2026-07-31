import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
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
      session.value = next
      if (!next) {
        profile.value = null
        return
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

  async function signOut() {
    await supabase.auth.signOut()
    session.value = null
    profile.value = null
  }

  return {
    session,
    profile,
    ready,
    user,
    isSignedIn,
    role,
    isAdmin,
    displayName,
    init,
    loadProfile,
    signIn,
    signOut,
  }
})
