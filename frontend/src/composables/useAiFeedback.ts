import { computed, toValue, type MaybeRefOrGetter } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { isMissingDbObject, supabase } from '@/lib/supabase'
import { useSessionStore } from '@/stores/session'

/**
 * "Was this useful?" under an AI brief — public.ai_feedback,
 * migration 20261013140001.
 *
 * One vote per user per brief, in practice: the read finds the caller's
 * newest vote on THIS brief (cast after its generated_at), so a vote on
 * yesterday's brief does not pre-select today's buttons, and voting again
 * on the same brief changes that row instead of adding a second one. The
 * admin read of the table is what this is for — helpful/wrong per surface
 * and prompt version.
 *
 * `unavailable` is true on a database without the table; the thumbs hide
 * themselves then (lib/supabase.ts isMissingDbObject contract).
 */

/** The table postdates the generated database.types.ts. */
const db = supabase as unknown as SupabaseClient

export type FeedbackSurface = 'territory_brief' | 'account_summary'
export type FeedbackVerdict = 'helpful' | 'wrong'

export interface AiFeedbackRow {
  id: number
  verdict: FeedbackVerdict
  note: string | null
  prompt_version: string | null
  created_at: string
}

/**
 * Account-summary votes live under ['account', key] so the account page's
 * root invalidation sweeps them; the territory brief's are per user.
 */
export function aiFeedbackKey(
  surface: FeedbackSurface,
  subjectKey: string,
  userId: string,
  since: string,
) {
  return surface === 'account_summary'
    ? (['account', subjectKey, 'ai-feedback', userId, since] as const)
    : (['ai-feedback', surface, subjectKey, userId, since] as const)
}

const COLUMNS = 'id, verdict, note, prompt_version, created_at'

export function useAiFeedback(opts: {
  surface: FeedbackSurface
  subjectKey: MaybeRefOrGetter<string>
  /** The brief being judged: its generated_at bounds "already voted". */
  generatedAt: MaybeRefOrGetter<string | null | undefined>
  promptVersion: MaybeRefOrGetter<string | null | undefined>
}) {
  const session = useSessionStore()
  const qc = useQueryClient()

  const userId = computed(() => session.user?.id ?? '')
  const subject = computed(() => toValue(opts.subjectKey) ?? '')
  const since = computed(() => toValue(opts.generatedAt) ?? '')
  const key = computed(() => aiFeedbackKey(opts.surface, subject.value, userId.value, since.value))

  const query = useQuery({
    queryKey: key,
    enabled: computed(() => !!userId.value && !!since.value),
    staleTime: 5 * 60_000,
    // A missing table will still be missing in a second.
    retry: (failureCount, error) => !isMissingDbObject(error) && failureCount < 1,
    queryFn: async (): Promise<AiFeedbackRow | null> => {
      const { data, error } = await db
        .from('ai_feedback')
        .select(COLUMNS)
        .eq('user_id', userId.value)
        .eq('surface', opts.surface)
        .eq('subject_key', subject.value)
        .gte('created_at', since.value)
        .order('created_at', { ascending: false })
        .limit(1)
      if (error) throw error
      return ((data ?? [])[0] as AiFeedbackRow | undefined) ?? null
    },
  })

  const vote = useMutation({
    mutationFn: async (verdict: FeedbackVerdict): Promise<AiFeedbackRow> => {
      const current = query.data.value
      const { data, error } = current
        ? await db
            .from('ai_feedback')
            .update({ verdict })
            .eq('id', current.id)
            .select(COLUMNS)
            .single()
        : await db
            .from('ai_feedback')
            .insert({
              surface: opts.surface,
              subject_key: subject.value,
              prompt_version: toValue(opts.promptVersion) ?? null,
              verdict,
            })
            .select(COLUMNS)
            .single()
      if (error) throw error
      return data as AiFeedbackRow
    },
    onSuccess: (row) => qc.setQueryData(key.value, row),
  })

  const addNote = useMutation({
    mutationFn: async (note: string): Promise<AiFeedbackRow> => {
      const current = query.data.value
      if (!current) throw new Error('Vote first, then add a note.')
      const { data, error } = await db
        .from('ai_feedback')
        .update({ note: note.trim().slice(0, 1000) || null })
        .eq('id', current.id)
        .select(COLUMNS)
        .single()
      if (error) throw error
      return data as AiFeedbackRow
    },
    onSuccess: (row) => qc.setQueryData(key.value, row),
  })

  return {
    query,
    current: computed(() => query.data.value ?? null),
    unavailable: computed(
      () =>
        isMissingDbObject(query.error.value) ||
        isMissingDbObject(vote.error.value) ||
        isMissingDbObject(addNote.error.value),
    ),
    vote,
    addNote,
  }
}
