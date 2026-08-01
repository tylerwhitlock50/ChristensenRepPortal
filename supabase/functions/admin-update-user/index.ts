/*============================================================================
  admin-update-user

  Justification for existing (TECH_STACK §3.2, same as admin-create-user):
  setting another user's password and blocking their sign-in require
  service_role via the Auth admin API — there is no RLS path to either.
  Everything else about a user (full_name, role, rep keys) is a plain
  client-side profiles update under the "admin manages profiles" policy and
  deliberately does NOT go through this function.

  The order of operations mirrors admin-create-user exactly, and for the
  same reason:

    1. CORS preflight.
    2. Build a client with THE CALLER'S OWN JWT.
    3. Ask Postgres, as that user, whether they are an admin.
    4. Only then touch service_role.

  Deactivation is two writes on purpose:
    - profiles.active = false  → sign-in blocked by the SPA and is_admin()/
      my_customer_keys() stop deriving access
    - an auth ban (~100 years) → token refresh and future password sign-ins
      fail at the Auth layer, so a stolen refresh token dies too
  The caller is warned that the CURRENT access token stays valid until it
  expires (about an hour) — RLS keeps honoring it because the profile row
  still exists; the derived branches of my_customer_keys() already check
  `active`, so what remains is explicit grant rows (see 010's closing note).
============================================================================*/

import { fail, json, preflight } from '../_shared/cors.ts'
import {
  HttpError,
  readJson,
  requireCaller,
  requirePost,
  serviceClient,
  userClient,
} from '../_shared/supabase.ts'

const MIN_PASSWORD_LENGTH = 12

/** Effectively permanent; Supabase has no explicit "disable" flag. */
const BAN_FOREVER = '876000h' // ≈ 100 years
const BAN_NONE = 'none'

type RequestBody = {
  user_id?: string
  password?: string
  active?: boolean
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

async function handle(req: Request): Promise<Response> {
  requirePost(req)

  /*--------------------------------------------------------------------
    Step 1 — who is calling, and are they an admin? As the user, always.
  --------------------------------------------------------------------*/
  const asCaller = userClient(req)
  const caller = await requireCaller(asCaller)

  const adminCheck = await asCaller.rpc('is_admin')
  if (adminCheck.error) {
    console.error('is_admin failed', adminCheck.error)
    throw new HttpError(500, 'admin_check_failed', 'Could not verify your role.')
  }
  if (adminCheck.data !== true) {
    throw new HttpError(403, 'not_admin', 'Only an admin can update users.')
  }

  /*--------------------------------------------------------------------
    Step 2 — validate the payload before anything is touched.
  --------------------------------------------------------------------*/
  const body = await readJson<RequestBody>(req)

  const userId = (body.user_id ?? '').trim()
  if (!userId || !UUID_RE.test(userId)) {
    throw new HttpError(400, 'invalid_user_id', 'A valid user_id is required.')
  }

  const wantsPassword = body.password !== undefined
  const wantsActive = body.active !== undefined

  if (!wantsPassword && !wantsActive) {
    throw new HttpError(
      400,
      'nothing_to_do',
      'Provide a password and/or an active flag to update.',
    )
  }

  if (wantsPassword && (body.password ?? '').length < MIN_PASSWORD_LENGTH) {
    throw new HttpError(
      400,
      'weak_password',
      `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`,
    )
  }

  // An admin locking themselves out mid-session is unrecoverable from the
  // UI (their own is_admin() dies with the profile flag). Make it explicit.
  if (body.active === false && userId === caller.id) {
    throw new HttpError(
      400,
      'cannot_deactivate_self',
      'You cannot deactivate your own account.',
    )
  }

  // The target must actually be one of ours — a profile row exists for every
  // real user (auth trigger), so this doubles as a UUID-typo check.
  const target = await asCaller
    .from('profiles')
    .select('user_id, full_name, active')
    .eq('user_id', userId)
    .maybeSingle()
  if (target.error) {
    console.error('target lookup failed', target.error)
    throw new HttpError(500, 'lookup_failed', 'Could not look up that user.')
  }
  if (!target.data) {
    throw new HttpError(404, 'user_not_found', 'No user with that id exists.')
  }

  /*--------------------------------------------------------------------
    Step 3 — now, and only now, service_role.
  --------------------------------------------------------------------*/
  const admin = serviceClient()
  const warnings: string[] = []
  const updated: Record<string, boolean> = {}

  if (wantsPassword) {
    const res = await admin.auth.admin.updateUserById(userId, {
      password: body.password,
    })
    if (res.error) {
      console.error('password update failed', res.error)
      throw new HttpError(400, 'password_update_failed', res.error.message)
    }
    updated.password = true
  }

  if (wantsActive) {
    const activate = body.active === true

    // Auth side first: if the ban write fails we haven't half-deactivated
    // anyone — the profile flag (what the app reads) is untouched.
    const banned = await admin.auth.admin.updateUserById(userId, {
      ban_duration: activate ? BAN_NONE : BAN_FOREVER,
    })
    if (banned.error) {
      console.error('ban update failed', banned.error)
      throw new HttpError(400, 'ban_update_failed', banned.error.message)
    }

    const profile = await admin
      .from('profiles')
      .update({ active: activate })
      .eq('user_id', userId)
      .select('user_id')
      .single()
    if (profile.error) {
      // Roll the ban back so auth and profile can't disagree.
      console.error('profile active update failed, reverting ban', profile.error)
      const revert = await admin.auth.admin.updateUserById(userId, {
        ban_duration: activate ? BAN_FOREVER : BAN_NONE,
      })
      if (revert.error) {
        console.error('ban revert failed — auth and profile disagree', revert.error)
        throw new HttpError(
          500,
          'deactivate_failed_inconsistent',
          `The auth ban was ${activate ? 'lifted' : 'set'} but the profile flag ` +
            'could not be updated, and the revert failed. Fix the profile row ' +
            'manually in the dashboard.',
        )
      }
      throw new HttpError(
        500,
        'active_update_failed',
        'Could not update the active flag. Nothing was changed.',
      )
    }
    updated.active = true

    if (!activate) {
      warnings.push(
        'Their current session token stays valid for up to an hour; refresh ' +
          'and new sign-ins are blocked immediately. Any explicit account ' +
          'grant rows keep working until removed.',
      )
    }
  }

  console.log('user updated', { by: caller.id, user_id: userId, updated })

  return json({ user_id: userId, updated, warnings }, 200)
}

Deno.serve(async (req) => {
  const pre = preflight(req)
  if (pre) return pre

  try {
    return await handle(req)
  } catch (err) {
    if (err instanceof HttpError) {
      return fail(err.status, err.code, err.message)
    }
    console.error('admin-update-user unhandled error', err)
    return fail(500, 'internal_error', 'Could not update the user.')
  }
})
