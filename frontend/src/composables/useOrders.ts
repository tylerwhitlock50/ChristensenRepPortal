import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { erp, supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'
import type { OrderStatus, QcResult } from '@/types/domain'

/**
 * Portal-written orders (public.orders / order_lines / order_qc_results,
 * migration 20260817000200).
 *
 * The write model mirrors the RLS design exactly: DRAFTS are ordinary table
 * writes (insert/update/delete under the owner's own policies); every other
 * lifecycle move — submit, recall, cancel, mark entered, reopen, resolve,
 * re-check — is a transition RPC that the database gates by role and
 * current status. Nothing here decides who may do what; it only asks.
 */

/** Tables land after database.types.ts was last generated — same untyped-
 *  handle convention as useAppSettings.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

export interface OrderRow {
  id: number
  user_id: string
  customer_key: string
  customer_name: string
  customer_type: string | null
  status: OrderStatus
  po_number: string | null
  requested_ship_date: string | null
  notes: string | null
  total_amount: number | null
  submitted_at: string | null
  entered_at: string | null
  entered_by: string | null
  erp_order_number: string | null
  qc_checked_at: string | null
  verified_at: string | null
  resolution_note: string | null
  created_at: string
  updated_at: string
}

export interface OrderLineRow {
  id: number
  order_id: number
  price_list_id: number
  price_list_item_id: number | null
  part_id: string
  description: string | null
  qty: number
  unit_price: number
  discount_pct: number
  effective_unit_price: number
  line_total: number
}

export interface QcResultRow {
  id: number
  order_id: number
  run_at: string
  result: QcResult
  part_id: string | null
  app_qty: number | null
  erp_qty: number | null
  app_unit_price: number | null
  erp_unit_price: number | null
  detail: string | null
}

export interface OrderDetail {
  order: OrderRow
  lines: OrderLineRow[]
  qc: QcResultRow[]
}

// ---------------------------------------------------------------- reads

/** Everything RLS lets the caller read — their own orders, plus the book's
 *  for a principal. Admin sees all; the views split by status client-side. */
export function useMyOrders() {
  const session = useSessionStore()
  return useQuery({
    queryKey: computed(() => qk.orders.list(session.user?.id ?? '')),
    enabled: computed(() => !!session.user),
    queryFn: async (): Promise<OrderRow[]> => {
      const { data, error } = await db
        .from('orders')
        .select('*')
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? []) as OrderRow[]
    },
  })
}

/** Header + lines + QC findings in one key, so any transition invalidates
 *  the whole detail page at once. */
export function useOrderDetail(orderId: MaybeRef<number>) {
  return useQuery({
    queryKey: computed(() => qk.orders.detail(unref(orderId))),
    queryFn: async (): Promise<OrderDetail | null> => {
      const id = unref(orderId)
      const { data: order, error } = await db
        .from('orders')
        .select('*')
        .eq('id', id)
        .maybeSingle()
      if (error) throw error
      if (!order) return null

      const [linesRes, qcRes] = await Promise.all([
        db.from('order_lines').select('*').eq('order_id', id).order('id'),
        db.from('order_qc_results').select('*').eq('order_id', id).order('id'),
      ])
      if (linesRes.error) throw linesRes.error
      if (qcRes.error) throw qcRes.error

      return {
        order: order as OrderRow,
        lines: (linesRes.data ?? []) as OrderLineRow[],
        qc: (qcRes.data ?? []) as QcResultRow[],
      }
    },
  })
}

/** The entry queue: everything post-draft that isn't closed out, oldest
 *  submission first — the keying order. */
export function useOrderQueue() {
  return useQuery({
    queryKey: qk.orders.queue(),
    queryFn: async (): Promise<OrderRow[]> => {
      const { data, error } = await db
        .from('orders')
        .select('*')
        .in('status', ['submitted', 'entered', 'discrepancy'])
        .order('submitted_at', { ascending: true, nullsFirst: false })
      if (error) throw error
      return (data ?? []) as OrderRow[]
    },
  })
}

/** The chosen account's identity for the writer: name + customer_type
 *  (which decides the effective price lists). Rep-readable via RLS. */
export function useOrderCustomer(customerKey: MaybeRef<string>) {
  return useQuery({
    queryKey: computed(() => ['order-customer', unref(customerKey)] as const),
    enabled: computed(() => !!unref(customerKey)),
    queryFn: async () => {
      const { data, error } = await erp
        .from('dim_customer' as never)
        .select('customer_key, customer_name, customer_type')
        .eq('customer_key', unref(customerKey))
        .maybeSingle()
      if (error) throw error
      return data as unknown as {
        customer_key: string
        customer_name: string | null
        customer_type: string | null
      } | null
    },
  })
}

