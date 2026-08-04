import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'
import type { Tables } from '@/types/database.types'

export type Task = Tables<'tasks'>

/** 'YYYY-MM-DD' in the rep's own timezone — due_date is a bare date, not an instant. */
function today(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/** Open first, then soonest due; tasks with no due date sink to the bottom. */
const OPEN_TASK_ORDER = { ascending: true, nullsFirst: false } as const

/**
 * My open follow-ups.
 *
 * The `user_id` filter is NOT the security boundary — the "own tasks" policy
 * already is. It's here because that policy also grants admins every rep's
 * tasks, and an admin's personal to-do list should be their own.
 */
export function useMyTasks() {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')

  return useQuery({
    queryKey: computed(() => qk.tasks.mine(userId.value)),
    enabled: computed(() => !!userId.value),
    queryFn: async (): Promise<Task[]> => {
      const { data, error } = await supabase
        .from('tasks')
        .select('*')
        .eq('user_id', userId.value)
        .eq('status', 'open')
        .order('due_date', OPEN_TASK_ORDER)
        .order('created_at', { ascending: true })
        .limit(200)
      if (error) throw error
      return data ?? []
    },
    staleTime: 30_000,
  })
}

/**
 * How many of my follow-ups are due — the nav badge.
 *
 * One round trip returning two ids-and-dates, not two `head: true` counts: the
 * payload is a few hundred bytes and the second request would cost more on LTE
 * than the rows it saves.
 *
 * No admin gate, unlike the mission badge in AppShell. That one is gated
 * because `recommendations` is ACCOUNT-scoped, so an admin's unscoped select is
 * the whole company. `tasks` is USER-scoped — the "own tasks" policy is
 * `user_id = auth.uid() or is_admin()` and the filter below is always sent — so
 * an admin's result is their own list exactly like a rep's, and gating it off
 * would hide their own overdue follow-ups.
 *
 * `enabled` is what makes that true. Without a user id the filter is empty, and
 * for an admin an empty filter IS the company-wide select.
 */
export function useMyDueTasks() {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')

  return useQuery({
    queryKey: computed(() => qk.tasks.due(userId.value)),
    enabled: computed(() => !!userId.value),
    staleTime: 60_000,
    queryFn: async (): Promise<{ due: number; overdue: number }> => {
      const now = today()
      const { data, error } = await supabase
        .from('tasks')
        .select('id, due_date')
        .eq('user_id', userId.value)
        .eq('status', 'open')
        .lte('due_date', now)
        .limit(200)
      if (error) throw error
      const rows = data ?? []
      return {
        due: rows.length,
        overdue: rows.filter((r) => (r.due_date ?? '') < now).length,
      }
    },
  })
}

/**
 * Finished and dropped follow-ups. Until this existed, checking a box made a
 * task permanently unreachable — `completed_at` was written and never read.
 *
 * The ordering is the whole subtlety. `useCancelTask` deliberately leaves
 * `completed_at` NULL ("dropped, not done"), so every cancelled row has a null
 * sort key; without the `created_at` fallback they land in arbitrary order.
 * For the same reason the UI must label those rows from `created_at` — a
 * cancelled task has no completion date to show.
 */
export function useClosedTasks(enabled: MaybeRef<boolean> = true) {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')

  return useQuery({
    queryKey: computed(() => qk.tasks.closed(userId.value)),
    enabled: computed(() => !!userId.value && unref(enabled)),
    queryFn: async (): Promise<Task[]> => {
      const { data, error } = await supabase
        .from('tasks')
        .select('*')
        .eq('user_id', userId.value)
        .in('status', ['done', 'cancelled'])
        .order('completed_at', { ascending: false, nullsFirst: false })
        .order('created_at', { ascending: false })
        .limit(50)
      if (error) throw error
      return data ?? []
    },
  })
}

/** My open follow-ups for one account — the strip on the account page. */
export function useAccountTasks(customerKey: MaybeRef<string>) {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')
  const key = computed(() => unref(customerKey))

  return useQuery({
    queryKey: computed(() => qk.tasks.forAccount(userId.value, key.value)),
    enabled: computed(() => !!userId.value && !!key.value),
    queryFn: async (): Promise<Task[]> => {
      const { data, error } = await supabase
        .from('tasks')
        .select('*')
        .eq('user_id', userId.value)
        .eq('customer_key', key.value)
        .eq('status', 'open')
        .order('due_date', OPEN_TASK_ORDER)
        .limit(50)
      if (error) throw error
      return data ?? []
    },
  })
}

function useInvalidateTasks() {
  const qc = useQueryClient()
  // One call covers mine / due / closed / account — every key is built under
  // the ['tasks'] root precisely so this stays one line. Keep it that way: the
  // nav badge and the Done list both depend on completing a task from Today
  // refreshing them without anyone wiring it up.
  return () => void qc.invalidateQueries({ queryKey: qk.tasks.root() })
}

/**
 * `user_id` defaults to auth.uid() in the table definition and the policy
 * requires it to equal auth.uid(), so the client never sends it.
 */
export function useCreateTask() {
  const invalidate = useInvalidateTasks()
  return useMutation({
    mutationFn: async (input: {
      title: string
      /** 'YYYY-MM-DD' from an <input type="date">, or nothing. */
      dueDate?: string | null
      customerKey?: string | null
    }) => {
      const title = input.title.trim()
      if (!title) throw new Error('Give the follow-up a name first.')

      const { data, error } = await supabase
        .from('tasks')
        .insert({
          title,
          due_date: input.dueDate || null,
          customer_key: input.customerKey || null,
        })
        .select()
        .single()
      if (error) throw error
      return data
    },
    onSuccess: () => invalidate(),
  })
}

/**
 * Check it off, or put it back. `completed_at` is stamped here rather than by a
 * trigger so un-checking clears it in the same round trip.
 */
export function useToggleTask() {
  const invalidate = useInvalidateTasks()
  return useMutation({
    mutationFn: async (input: { id: number; done: boolean }) => {
      const { data, error } = await supabase
        .from('tasks')
        .update({
          status: input.done ? 'done' : 'open',
          completed_at: input.done ? new Date().toISOString() : null,
        })
        .eq('id', input.id)
        .select()
      if (error) throw error
      if (!data?.length) throw new Error('That follow-up is no longer there.')
      return data[0]
    },
    onSuccess: () => invalidate(),
  })
}

/**
 * Dropped, not done. `completed_at` stays null — nothing was completed, and the
 * execution reporting counts on that distinction.
 */
export function useCancelTask() {
  const invalidate = useInvalidateTasks()
  return useMutation({
    mutationFn: async (input: { id: number }) => {
      const { data, error } = await supabase
        .from('tasks')
        .update({ status: 'cancelled', completed_at: null })
        .eq('id', input.id)
        .select()
      if (error) throw error
      if (!data?.length) throw new Error('That follow-up is no longer there.')
      return data[0]
    },
    onSuccess: () => invalidate(),
  })
}
