import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { FunctionsHttpError } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { daysAgo, shortDate } from '@/lib/format'
import type { Tables } from '@/types/database.types'

/**
 * The AI account summary, client side (TECH_STACK §5.1).
 *
 * Two halves, deliberately separate:
 *
 *   useAiSummary()          reads the cached public.ai_summaries row straight
 *                           through PostgREST. Instant, free, and it works
 *                           offline-ish on a bad connection because it is just
 *                           another RLS-scoped select.
 *   useGenerateAiSummary()  invokes the Edge Function to (re)generate. The
 *                           function itself decides whether that costs a token
 *                           — an unchanged account returns the cached row.
 *
 * The rep always sees the cached copy first with "as of <when>", and the
 * regenerate button is an explicit choice rather than something that fires on
 * mount.
 */

export type AiSummary = Tables<'ai_summaries'>

export const AI_SUMMARY_STATUSES = [
  'generated',
  'cached',
  'cooldown',
  'insufficient_data',
] as const
export type AiSummaryStatus = (typeof AI_SUMMARY_STATUSES)[number]

/** What the Edge Function returns on success. */
export type AiSummaryResult = {
  status: AiSummaryStatus
  summary: AiSummary | null
  /** Present on `insufficient_data`: "Not enough activity to summarize". */
  message?: string
  reason?: string
  /** Present on `cooldown`. */
  retry_after_seconds?: number
  /** False when the summary was generated but could not be written back. */
  cached?: boolean
}

/**
 * Query key. `qk` lives in src/lib/queryClient.ts, which this agent does not
 * own, so the key is defined here instead. It keeps the flat `['account',
 * key, …]` convention on purpose: `qk.account.root(customerKey)` is a prefix
 * of it, so every existing `invalidateQueries({ queryKey: qk.account.root(k) })`
 * already sweeps the summary too.
 *
 * Move it into `qk.account.aiSummary` whenever queryClient.ts is next edited.
 */
export const aiSummaryKey = (customerKey: string) =>
  ['account', customerKey, 'ai-summary'] as const

/**
 * "as of <timestamp>" for the card footer. Persona #1 reads "as of yesterday"
 * faster than a date, and the date is more useful once it is older than that.
 */
export function asOfLabel(generatedAt: string | null | undefined): string {
  if (!generatedAt) return ''
  const ago = daysAgo(generatedAt)
  if (ago === 'today' || ago === 'yesterday') return `as of ${ago}`
  return `as of ${shortDate(generatedAt)}`
}

/**
 * Edge Function errors arrive as `{ error: { code, message } }` in the
 * response body, which supabase-js wraps in a FunctionsHttpError rather than
 * surfacing. Unwrap it so the rep sees "That account is not in your book"
 * instead of "Edge Function returned a non-2xx status code".
 */
async function functionErrorMessage(error: unknown): Promise<string> {
  if (error instanceof FunctionsHttpError) {
    try {
      const body = (await error.context.json()) as {
        error?: { code?: string; message?: string }
      }
      if (body?.error?.message) return body.error.message
    } catch {
      // Body wasn't JSON — fall through to the generic message.
    }
  }
  if (error instanceof Error && error.message) return error.message
  return 'Could not build the summary. Try again.'
}

/**
 * The cached row. RLS scopes this to the rep's book, so no owner filter is
 * needed or wanted — an account outside the book returns nothing.
 */
export function useAiSummary(customerKey: MaybeRef<string>) {
  const key = computed(() => unref(customerKey))

  const query = useQuery({
    queryKey: computed(() => aiSummaryKey(key.value)),
    enabled: computed(() => !!key.value),
    queryFn: async (): Promise<AiSummary | null> => {
      const { data, error } = await supabase
        .from('ai_summaries')
        .select('*')
        .eq('customer_key', key.value)
        .maybeSingle()
      if (error) throw error
      return data
    },
    // Summaries only change when someone presses the button, and that path
    // writes the cache directly.
    staleTime: 5 * 60_000,
  })

  const summary = computed(() => query.data.value ?? null)
  const asOf = computed(() => asOfLabel(summary.value?.generated_at))
  const hasSummary = computed(() => !!summary.value?.content)

  return { ...query, summary, asOf, hasSummary }
}

/**
 * Regenerate. Everything expensive — access check, context build, hash
 * comparison, daily cap — happens inside the function; this is a thin call.
 */
export function useGenerateAiSummary() {
  const qc = useQueryClient()

  return useMutation({
    mutationFn: async (customerKey: string): Promise<AiSummaryResult> => {
      const { data, error } = await supabase.functions.invoke<AiSummaryResult>(
        'ai-account-summary',
        { body: { customer_key: customerKey } },
      )
      if (error) throw new Error(await functionErrorMessage(error))
      if (!data) throw new Error('The summary service returned nothing.')
      return data
    },
    onSuccess: (result, customerKey) => {
      // The function hands back the exact row the query reads, so seed the
      // cache instead of round-tripping PostgREST again on LTE.
      qc.setQueryData(aiSummaryKey(customerKey), result.summary ?? null)
    },
  })
}
