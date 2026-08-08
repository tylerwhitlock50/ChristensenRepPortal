import { computed } from 'vue'
import { useMutation, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'

/**
 * Contact writes. The read lives in `useAccountData.ts` and is re-exported here
 * so a component only has to import from one place — there is exactly one
 * `useContacts` query in the app.
 */
export { useContacts } from '@/composables/useAccountData'
export type { Contact, AccountContact } from '@/composables/useAccountData'

/** What the form collects. Blank strings become NULL on the way to Postgres. */
export type ContactInput = {
  name: string
  title?: string | null
  phone?: string | null
  email?: string | null
  is_primary?: boolean
  notes?: string | null
}

function blankToNull(value: string | null | undefined): string | null {
  const trimmed = value?.trim()
  return trimmed ? trimmed : null
}

function toRow(values: ContactInput) {
  return {
    name: values.name.trim(),
    title: blankToNull(values.title),
    phone: blankToNull(values.phone),
    email: blankToNull(values.email),
    is_primary: values.is_primary ?? false,
    notes: blankToNull(values.notes),
  }
}

function useInvalidateContacts() {
  const qc = useQueryClient()
  return (customerKey: string) => {
    void qc.invalidateQueries({ queryKey: qk.account.contacts(customerKey) })
  }
}

/**
 * The insert policy is `has_account_access(customer_key) and created_by = auth.uid()`,
 * and the column already defaults to `auth.uid()` (004_app_crm.sql). Sending
 * created_by from the client would add nothing but a way to get it wrong, so we
 * let the default apply.
 */
export function useAddContact() {
  const invalidate = useInvalidateContacts()
  return useMutation({
    mutationFn: async (input: { customerKey: string; values: ContactInput }) => {
      const { data, error } = await supabase
        .from('contacts')
        .insert({ customer_key: input.customerKey, ...toRow(input.values) })
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}

export function useUpdateContact() {
  const invalidate = useInvalidateContacts()
  return useMutation({
    mutationFn: async (input: {
      id: number
      customerKey: string
      values: ContactInput
    }) => {
      // No `.single()`: when RLS filters the row out PostgREST reports "0 rows"
      // as a coercion error, which reads like a bug. An empty array is the
      // honest signal, and we turn it into a sentence a rep can act on.
      const { data, error } = await supabase
        .from('contacts')
        .update(toRow(input.values))
        .eq('id', input.id)
        .select()
      if (error) throw error
      if (!data?.length) {
        throw new Error(
          "That contact couldn't be saved. It may have been removed, or it belongs to an account outside your book.",
        )
      }
      return data[0]
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}

/**
 * Reps can't delete — policy "admin deletes contacts" is `is_admin()`
 * (007_rls_policies.sql / 010_access_performance.sql). A rep's DELETE isn't
 * rejected, it simply matches zero rows, so without this check the UI would
 * cheerfully report success and the contact would still be there.
 */
export function useDeleteContact() {
  const invalidate = useInvalidateContacts()
  const session = useSessionStore()
  return useMutation({
    mutationFn: async (input: { id: number; customerKey: string }) => {
      const { data, error } = await supabase
        .from('contacts')
        .delete()
        .eq('id', input.id)
        .select()
      if (error) throw error
      if (!data?.length) {
        throw new Error(
          session.isAdmin
            ? 'That contact is already gone.'
            : 'Only an admin can delete a contact. Edit it instead, or ask sales ops to remove it.',
        )
      }
      return data[0]
    },
    onSuccess: (_data, vars) => invalidate(vars.customerKey),
  })
}

/**
 * Whether to *offer* the delete affordance. This is presentation only — the
 * delete policy is the boundary, and useDeleteContact still handles the case
 * where this is wrong.
 */
export function useCanDeleteContacts() {
  const session = useSessionStore()
  return computed(() => session.isAdmin)
}
