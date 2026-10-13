import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import type { Session, SupabaseClient } from '@supabase/supabase-js'
import { onlineManager } from '@tanstack/vue-query'
import { isNoConnection, storedSession, supabase } from '@/lib/supabase'
import { queryClient } from '@/lib/queryClient'
import {
  readOfflineIdentity,
  readPersistedCache,
  restorePersistedCache,
  saveOfflineIdentity,
  savedCacheTimestamp,
  startPersisting,
  wipePersistedCache,
  type OfflineIdentity,
} from '@/lib/queryPersist'
import { fetchActingContext, type ActingContext } from '@/composables/useViewAs'
import type { Tables } from '@/types/database.types'
import type { Role } from '@/types/domain'

export type Profile = Tables<'profiles'>

/** 20260816140000 lands after database.types.ts was last generated. */
const db = supabase as unknown as SupabaseClient

/**
 * How long a boot waits on a sign-in check that isn't answering before it
 * opens on the rep's saved copy instead. supabase-js keeps retrying a token
 * refresh for up to ~25 s with no signal; nobody in a store should stare at
 * a skeleton for that.
 */
const OFFLINE_OPEN_AFTER_MS = 6_000
/** While offline, how often to try the network again (if the phone says it has one). */
const RECONNECT_EVERY_MS = 30_000
const OFFLINE_RESTORE_BUDGET_MS = 3_000

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
  /**
   * Set while the app is open on the rep's saved copy because the network
   * can't confirm the sign-in (see openOffline): when that copy was saved.
   */
  const offlineSince = ref<number | null>(null)

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

  /** Open on saved data with the sign-in unconfirmed: read-only until it is. */
  const isOffline = computed(() => offlineSince.value !== null)

  /**
   * View-as is read-only, and the database enforces it (a trigger on every
   * RLS-enabled table raises 42501). This is what lets the UI stop offering
   * writes it knows will be refused, rather than surfacing an error after
   * the rep-portal user has typed out a visit survey. The offline open is
   * read-only for a plainer reason: the sign-in is not confirmed yet.
   */
  const canWrite = computed(
    () => isSignedIn.value && !isViewingAs.value && !isOffline.value,
  )

  /**
   * Whether this identity may keep the ERP read cache on the device between
   * opens (lib/queryPersist.ts). Reps only: an admin's cache is the whole
   * company, and only admins can view-as — which is how a saved cache could
   * end up holding somebody else's book under your name.
   */
  const keepsSavedCache = computed(
    () =>
      !!session.value &&
      profile.value?.role === 'rep' &&
      profile.value.active === true &&
      !isViewingAs.value,
  )

  /**
   * Bring the saved cache in line with who is signed in: restore it (boot
   * only) and keep saving for a rep; delete it for anyone else. Never
   * throws, never takes longer than the restore budget.
   */
  async function syncSavedCache(opts: { restore: boolean }) {
    const userId = session.value?.user.id
    if (!userId) {
      void wipePersistedCache()
      return
    }
    // The profile read failed (no signal, usually): we can't tell yet who
    // this is, so leave the saved copy exactly as it is.
    if (!profile.value) return
    if (keepsSavedCache.value) {
      if (opts.restore) await restorePersistedCache(userId)
      startPersisting(userId)
      saveOfflineIdentity(userId, profile.value)
    } else {
      void wipePersistedCache()
    }
  }

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
   * The cache reset is the whole client-side implementation. Query keys are
   * scoped by account and by page, never by user — the same reasoning that
   * made signOut() clear it — so without this the admin would be handed
   * their own territory totals out of cache with no network request at all.
   *
   * resetQueries(), not clear(): clear() drops the cache entries but never
   * tells a mounted observer, so a page that stays up across the switch
   * (Overview while changing rep in the banner, or on Exit) kept rendering
   * the previous identity's rows. Reset puts every query back to its initial
   * state AND refetches the ones something is still watching.
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
    void syncSavedCache({ restore: false })
    await queryClient.resetQueries()
  }

  /* ---- offline open ---------------------------------------------------- */

  /**
   * Opening the app in a dead zone. With an expired access token and no
   * signal, supabase-js cannot refresh the session and reports none, and
   * the router sent the rep to /login — with their accounts saved on the
   * phone and no way to reach them. Now, if the sign-in check fails for
   * lack of a connection (never on a rejection), the app opens read-only on
   * what this phone saved for this same user, and keeps trying.
   *
   * What it takes, all of it:
   *   - a session supabase-js still holds in storage for user U (so U was
   *     signed in here and never signed out — sign-out deletes it);
   *   - a saved identity for U from lib/queryPersist: an active rep, saved
   *     online within 24 hours, same build. Admins and order entry never
   *     have one, so they never open offline;
   *   - a failure that is a missing connection: no answer, a timeout, a
   *     network error. A refresh token the server REJECTS (revoked, user
   *     deleted) is an answer: supabase-js drops the session from storage,
   *     SIGNED_OUT deletes the saved copy, and AppShell goes to /login.
   *
   * Nothing new is exposed: it shows only what is already in this phone's
   * IndexedDB, nothing is written while offline (canWrite is false), and no
   * request leaves until a real sign-in comes back. Back online, the session
   * is verified, the profile re-read, and a rep deactivated meanwhile is
   * signed out and the copy deleted.
   */
  async function openOffline(saved: OfflineIdentity<Profile>, stored: Session) {
    session.value = stored
    profile.value = saved.profile
    acting.value = null
    // Queries wait instead of failing one by one: no request until the
    // sign-in is real again (goOnline). TanStack would flip itself back
    // online on the browser's 'online' event, before anything is verified,
    // so its listener is swapped out until leaveOffline().
    onlineManager.setEventListener(() => undefined)
    onlineManager.setOnline(false)
    // A longer wait than an online boot allows: with no network there is
    // nothing else to show, and a slow phone's IndexedDB is still quicker
    // than an empty screen.
    await restorePersistedCache(stored.user.id, {
      budgetMs: OFFLINE_RESTORE_BUDGET_MS,
      // Slower still: apply it when it comes, if we're still offline as U.
      applyLate: () => isOffline.value && session.value?.user.id === stored.user.id,
    })
    offlineSince.value = (await savedCacheTimestamp(stored.user.id)) ?? saved.savedAt
    startReconnecting()
  }

  let reconnectTimer: ReturnType<typeof setInterval> | null = null
  let reconnecting = false

  function startReconnecting() {
    if (reconnectTimer) return
    window.addEventListener('online', reconnect)
    reconnectTimer = setInterval(() => {
      if (navigator.onLine !== false) void reconnect()
    }, RECONNECT_EVERY_MS)
  }

  function stopReconnecting() {
    window.removeEventListener('online', reconnect)
    if (reconnectTimer) clearInterval(reconnectTimer)
    reconnectTimer = null
  }

  function leaveOffline() {
    offlineSince.value = null
    stopReconnecting()
    onlineManager.setEventListener(followBrowserConnectivity)
    onlineManager.setOnline(navigator.onLine !== false)
  }

  /** TanStack's default onlineManager listener, put back after offline mode. */
  function followBrowserConnectivity(setOnline: (online: boolean) => void) {
    const on = () => setOnline(true)
    const off = () => setOnline(false)
    window.addEventListener('online', on)
    window.addEventListener('offline', off)
    return () => {
      window.removeEventListener('online', on)
      window.removeEventListener('offline', off)
    }
  }

  /**
   * Whether the server has said no, as opposed to not answering. The one
   * reliable sign is supabase-js dropping the session from storage, which it
   * does only on a rejected refresh — not on a network error, and not on its
   * own bookkeeping errors (a refresh discarded because another tab won).
   */
  function sessionWasRejected(): boolean {
    return storedSession() === null
  }

  /** Try the sign-in again; the 'online' event and a timer call this. */
  async function reconnect() {
    if (!isOffline.value || reconnecting) return
    const { data } = await supabase.auth.getSession()
    if (data.session) await goOnline(data.session)
    else if (sessionWasRejected()) await endRejected()
  }

  /** The sign-in is real again: verify who this is, then carry on online. */
  async function goOnline(next: Session) {
    if (!isOffline.value || reconnecting) return
    reconnecting = true
    try {
      session.value = next
      let failure: unknown = null
      const fresh = await loadProfile().catch((e) => {
        failure = e
        return undefined
      })
      if (fresh === undefined) {
        // No signal yet: stay on the saved copy and try again next time.
        if (isNoConnection(failure)) return
        // The database answered and refused. Same as an online boot that
        // can't read the profile: no profile, so the shell sends the rep to
        // /login. The saved copy is left alone, as it is there.
        leaveOffline()
        profile.value = null
        return
      }
      if (!fresh || !fresh.active) {
        await signOut()
        leaveOffline()
        return
      }
      await loadActingContext()
      leaveOffline()
      await syncSavedCache({ restore: false })
    } finally {
      reconnecting = false
    }
  }

  /** The server said no while we were offline: same as any sign-out. */
  async function endRejected() {
    leaveOffline()
    session.value = null
    profile.value = null
    acting.value = null
    const wiped = wipePersistedCache()
    queryClient.clear()
    await wiped
  }

  /**
   * Resolves with the saved identity when the boot should stop waiting on
   * the network: at once if the phone reports no connection, else after
   * OFFLINE_OPEN_AFTER_MS. Never resolves without a usable saved identity.
   */
  function offlineFallback(saved: Promise<OfflineIdentity<Profile> | null>): {
    fallback: Promise<OfflineIdentity<Profile>>
    cancel: () => void
  } {
    let cancelled = false
    let timer: ReturnType<typeof setTimeout> | undefined
    let onOffline: (() => void) | undefined
    const cancel = () => {
      cancelled = true
      clearTimeout(timer)
      if (onOffline) window.removeEventListener('offline', onOffline)
    }
    const fallback = saved.then(
      (identity) =>
        new Promise<OfflineIdentity<Profile>>((resolve) => {
          if (!identity || cancelled) return
          if (navigator.onLine === false) return resolve(identity)
          onOffline = () => resolve(identity)
          timer = setTimeout(onOffline, OFFLINE_OPEN_AFTER_MS)
          window.addEventListener('offline', onOffline, { once: true })
        }),
    )
    return { fallback, cancel }
  }

  /**
   * Called once from main.ts before the app mounts, then kept current by
   * Supabase's auth listener (token refresh, sign-out in another tab).
   *
   * `onSession` runs the moment a stored session is known, before the
   * profile round trip — main.ts uses it to start downloading the page the
   * rep is opening while we wait on the database.
   */
  async function init(opts: { onSession?: () => void } = {}) {
    // Read without the network, up front: who was signed in here, and
    // whether this phone could open for them with no signal.
    const stored = storedSession()
    const savedIdentity = stored
      ? readOfflineIdentity<Profile>(stored.user.id)
      : Promise.resolve(null)
    if (stored) {
      readPersistedCache(stored.user.id)
      opts.onSession?.()
    }

    const auth = supabase.auth.getSession()
    const authFallback = offlineFallback(savedIdentity)
    const first = await Promise.race([
      auth.then((result) => ({ result })),
      authFallback.fallback.then((identity) => ({ identity })),
    ])
    authFallback.cancel()

    if ('identity' in first) {
      // The sign-in check is still trying. Open on the saved copy; when the
      // check does finish, it either brings us online or ends the session.
      await openOffline(first.identity, stored!)
      void auth.then(({ data }) => {
        if (data.session) void goOnline(data.session)
        else if (sessionWasRejected()) void endRejected()
      })
    } else {
      const { data, error } = first.result
      session.value = data.session
      if (session.value) {
        if (!stored) {
          readPersistedCache(session.value.user.id)
          opts.onSession?.()
        }
        let failure: unknown = null
        // Side by side, not one after the other: acting_context needs only
        // the JWT, not the profile, and on a morning open over LTE each of
        // these is a full round trip the rep stares at a skeleton through.
        const loaded = Promise.all([
          loadProfile().catch((e) => {
            // A profile read failure shouldn't wedge the app at a blank
            // screen — the router guard will bounce to /login and the user
            // can retry. Unless it failed for lack of signal and this phone
            // has the rep's saved copy: then open on that (below).
            failure = e
            // …and if that already happened, this late failure changes nothing.
            if (!isOffline.value) profile.value = null
          }),
          // Before ready, not after: the router guard reads isAdmin, and an
          // admin who reloads the page mid-view-as must not be waved through
          // to /admin for the frame it takes this to resolve.
          loadActingContext(),
        ]).then(() => true as const)
        // The token is still good but the database isn't answering (no
        // signal; postgrest-js retries the read for ~7 s): same fallback.
        const readsFallback = offlineFallback(savedIdentity)
        const loadedFirst = await Promise.race([loaded, readsFallback.fallback])
        readsFallback.cancel()
        let identity: OfflineIdentity<Profile> | null = null
        if (loadedFirst !== true) identity = loadedFirst
        else if (!profile.value && isNoConnection(failure)) identity = await savedIdentity
        if (identity?.profile.user_id !== session.value.user.id) identity = null

        if (identity) {
          await openOffline(identity, session.value)
          // If the reads were only slow, they finish and bring us back.
          if (loadedFirst !== true) void loaded.then(() => reconnect())
        } else {
          if (loadedFirst !== true) await loaded
          if (profile.value && !profile.value.active) {
            // signIn() refuses a deactivated profile, but a rep deactivated
            // while their refresh token was still good lands here on the
            // next reload and would otherwise be treated as signed in until
            // it expired.
            await signOut()
          } else {
            // Before ready: restored data must be in the cache before the
            // first page decides what to fetch. Bounded by the restore
            // budget.
            await syncSavedCache({ restore: true })
          }
        }
      } else if (isNoConnection(error)) {
        // The token refresh failed for lack of signal. Open on the saved
        // copy if there is one; if not, /login as before — and keep the copy.
        const identity = stored ? await savedIdentity : null
        if (identity) await openOffline(identity, stored!)
      } else if (sessionWasRejected()) {
        // Nobody is signed in on this device (signed out, or the session is
        // gone for good): nothing saved for anyone should outlive that.
        void wipePersistedCache()
      }
    }
    ready.value = true

    supabase.auth.onAuthStateChange((event, next) => {
      const previousUserId = session.value?.user.id
      // supabase-js reports "no session" as INITIAL_SESSION when the refresh
      // merely failed to connect; the session is still in storage. A real
      // rejection removes it and arrives as SIGNED_OUT, handled below.
      if (isOffline.value && event === 'INITIAL_SESSION') return
      if (!next) {
        session.value = null
        profile.value = null
        acting.value = null
        if (isOffline.value) leaveOffline()
        // Signed out in another tab, or the refresh token was revoked. The
        // saved copy goes first, so the clear below can't be saved over it.
        void wipePersistedCache()
        queryClient.clear()
        return
      }
      // Offline and the token just refreshed: we have signal again. Verify
      // before trusting it (goOnline), rather than taking the event's word.
      if (isOffline.value) {
        void goOnline(next)
        return
      }
      session.value = next
      // A different user signed in without a reload — same leak, same fix.
      if (previousUserId && previousUserId !== next.user.id) {
        acting.value = null
        void wipePersistedCache()
        queryClient.clear()
      }
      // TOKEN_REFRESHED fires often; the profile hasn't changed. SIGNED_IN
      // also fires every time the app comes back to the foreground, so the
      // acting context is only re-read for whoever can be acting as someone:
      // admins (and a session that is mid-view-as). A rep's is always "self".
      if (event === 'SIGNED_IN' || event === 'USER_UPDATED') {
        const sameUser = previousUserId === next.user.id
        void Promise.all([
          loadProfile().catch(() => {}),
          !sameUser || isRealAdmin.value || isViewingAs.value
            ? loadActingContext()
            : null,
        ]).then(() => syncSavedCache({ restore: false }))
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
    void syncSavedCache({ restore: false })

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

  /**
   * Change the password of the signed-in user, from inside the app.
   *
   * The current password is re-checked first, even though updateUser() would
   * accept the change without it. A signed-in session on a shared truck iPad
   * is not proof that the person holding it is the account owner, and "type
   * your old password" is the one thing a passer-by cannot do. The check is
   * a real sign-in, so it also refreshes the session it is about to update.
   *
   * Other devices are signed out afterwards, best-effort: the usual reason a
   * rep changes a password deliberately is that they are no longer sure who
   * else has it.
   */
  async function changePassword(currentPassword: string, newPassword: string) {
    const email = user.value?.email
    if (!email) throw new Error('Not signed in.')

    const check = await supabase.auth.signInWithPassword({ email, password: currentPassword })
    if (check.error) {
      if (/rate|too many/i.test(check.error.message)) throw check.error
      throw new Error('That current password is not right.')
    }

    const { error } = await supabase.auth.updateUser({ password: newPassword })
    if (error) throw error

    try {
      await supabase.auth.signOut({ scope: 'others' })
    } catch {
      /* this device is updated either way */
    }
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
    const { error } = await supabase.auth.signOut()
    if (error) {
      // The server-side revoke failed (dead cell, expired token). Drop the
      // persisted session locally anyway — otherwise the button reads as
      // signed out while the next reload restores the rep's session.
      await supabase.auth.signOut({ scope: 'local' })
    }
    session.value = null
    profile.value = null
    acting.value = null
    if (isOffline.value) leaveOffline()
    // Sign-out is an in-tab router.push, not a reload, so the queryClient
    // singleton survives it. Account, recommendation and admin keys are NOT
    // scoped by user id, so without this the next rep to sign in on a shared
    // truck iPad is served the previous rep's cached revenue from cache with
    // no network request at all. This is PRD acceptance criterion #1 failing
    // on the client side of the boundary. The copy saved on the device for
    // the next app open goes the same way, and first (see wipePersistedCache).
    const wiped = wipePersistedCache()
    queryClient.clear()
    await wiped
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
    offlineSince,
    isOffline,
    displayName,
    init,
    loadProfile,
    loadActingContext,
    setViewAs,
    signIn,
    signOut,
    requestPasswordReset,
    updatePassword,
    changePassword,
  }
})
