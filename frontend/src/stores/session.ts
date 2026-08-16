import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import type { Session, SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { queryClient } from '@/lib/queryClient'
import { fetchActingContext, type ActingContext } from '@/composables/useViewAs'
import type { Tables } from '@/types/database.types'
import type { Role } from '@/types/domain'

export type Profile = Tables<'profiles'>

/** 20260816140000 lands after database.types.ts was last generated. */
const db = supabase as unknown as SupabaseClient

/**
 * Session + profile only. Everything that comes from the database lives in
 * TanStack Query, not here (TECH_STACK §2.3).
 *
 * The one addition to that rule is the acting context (admin "view as rep").
 * It belongs here for the same reason the profile does: the router guard and
 * the shell both consult it before any page query runs, and it decides what
 * every one of those queries will come back with.
 */
export const useSessionStore = defineStore('session', () => {
  const session = ref<Session | null>(null)
  const profile = ref<Profile | null>(null)
  /** Null until loaded, and whenever the migration is not applied. */
  const acting = ref<ActingContext | null>(null)
  /** False until the initial getSession() has resolved — guards must wait. */
  const ready = ref(false)

  const user = computed(() => session.value?.user ?? null)
  const isSignedIn = computed(() => !!session.value && !!profile.value)

  /* ---- identity: real vs effective ------------------------------------- */

  /** True while this admin is viewing the portal as somebody else. */
  const isViewingAs = computed(() => acting.value?.impersonating === true)

  /**
   * The credential-holder's own role. Only three things care: whether to
   * offer the picker at all, whether to keep offering it mid-session, and
   * how to render the account menu. Everything else wants `role`.
   */
  const realRole = computed<Role | null>(
    () => (profile.value?.role as Role | undefined) ?? null,
  )
  const isRealAdmin = computed(
    () => acting.value?.real_is_admin ?? realRole.value === 'admin',
  )

  /**
   * The role the APP should behave as, mirroring public.is_admin() in the
   * database. Viewing as a rep makes this 'rep', which is what hides the
   * admin nav and turns the admin-only routes away — matching the fact that
   * those routes' queries would now come back empty anyway.
   */
  const role = computed<Role | null>(() =>
    isViewingAs.value
      ? ((acting.value?.target_role as Role | undefined) ?? 'rep')
      : realRole.value,
  )
  const isAdmin = computed(() => role.value === 'admin')
  const isOrderEntry = computed(() => role.value === 'order_entry')

  /** The account menu is about YOUR account, so it keeps the real name. */
  const displayName = computed(
    () => profile.value?.full_name || user.value?.email || 'Signed in',
  )

  /**
   * View-as is read-only, and the database enforces it (a trigger on every
   * RLS-enabled table raises 42501). This is what lets the UI stop offering
   * writes it knows will be refused, rather than surfacing an error after
   * the rep-portal user has typed out a visit survey.
   */
  const canWrite = computed(() => isSignedIn.value && !isViewingAs.value)

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
   * Re-read who the database thinks we are acting as. Cheap (one RPC over a
   * one-row table) and load-bearing: it is also how a server-side expiry or
   * a stop issued from another tab reaches this one.
   */
  async function loadActingContext(): Promise<ActingContext | null> {
    if (!session.value) {
      acting.value = null
      return null
    }
    try {
      acting.value = await fetchActingContext()
    } catch {
      // Never wedge the app on this. Falling back to null means "not viewing
      // as anyone", which is the safe read: the UI offers full admin, and
      // any write it then allows is checked by RLS anyway.
      acting.value = null
    }
    return acting.value
  }

  /**
   * Switch to seeing the portal as `userId`, or (null) stop.
   *
   * The cache clear is the whole client-side implementation. Query keys are
   * scoped by account and by page, never by user — the same reasoning that
   * made signOut() clear it — so without this the admin would be handed
   * their own territory totals out of cache with no network request at all.
   */
  async function setViewAs(userId: string | null) {
    if (userId) {
      const { error } = await db.rpc('start_impersonation', {
        p_target_user_id: userId,
      })
      if (error) throw error
    } else {
      const { error } = await db.rpc('stop_impersonation')
      if (error) throw error
    }
    await loadActingContext()
    queryClient.clear()
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
      // Before ready, not after: the router guard reads isAdmin, and an admin
      // who reloads the page mid-view-as must not be waved through to /admin
      // for the frame it takes this to resolve.
      await loadActingContext()
    }
    ready.value = true

    supabase.auth.onAuthStateChange((event, next) => {
      const previousUserId = session.value?.user.id
      session.value = next
      if (!next) {
        profile.value = null
        acting.value = null
        // Signed out in another tab, or the refresh token was revoked.
        queryClient.clear()
        return
      }
      // A different user signed in without a reload — same leak, same fix.
      if (previousUserId && previousUserId !== next.user.id) {
        acting.value = null
        queryClient.clear()
      }
      // TOKEN_REFRESHED fires often; the profile hasn't changed.
      if (event === 'SIGNED_IN' || event === 'USER_UPDATED') {
        void loadProfile().catch(() => {})
        void loadActingContext()
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

    // Normally null — signOut() ends any view-as. It can still be set here
    // if the last session died without one (expired refresh token, cleared
    // storage), and signing back in to the rep's view unannounced would be
    // the worst version of this feature. Loading it means the banner is up
    // on the first frame.
    await loadActingContext()

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
    // Before the sign-out, because the RPC needs the JWT. View-as state is
    // server-side and outlives the browser session, so without this an admin
    // who signs out mid-view-as signs back in still looking at the rep's
    // book. Best-effort: a failed clear must never trap someone in a
    // half-signed-out state, and the 12-hour expiry is the backstop.
    if (isViewingAs.value) {
      try {
        await db.rpc('stop_impersonation')
      } catch {
        /* expiry will catch it */
      }
    }
    await supabase.auth.signOut()
    session.value = null
    profile.value = null
    acting.value = null
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
    acting,
    ready,
    user,
    isSignedIn,
    role,
    isAdmin,
    isOrderEntry,
    realRole,
    isRealAdmin,
    isViewingAs,
    canWrite,
    displayName,
    init,
    loadProfile,
    loadActingContext,
    setViewAs,
    signIn,
    signOut,
    requestPasswordReset,
    updatePassword,
  }
})
