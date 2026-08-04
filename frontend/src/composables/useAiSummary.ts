import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { FunctionsHttpError } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
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
 * Re-pointed at the canonical registry (the queryClient.ts header asked for
 * this on the next edit). Still a suffix of `qk.account.root(key)`, so every
 * existing account-root invalidation sweeps the summary too.
 */
export const aiSummaryKey = qk.account.aiSummary

/** Headlines for a set of accounts — the Today cards, not an account page. */
export const aiHeadlinesKey = (keys: string[]) => ['me', 'ai-headlines', keys] as const

/**
 * An AI headline is only better than the deterministic `reason` string while
 * it is current. The reason is rebuilt nightly from tonight's facts; a
 * headline from three weeks ago sitting on a card that says "Do this first"
 * is worse than the sentence it replaced.
 */
export const HEADLINE_MAX_AGE_DAYS = 7

export interface AccountHeadline {
  headline: string
  generatedAt: string
}

/**
 * Batch-read the cached headlines for the accounts currently on screen.
 *
 * Same shape as useAccountNames() — one `.in()` over the visible keys rather
 * than a query per card. RLS scopes it, so no owner filter is written here.
 * Degrades to an empty map: a missing headline must never take down the
 * to-do list, and every caller falls back to `rec.reason`.
 */
export function useAiHeadlines(customerKeys: MaybeRef<string[]>) {
  const list = computed(() => [...new Set(unref(customerKeys))].sort())

  return useQuery({
    queryKey: computed(() => aiHeadlinesKey(list.value)),
    enabled: computed(() => list.value.length > 0),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<Record<string, AccountHeadline>> => {
      const { data, error } = await supabase
        .from('ai_summaries')
        .select('customer_key, headline, generated_at')
        .in('customer_key', list.value)
      if (error) throw error

      const cutoff = Date.now() - HEADLINE_MAX_AGE_DAYS * 86_400_000
      const map: Record<string, AccountHeadline> = {}
      for (const row of data ?? []) {
        if (!row.headline) continue
        if (new Date(row.generated_at).getTime() < cutoff) continue
        map[row.customer_key] = {
          headline: row.headline,
          generatedAt: row.generated_at,
        }
      }
      return map
    },
  })
}

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
      //
      // Only when it actually returned one. 'insufficient_data' and 'cooldown'
      // carry no summary, and writing null for those blanks a perfectly good
      // row that is still in Postgres — which the 5-minute staleTime then
      // refuses to refetch.
      if (result.summary) {
        qc.setQueryData(aiSummaryKey(customerKey), result.summary)
      }
    },
  })
}
