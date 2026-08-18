/*============================================================================
  admin-create-user

  Justification for existing (TECH_STACK §3.2): creating an auth user and
  setting their password requires service_role, and the PRD forbids
  self-signup — users are created and credentialed by the admin only.

  Order of operations matters more here than anywhere else in the codebase:

    1. CORS preflight.
    2. Build a client with THE CALLER'S OWN JWT.
    3. Ask Postgres, as that user, whether they are an admin — is_admin()
       reads public.profiles under RLS.
    4. Only then touch service_role.

  A service_role function without a caller check is a full account-takeover
  hole: anyone who can reach the URL could mint themselves an admin profile
  with any sales_rep_key they like and read every dealer's revenue. The
  service client is therefore constructed AFTER the admin check, not at module
  scope, so there is no window in which it exists un-gated.

  Placeholder rep codes (migration 010): '(Unknown)', 'WEB' and 'HOUSE' are
  real rep IDs in this ERP — 'WEB' alone owns 52 live customers. Stamping one
  on a profile would silently hand that user the placeholder's entire book, so
  it is rejected with a clear 400 rather than a silent success.
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
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'

const MIN_PASSWORD_LENGTH = 12
const ROLES = ['admin', 'rep', 'order_entry'] as const
type Role = (typeof ROLES)[number]

type RequestBody = {
  email?: string
  password?: string
  full_name?: string
  role?: string
  sales_rep_key?: string | null
  rep_group_vendor_id?: string | null
  active?: boolean
}

/** '' and '   ' are not values; they are a form that was left blank. */
function nullIfBlank(value: string | null | undefined): string | null {
  const trimmed = (value ?? '').trim()
  return trimmed.length > 0 ? trimmed : null
}

function isEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)
}

/**
 * Reads the placeholder list from the database rather than hard-coding it, so
 * emptying `placeholder_rep_keys()` (the documented way to revert the 010
 * guard) also relaxes this check. Two copies of that list would drift, and a
 * drift here is a silent access bug.
 */
