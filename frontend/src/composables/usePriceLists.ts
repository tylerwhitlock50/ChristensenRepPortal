import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'

/**
 * Structured price lists (public.price_lists / price_list_items, migration
 * 20260817000100) — what the order writer sells from and the admin
 * publishes. Every signed-in user reads them; writes are admin-only and
 * enforced by RLS, not by anything here.
 */

/** Tables land after database.types.ts was last generated — same untyped-
 *  handle convention as useAppSettings.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

export interface PriceListRow {
  id: number
  name: string
  customer_type: string | null
  is_special: boolean
  effective_from: string
  effective_to: string | null
  promo_buy_qty: number | null
  promo_get_qty: number | null
  active: boolean
  notes: string | null
  created_by: string | null
  created_at: string
  updated_at: string
}

export interface PriceListItemRow {
  id: number
  price_list_id: number
  part_id: string
  description: string | null
  unit_price: number
}

/** "Buy 10, get 2" — the chip text wherever a promo list is shown. */
export function promoLabel(list: PriceListRow): string | null {
  if (list.promo_buy_qty == null || list.promo_get_qty == null) return null
  return `Buy ${list.promo_buy_qty}, get ${list.promo_get_qty}`
}

async function fetchLists(): Promise<PriceListRow[]> {
  const { data, error } = await db
    .from('price_lists')
    .select('*')
    .order('is_special')
    .order('customer_type', { nullsFirst: false })
    .order('effective_from', { ascending: false })
  if (error) throw error
  return (data ?? []) as PriceListRow[]
}

/** Every list, active or not — the admin management view. */
export function usePriceLists() {
  return useQuery({ queryKey: qk.priceLists.lists(), queryFn: fetchLists })
}

export function usePriceListItems(listId: MaybeRef<number | null>) {
  return useQuery({
    queryKey: computed(() => qk.priceLists.items(unref(listId) ?? 0)),
    enabled: computed(() => unref(listId) != null),
    queryFn: async (): Promise<PriceListItemRow[]> => {
      const { data, error } = await db
        .from('price_list_items')
        .select('*')
        .eq('price_list_id', unref(listId))
        .order('part_id')
      if (error) throw error
      return (data ?? []) as PriceListItemRow[]
    },
  })
}

/**
 * The lists a rep may sell from for one customer type, today — the
 * SQL-owned eligibility rule (effective_price_lists()), never re-derived
 * client-side. submit_order() re-checks the same function server-side.
 */
export function useEffectivePriceLists(customerType: MaybeRef<string | null>) {
  return useQuery({
    queryKey: computed(() => qk.priceLists.effective(unref(customerType) ?? '')),
    enabled: computed(() => unref(customerType) !== undefined),
    queryFn: async (): Promise<PriceListRow[]> => {
      const { data, error } = await db.rpc('effective_price_lists', {
        p_customer_type: unref(customerType),
      })
      if (error) throw error
      return (data ?? []) as PriceListRow[]
    },
  })
}

export interface PriceListInput {
  name: string
  customer_type: string | null
  is_special: boolean
  effective_from: string
  effective_to: string | null
  promo_buy_qty: number | null
  promo_get_qty: number | null
  active: boolean
  notes: string | null
}

export function useCreatePriceList() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: PriceListInput) => {
      const { data, error } = await db
        .from('price_lists')
        .insert(input)
        .select()
        .single()
      if (error) throw error
      return data as PriceListRow
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.priceLists.root() })
    },
  })
}

export function useUpdatePriceList() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { id: number } & Partial<PriceListInput>) => {
      const { id, ...patch } = input
      const { data, error } = await db
        .from('price_lists')
        .update(patch)
        .eq('id', id)
        .select()
        .single()
      if (error) throw error
      return data as PriceListRow
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.priceLists.root() })
    },
  })
}

export function useDeletePriceList() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: number) => {
      const { error } = await db.from('price_lists').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.priceLists.root() })
    },
  })
}

export interface PriceListItemInput {
  part_id: string
  description: string | null
  unit_price: number
}

/**
 * Replace a list's items wholesale — the CSV upload's semantics. Delete
 * then chunked insert (500/row batches keep each request comfortably under
 * PostgREST's payload ceiling). Not atomic across requests: a failure
 * mid-way leaves the list partially loaded and the admin re-uploads —
 * acceptable for an admin tool, and the upload preview makes it obvious.
 */
export function useReplacePriceListItems() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { priceListId: number; items: PriceListItemInput[] }) => {
      const { error: deleteError } = await db
        .from('price_list_items')
        .delete()
        .eq('price_list_id', input.priceListId)
      if (deleteError) throw deleteError

      for (let i = 0; i < input.items.length; i += 500) {
        const chunk = input.items
          .slice(i, i + 500)
          .map((item) => ({ ...item, price_list_id: input.priceListId }))
        const { error } = await db.from('price_list_items').insert(chunk)
        if (error) throw error
      }
      return input.items.length
    },
    onSuccess: (_count, input) => {
      void qc.invalidateQueries({ queryKey: qk.priceLists.items(input.priceListId) })
    },
  })
}
