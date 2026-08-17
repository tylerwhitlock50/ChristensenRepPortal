import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import type { Tables } from '@/types/database.types'
import type { ActionType } from '@/types/domain'

export type Note = Tables<'notes'>
export type Action = Tables<'actions'>
export type Contact = Tables<'contacts'>

/**
 * One row of public.v_account_contacts (032): rep-entered contacts merged
 * with the ERP's active customer contacts. `id` is set — and the row is
 * editable — only when source === 'rep'.
 */
export type AccountContact = {
  contact_key: string
  source: 'rep' | 'erp'
  id: number | null
  customer_key: string
  name: string
  title: string | null
  phone: string | null
  email: string | null
  is_primary: boolean
  notes: string | null
  updated_at: string | null
  /**
   * ERP contact-preference flags (migration 034). `do_not_call` describes the
   * number in THIS row's `phone` column — the landline when there is one,
   * otherwise the mobile — not the contact in general. Always false for
   * rep-entered rows, which carry no ERP instruction.
   */
  do_not_call: boolean
  do_not_email: boolean
}

export function useNotes(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.notes(key.value)),
    enabled: computed(() => !!key.value),
    queryFn: async (): Promise<Note[]> => {
      const { data, error } = await supabase
        .from('notes')
        .select('*')
        .eq('customer_key', key.value)
        .order('created_at', { ascending: false })
        .limit(100)
      if (error) throw error
      return data ?? []
    },
  })
}

export function useAddNote() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { customerKey: string; body: string }) => {
      const { data, error } = await supabase
        .from('notes')
        .insert({ customer_key: input.customerKey, body: input.body.trim() })
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: qk.account.notes(vars.customerKey) })
    },
  })
}

export function useContacts(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.contacts(key.value)),
    enabled: computed(() => !!key.value),
    queryFn: async (): Promise<AccountContact[]> => {
      const { data, error } = await supabase
        .from('v_account_contacts')
        .select('*')
        .eq('customer_key', key.value)
        .order('is_primary', { ascending: false })
        .order('name')
      if (error) throw error
      /**
       * 034 adds do_not_call/do_not_email after database.types.ts was last
       * generated, so the generated Row type is a column short. Default them
       * to the SAFE value: an un-migrated database must not be read as
       * "calling is fine" — it means "we don't know yet", and the badge
       * simply doesn't appear either way.
       */
      return ((data ?? []) as unknown as Record<string, unknown>[]).map((r) => ({
        ...(r as unknown as AccountContact),
        do_not_call: r.do_not_call === true,
        do_not_email: r.do_not_email === true,
      }))
    },
  })
}

/** Visit/call/email history for the account — the "was this worked?" answer. */
export function useAccountActions(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))
  return useQuery({
    queryKey: computed(() => qk.account.activity(key.value)),
    enabled: computed(() => !!key.value),
    queryFn: async (): Promise<Action[]> => {
      const { data, error } = await supabase
        .from('actions')
        .select('*')
        .eq('customer_key', key.value)
        .order('action_date', { ascending: false })
        .limit(50)
      if (error) throw error
      return data ?? []
    },
  })
}

/** Log a contact that isn't tied to a recommendation. */
export function useLogAccountAction() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: {
      customerKey: string
      actionType: ActionType
      note?: string
    }) => {
      const { data, error } = await supabase
        .from('actions')
        .insert({
          customer_key: input.customerKey,
          action_type: input.actionType,
          note: input.note?.trim() || null,
        })
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: (_d, vars) => {
      void qc.invalidateQueries({ queryKey: qk.account.root(vars.customerKey) })
    },
  })
}
