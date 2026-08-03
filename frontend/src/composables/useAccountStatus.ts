import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'
import type { DeactivationReason } from '@/types/domain'

/**
 * The portal-side "stop working this account" state
 * (public.account_deactivations, migration 023). The ERP's active_flag is
 * whatever the ERP says; this is what the REP says, and it is what hides an
 * account from the active list, scoring, and recommendations.
 *
 * Untyped handle for the usual reason (useAccounts.ts): the table postdates
 * the generated database.types.ts.
 */
const db = supabase as unknown as SupabaseClient

export interface AccountDeactivation {
  id: number
  customer_key: string
  reason: DeactivationReason
  note: string | null
  deactivated_by: string
  deactivated_at: string
  reactivated_by: string | null
  reactivated_at: string | null
}

/** The OPEN deactivation period for one account, or null when it's in play. */
export function useAccountDeactivation(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.status(key.value)),
    enabled: computed(() => !!key.value),
    queryFn: async (): Promise<AccountDeactivation | null> => {
      const { data, error } = await db
        .from('account_deactivations')
        .select('*')
        .eq('customer_key', key.value)
        .is('reactivated_at', null)
        .maybeSingle()
      if (error) throw error
      return (data ?? null) as AccountDeactivation | null
    },
  })
}

/**
 * Deactivating dismisses the account's open recommendations and drops it
 * from scoring DB-side (the 023 trigger), so on success everything that
 * shows that work is invalidated too, not just this account's page.
 */
function useInvalidateAccountStatus() {
  const qc = useQueryClient()
  return (customerKey: string) => {
    void qc.invalidateQueries({ queryKey: qk.account.root(customerKey) })
    void qc.invalidateQueries({ queryKey: qk.me.accounts() })
    void qc.invalidateQueries({ queryKey: qk.me.needsAttention() })
  }
}

export function useDeactivateAccount() {
  const invalidate = useInvalidateAccountStatus()
  return useMutation({
    mutationFn: async (input: {
      customerKey: string
      reason: DeactivationReason
      note?: string | null
    }) => {
      // deactivated_by / deactivated_at come from column defaults — sending
      // them from the client would only add a way to get them wrong (the
      // same posture as useAddContact).
      const { data, error } = await db
        .from('account_deactivations')
        .insert({
          customer_key: input.customerKey,
          reason: input.reason,
          note: input.note?.trim() || null,
        })
        .select()
        .single()
      if (error) {
        // The partial unique index: one open period per account.
        if (error.code === '23505') {
          throw new Error('This account is already deactivated.')
        }
        // RLS with check: the account is outside the caller's book.
        if (error.code === '42501') {
          throw new Error(
            "This account isn't in your book, so you can't deactivate it.",
          )
        }
        throw error
      }
      return data as AccountDeactivation
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}

export function useReactivateAccount() {
  const invalidate = useInvalidateAccountStatus()
  const session = useSessionStore()
  return useMutation({
    mutationFn: async (input: { id: number; customerKey: string }) => {
      const userId = session.user?.id
      if (!userId) throw new Error('You are signed out. Sign in and try again.')
      // No `.single()`: when RLS filters the row out PostgREST reports
      // "0 rows" as a coercion error. An empty array is the honest signal
      // (same pattern as useUpdateContact).
      const { data, error } = await db
        .from('account_deactivations')
        .update({
          reactivated_at: new Date().toISOString(),
          reactivated_by: userId,
        })
        .eq('id', input.id)
        .is('reactivated_at', null)
        .select()
      if (error) throw error
      if (!data?.length) {
        throw new Error(
          'This account is already back in play, or it belongs to an account outside your book.',
        )
      }
      return data[0] as AccountDeactivation
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}
