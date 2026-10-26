import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { FunctionsHttpError, type SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import type { Tables } from '@/types/database.types'
import type { Role } from '@/types/domain'

export type AdminProfile = Tables<'profiles'>

/**
 * User management, admin only. Reads and profile-field writes go straight
 * through RLS ("admin manages profiles"); the two things RLS cannot do —
 * passwords and sign-in bans — go through the admin-* Edge Functions, which
 * re-verify is_admin() server-side before touching service_role.
 */

export function useProfiles() {
  return useQuery({
    queryKey: qk.admin.users(),
    queryFn: async (): Promise<AdminProfile[]> => {
      const { data, error } = await supabase
        .from('profiles')
        .select('*')
        .order('full_name')
      if (error) throw error
      return data ?? []
    },
  })
}

function friendlyProfileError(e: unknown): string {
  const message = (e as Error)?.message ?? ''
  if (message.includes('placeholder_rep_key')) {
    return 'That rep code is a placeholder (WEB/HOUSE) — it would grant the whole placeholder book. Use the real rep code.'
  }
  return message || 'Could not save that.'
}

export function useUpdateProfile() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      userId: string
      fullName?: string
      role?: Role
      salesRepKey?: string | null
      repGroupVendorId?: string | null
    }) => {
      const patch: Partial<AdminProfile> = {}
      if (input.fullName !== undefined) patch.full_name = input.fullName.trim()
      if (input.role !== undefined) patch.role = input.role
      if (input.salesRepKey !== undefined)
        patch.sales_rep_key = input.salesRepKey?.trim() || null
      if (input.repGroupVendorId !== undefined)
        patch.rep_group_vendor_id = input.repGroupVendorId?.trim() || null

      const { data, error } = await supabase
        .from('profiles')
        .update(patch)
        .eq('user_id', input.userId)
        .select()
        .single()
      if (error) throw new Error(friendlyProfileError(error))
      return data
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.admin.users() })
      void qc.invalidateQueries({ queryKey: qk.admin.activity() })
    },
  })
}

/** Pulls the { error: { code, message } } envelope out of a function failure. */
async function functionErrorMessage(error: unknown, fallback: string): Promise<string> {
  if (error instanceof FunctionsHttpError) {
    try {
      const body = (await error.context.json()) as {
        error?: { code?: string; message?: string }
      }
      if (body?.error?.message) return body.error.message
    } catch {
      // Body wasn't JSON — fall through.
    }
  }
  if (error instanceof Error && error.message) return error.message
  return fallback
}

export interface CreateUserInput {
  email: string
  password: string
  fullName: string
  role: Role
  salesRepKey?: string | null
  repGroupVendorId?: string | null
}

export interface CreateUserResult {
  user_id: string
  email: string
  warnings: string[]
}

export function useCreateUser() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: CreateUserInput): Promise<CreateUserResult> => {
      const { data, error } = await supabase.functions.invoke<CreateUserResult>(
        'admin-create-user',
        {
          body: {
            email: input.email,
            password: input.password,
            full_name: input.fullName,
            role: input.role,
            sales_rep_key: input.salesRepKey || null,
            rep_group_vendor_id: input.repGroupVendorId || null,
          },
        },
      )
      if (error) {
        throw new Error(await functionErrorMessage(error, 'Could not create the user.'))
      }
      if (!data) throw new Error('The user service returned nothing.')
      return data
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.admin.users() })
      void qc.invalidateQueries({ queryKey: qk.admin.unmappedReps() })
      void qc.invalidateQueries({ queryKey: qk.admin.activity() })
      void qc.invalidateQueries({ queryKey: qk.admin.execution() })
    },
  })
}

/* ---- reps who have no account yet ---------------------------------------- */

/** One row from public.admin_unmapped_reps() (20261013170000). */
export interface UnmappedRep {
  sales_rep_key: string
  sales_rep_name: string | null
  /** Lower-cased and trimmed by the function; null when the ERP has none. */
  sales_rep_email: string | null
  vendor_id: string | null
  sales_rep_type: string | null
  customer_count: number
  /** WEB / HOUSE / the ETL's own flags — not a person, never gets an account. */
  is_placeholder: boolean
  /** Set when a profile already carries this email: creating would 409. */
  email_profile_user_id: string | null
  email_profile_name: string | null
}

/** 20261013170000 lands after database.types.ts was last generated — same
 *  untyped-handle convention as useViewAs.ts; delete after regenerating. */
const db = supabase as unknown as SupabaseClient

/**
 * ERP reps whose sales_rep_key is on no profile, with the email the ERP has
 * for them. The function returns nothing to a non-admin, so a wrong caller
 * sees an empty list, not an error.
 */
export function useUnmappedReps() {
  return useQuery({
    queryKey: qk.admin.unmappedReps(),
    staleTime: 60_000,
    queryFn: async (): Promise<UnmappedRep[]> => {
      const { data, error } = await db.rpc('admin_unmapped_reps')
      if (error) throw error
      return ((data ?? []) as UnmappedRep[]).map((r) => ({
        ...r,
        customer_count: Number(r.customer_count ?? 0),
      }))
    },
  })
}

/* ---- password generation ------------------------------------------------- */

/**
 * No 0/O, 1/l/I: the admin reads this out or pastes it into an email, and
 * the rep types it from a phone screen. 57 symbols × 16 places is ~93 bits,
 * well past anything a password policy asks for.
 */
const PASSWORD_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
export const GENERATED_PASSWORD_LENGTH = 16

/** A random temporary password, from the browser's CSPRNG. */
export function generatePassword(length = GENERATED_PASSWORD_LENGTH): string {
  const n = PASSWORD_ALPHABET.length
  // Rejection sampling so every symbol is equally likely: a plain `byte % n`
  // would favour the first (256 mod n) symbols.
  const limit = 256 - (256 % n)
  const out: string[] = []
  const bytes = new Uint8Array(length * 2)
  while (out.length < length) {
    crypto.getRandomValues(bytes)
    for (const b of bytes) {
      if (b < limit) out.push(PASSWORD_ALPHABET[b % n]!)
      if (out.length === length) break
    }
  }
  return out.join('')
}

export interface AdminUpdateUserResult {
  user_id: string
  updated: { password?: boolean; active?: boolean }
  warnings: string[]
}

/** Password set / deactivate / reactivate — the service_role paths. */
export function useAdminUpdateUser() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      userId: string
      password?: string
      active?: boolean
    }): Promise<AdminUpdateUserResult> => {
      const { data, error } = await supabase.functions.invoke<AdminUpdateUserResult>(
        'admin-update-user',
        {
          body: {
            user_id: input.userId,
            ...(input.password !== undefined ? { password: input.password } : {}),
            ...(input.active !== undefined ? { active: input.active } : {}),
          },
        },
      )
      if (error) {
        throw new Error(await functionErrorMessage(error, 'Could not update the user.'))
      }
      if (!data) throw new Error('The user service returned nothing.')
      return data
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.admin.users() })
      void qc.invalidateQueries({ queryKey: qk.admin.activity() })
    },
  })
}
