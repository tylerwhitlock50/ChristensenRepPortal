import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { FunctionsHttpError } from '@supabase/supabase-js'
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
      void qc.invalidateQueries({ queryKey: qk.admin.activity() })
      void qc.invalidateQueries({ queryKey: qk.admin.execution() })
    },
  })
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
