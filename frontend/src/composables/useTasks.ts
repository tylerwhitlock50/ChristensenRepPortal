import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'
import type { Tables } from '@/types/database.types'

export type Task = Tables<'tasks'>

/**
 * Local key registry. These belong in `qk` (src/lib/queryClient.ts) eventually,
 * but that file is owned elsewhere, so tasks keep their keys here. They are
 * namespaced under 'tasks' so `taskKeys.root()` invalidates every task query in
 * one call, and scoped by user id so a sign-out/sign-in as someone else can't
 * read the previous user's cached list.
 */
export const taskKeys = {
  root: () => ['tasks'] as const,
  mine: (userId: string) => ['tasks', 'mine', userId] as const,
  forAccount: (userId: string, customerKey: string) =>
    ['tasks', 'account', userId, customerKey] as const,
} as const

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
    queryKey: computed(() => taskKeys.mine(userId.value)),
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

/** My open follow-ups for one account — the strip on the account page. */
export function useAccountTasks(customerKey: MaybeRef<string>) {
  const session = useSessionStore()
  const userId = computed(() => session.user?.id ?? '')
  const key = computed(() => unref(customerKey))

  return useQuery({
    queryKey: computed(() => taskKeys.forAccount(userId.value, key.value)),
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
  // One call covers ['tasks','mine',…] and ['tasks','account',…]; the lists are
  // small and a rep can have a task page and an account page mounted at once.
  return () => void qc.invalidateQueries({ queryKey: taskKeys.root() })
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
