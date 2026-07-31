import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import type { Tables } from '@/types/database.types'
import type { ActionType } from '@/types/domain'

export type Note = Tables<'notes'>
export type Action = Tables<'actions'>
export type Contact = Tables<'contacts'>

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
    queryFn: async (): Promise<Contact[]> => {
      const { data, error } = await supabase
        .from('contacts')
        .select('*')
        .eq('customer_key', key.value)
        .order('is_primary', { ascending: false })
        .order('name')
      if (error) throw error
      return data ?? []
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