// ---------------------------------------------------------------- drafts

function invalidateOrders(qc: ReturnType<typeof useQueryClient>) {
  void qc.invalidateQueries({ queryKey: qk.orders.root() })
}

export interface DraftHeaderInput {
  customer_key: string
  po_number: string | null
  requested_ship_date: string | null
  notes: string | null
}

export interface DraftLineInput {
  price_list_id: number
  price_list_item_id: number | null
  part_id: string
  description: string | null
  qty: number
  unit_price: number
  /** Preview value; submit_order() recomputes it authoritatively. */
  effective_unit_price: number
  discount_pct: number
}

/** Create the draft order row. Lines are saved separately (below). */
export function useCreateDraftOrder() {
  const qc = useQueryClient()
  const session = useSessionStore()
  return useMutation({
    mutationFn: async (input: DraftHeaderInput) => {
      const { data, error } = await db
        .from('orders')
        .insert({ ...input, user_id: session.user?.id })
        .select()
        .single()
      if (error) throw error
      return data as OrderRow
    },
    onSuccess: () => invalidateOrders(qc),
  })
}

export function useUpdateDraftOrder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { id: number } & Partial<DraftHeaderInput>) => {
      const { id, ...patch } = input
      const { data, error } = await db
        .from('orders')
        .update(patch)
        .eq('id', id)
        .select()
        .single()
      if (error) throw error
      return data as OrderRow
    },
    onSuccess: () => invalidateOrders(qc),
  })
}

export function useDeleteDraftOrder() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: number) => {
      const { error } = await db.from('orders').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => invalidateOrders(qc),
  })
}

/**
 * Replace a draft's lines wholesale. A draft is small (tens of lines), the
 * RLS only allows this while it IS a draft, and replace semantics mean the
 * saved state always equals the screen — no per-line diffing to get wrong.
 */
export function useSaveDraftLines() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: { orderId: number; lines: DraftLineInput[] }) => {
      const { error: deleteError } = await db
        .from('order_lines')
        .delete()
        .eq('order_id', input.orderId)
      if (deleteError) throw deleteError
      if (input.lines.length > 0) {
        const { error } = await db
          .from('order_lines')
          .insert(input.lines.map((l) => ({ ...l, order_id: input.orderId })))
        if (error) throw error
      }
    },
    onSuccess: () => invalidateOrders(qc),
  })
}

// ------------------------------------------------------------- transitions

/** All six transitions share one shape: call the RPC, get the updated
 *  order back, invalidate every order key. The database enforces role and
 *  status; errors surface with the RPC's own message. */
function useOrderRpc<TInput>(toArgs: (input: TInput) => Record<string, unknown>, fn: string) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: TInput) => {
      const { data, error } = await db.rpc(fn, toArgs(input))
      if (error) throw error
      return data as OrderRow
    },
    onSuccess: () => invalidateOrders(qc),
  })
}

export function useSubmitOrder() {
  return useOrderRpc((id: number) => ({ p_order_id: id }), 'submit_order')
}
export function useRecallOrder() {
  return useOrderRpc((id: number) => ({ p_order_id: id }), 'recall_order')
}
export function useCancelOrder() {
  return useOrderRpc((id: number) => ({ p_order_id: id }), 'cancel_order')
}
export function useMarkOrderEntered() {
  return useOrderRpc(
    (input: { id: number; erpOrderNumber: string }) => ({
      p_order_id: input.id,
      p_erp_order_number: input.erpOrderNumber,
    }),
    'mark_order_entered',
  )
}
export function useReopenEnteredOrder() {
  return useOrderRpc((id: number) => ({ p_order_id: id }), 'reopen_entered_order')
}
export function useResolveDiscrepancy() {
  return useOrderRpc(
    (input: { id: number; note: string | null }) => ({
      p_order_id: input.id,
      p_note: input.note,
    }),
    'resolve_discrepancy',
  )
}

/** "Re-check now" — run the QC for one order without waiting for tonight. */
export function useRunOrderQc() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (orderId: number) => {
      const { error } = await db.rpc('run_order_qc', { p_order_id: orderId })
      if (error) throw error
    },
    onSuccess: () => invalidateOrders(qc),
  })
}