async function placeholderRepKeys(client: SupabaseClient): Promise<string[]> {
  const { data, error } = await client.rpc('placeholder_rep_keys')
  if (error) {
    console.error('placeholder_rep_keys failed', error)
    // Fail closed on the codes we know are dangerous rather than allowing
    // anything through because an RPC hiccuped.
    return ['(Unknown)', 'WEB', 'HOUSE']
  }
  return (data ?? []) as string[]
}

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
    throw new HttpError(403, 'not_admin', 'Only an admin can create users.')
  }

  /*--------------------------------------------------------------------
    Step 2 — validate the payload before anything is created.
  --------------------------------------------------------------------*/
  const body = await readJson<RequestBody>(req)

  const email = (body.email ?? '').trim().toLowerCase()
  if (!email || !isEmail(email)) {
    throw new HttpError(400, 'invalid_email', 'A valid email address is required.')
  }

  const password = body.password ?? ''
  if (password.length < MIN_PASSWORD_LENGTH) {
    throw new HttpError(
      400,
      'weak_password',
      `Password must be at least ${MIN_PASSWORD_LENGTH} characters.`,
    )
  }

  const fullName = nullIfBlank(body.full_name)
  if (!fullName) {
    throw new HttpError(400, 'missing_full_name', 'Full name is required.')
  }

  const role = (body.role ?? 'rep') as Role
  if (!ROLES.includes(role)) {
    throw new HttpError(
      400,
      'invalid_role',
      "Role must be 'admin', 'rep', or 'order_entry'.",
    )
  }

  // order_entry owns no book (constraint order_entry_empty_book): scope
  // fields are forced null rather than trusted from the form.
  const salesRepKey = role === 'order_entry' ? null : nullIfBlank(body.sales_rep_key)
  const repGroupVendorId =
    role === 'order_entry' ? null : nullIfBlank(body.rep_group_vendor_id)
  const active = body.active ?? true

  // Placeholder guard — the whole reason this validation block exists.
  if (salesRepKey) {
    const placeholders = await placeholderRepKeys(asCaller)
    const hit = placeholders.find(
      (p) => p.toLowerCase() === salesRepKey.toLowerCase(),
    )
    if (hit) {
      throw new HttpError(
        400,
        'placeholder_rep_key',
        `'${hit}' is a placeholder rep code, not a person. Stamping it on a ` +
          'profile would grant that placeholder\'s entire book. Use the real ' +
          'rep code, or add explicit account_assignments grant rows instead.',
      )
    }
  }

  /*--------------------------------------------------------------------
    Step 3 — now, and only now, service_role.
  --------------------------------------------------------------------*/
  const admin = serviceClient()
  const warnings: string[] = []

  if (
    role === 'order_entry' &&
    (nullIfBlank(body.sales_rep_key) || nullIfBlank(body.rep_group_vendor_id))
  ) {
    warnings.push(
      'order_entry users have no account book — the rep code / rep group ' +
        'fields were ignored.',
    )
  }

  // Soft check: a typo'd rep code is valid SQL and grants nothing at all,
  // which looks identical to "the ETL hasn't run yet". Warn, don't block.
  if (salesRepKey) {
    // deno-lint-ignore no-explicit-any
    const repLookup = await (admin as any)
      .schema('erp')
      .from('dim_sales_rep')
      .select('sales_rep_key')
      .eq('sales_rep_key', salesRepKey)
      .maybeSingle()
    if (!repLookup.error && !repLookup.data) {
      warnings.push(
        `sales_rep_key '${salesRepKey}' does not exist in erp.dim_sales_rep. ` +
          'This user will see no accounts until it matches a real rep code.',
      )
    }
  }
  if (repGroupVendorId) {
    // deno-lint-ignore no-explicit-any
    const vendorLookup = await (admin as any)
      .schema('erp')
      .from('dim_sales_rep')
      .select('sales_rep_key')
      .eq('vendor_id', repGroupVendorId)
      .limit(1)
    if (!vendorLookup.error && (vendorLookup.data ?? []).length === 0) {
      warnings.push(
        `rep_group_vendor_id '${repGroupVendorId}' matches no reps in ` +
          'erp.dim_sales_rep. The group-book branch will return nothing.',
      )
    }
  }

  const created = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true, // admin-set credentials; there is no confirmation flow
    user_metadata: { full_name: fullName },
  })

  if (created.error || !created.data?.user) {
    const message = created.error?.message ?? 'Unknown error'
    const alreadyExists = /already (been )?registered|already exists/i.test(message)
    console.error('createUser failed', created.error)
    throw new HttpError(
      alreadyExists ? 409 : 400,
      alreadyExists ? 'email_taken' : 'create_user_failed',
      alreadyExists ? 'That email already has an account.' : message,
    )
  }

  const userId = created.data.user.id

  /*--------------------------------------------------------------------
    Step 4 — fill in the profile the auth trigger already created
    (handle_new_user, migration 003). Update, not insert.
  --------------------------------------------------------------------*/
  const profile = await admin
    .from('profiles')
    .update({
      full_name: fullName,
      role,
      sales_rep_key: salesRepKey,
      rep_group_vendor_id: repGroupVendorId,
      active,
    })
    .eq('user_id', userId)
    .select('user_id, full_name, role, sales_rep_key, rep_group_vendor_id, active')
    .single()

  if (profile.error) {
    // Don't leave a half-created user behind: an auth account with a default
    // 'rep' profile and no rep key is invisible in the admin UI but can still
    // sign in. Roll it back and report honestly.
    console.error('profile update failed, rolling back auth user', profile.error)
    const cleanup = await admin.auth.admin.deleteUser(userId)
    if (cleanup.error) {
      console.error('rollback failed — orphaned auth user', userId, cleanup.error)
      throw new HttpError(
        500,
        'profile_update_failed_orphan',
        `The auth user was created but its profile could not be set, and the ` +
          `rollback failed. Delete user ${userId} manually in the dashboard.`,
      )
    }
    throw new HttpError(
      500,
      'profile_update_failed',
      'Could not set up the profile. No user was created.',
    )
  }

  console.log('user created', { by: caller.id, user_id: userId, role })

  return json({ user_id: userId, email, profile: profile.data, warnings }, 201)
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
    console.error('admin-create-user unhandled error', err)
    return fail(500, 'internal_error', 'Could not create the user.')
  }
})
