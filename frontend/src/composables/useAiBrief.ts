import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { FunctionsHttpError } from '@supabase/supabase-js'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'

/**
 * AI Actions, client side — the "analyst on every screen".
 *
 * An AI Action is a DETERMINISTIC, server-whitelisted brief over the data
 * the user is currently viewing ('territory.brief' today; 'territory.revenue',
 * 'intel.backlog', … later). No free-form prompts leave the client; adding an
 * action is a registry entry in the ai-brief Edge Function plus a button here.
 *
 * Same two-half shape as useAiSummary.ts, and for the same reasons:
 *   useAiBrief()          reads the cached public.ai_briefs row via PostgREST
 *                         — instant, free, RLS-scoped to the caller.
 *   useGenerateAiBrief()  invokes the ai-brief Edge Function, which decides
 *                         whether the call costs a token (context hash →
 *                         cached, cooldown, daily cap).
 */

/** 028 lands after database.types.ts was last generated — same untyped-handle
 *  convention as useAccountMetrics.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

export interface AiBriefRow {
  user_id: string
  action: string
  subject_key: string
  content: string
  /**
   * Structured headlines (ai_briefs.items, 20261013140001). Absent on a
   * database without the column and on briefs written before it; read it
   * through briefHeadlines(), never directly.
   */
  items?: unknown
  model: string | null
  context_hash: string | null
  prompt_version: string | null
  generated_at: string
}

/** One headline the server tagged with the account it is about. */
export interface BriefHeadline {
  text: string
  /** Checked server-side against the brief's own context; null = no chip. */
  customerKey: string | null
  accountName: string | null
}

export type AiBriefStatus =
  | 'generated'
  | 'cached'
  | 'cooldown'
  | 'insufficient_data'

export interface AiBriefResult {
  status: AiBriefStatus
  brief: AiBriefRow | null
  message?: string
  reason?: string
  retry_after_seconds?: number
  cached?: boolean
}

/**
 * HEADLINES-first rendering. The prompt asks for:
 *
 *   HEADLINES
 *   • Territory up 8%
 *   • …
 *
 *   <analysis paragraphs>
 *
 * Parsing is tolerant: no HEADLINES block means everything is body, and the
 * brief still renders. Exported for unit tests.
 */
export function parseBrief(content: string): {
  headlines: string[]
  body: string
} {
  const lines = content.split(/\r?\n/)
  const start = lines.findIndex((l) => /^\s*headlines\s*:?\s*$/i.test(l))
  if (start === -1) return { headlines: [], body: content.trim() }

  const headlines: string[] = []
  let i = start + 1
  for (; i < lines.length; i++) {
    const line = lines[i].trim()
    if (!line) {
      // Blank line ends the block — unless we haven't collected anything yet
      // (some models put one blank line right after the heading).
      if (headlines.length > 0) break
      continue
    }
    const bullet = line.match(/^[•\-*]\s*(.+)$/)
    if (bullet) headlines.push(bullet[1].trim())
    else break
  }
  const body = [...lines.slice(0, start), ...lines.slice(i)].join('\n').trim()
  return { headlines, body }
}

/**
 * The tagged headlines from `items`, or null when there are none to use —
 * the caller then renders parseBrief()'s prose headlines exactly as before.
 * Defensive on purpose: `items` is JSON from the database, and a shape this
 * build doesn't understand must fall back to prose, not throw on the
 * Overview. Exported for unit tests.
 */
export function briefHeadlines(row: Pick<AiBriefRow, 'items'> | null | undefined): BriefHeadline[] | null {
  const items = row?.items as { headlines?: unknown } | null | undefined
  if (!items || typeof items !== 'object' || !Array.isArray(items.headlines)) return null
  const out: BriefHeadline[] = []
  for (const h of items.headlines as unknown[]) {
    if (!h || typeof h !== 'object') continue
    const { text, customer_key, account_name } = h as Record<string, unknown>
    if (typeof text !== 'string' || !text.trim()) continue
    const key = typeof customer_key === 'string' && customer_key.trim() ? customer_key.trim() : null
    out.push({
      text: text.trim(),
      customerKey: key,
      accountName: key && typeof account_name === 'string' && account_name.trim() ? account_name.trim() : null,
    })
  }
  return out.length ? out : null
}

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
  return 'Could not build the brief. Try again.'
}

/**
 * The cached brief for (me, action, subject). RLS lets admins see everyone's
 * rows, so the user_id filter is correctness (my brief, not the first
 * matching one), not security.
 */
export function useAiBrief(action: string, subjectKey: MaybeRef<string> = '') {
  const session = useSessionStore()
  const subject = computed(() => unref(subjectKey))

  const query = useQuery({
    queryKey: computed(() => qk.aiBrief(action, subject.value)),
    enabled: computed(() => !!session.user?.id),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<AiBriefRow | null> => {
      const { data, error } = await db
        .from('ai_briefs')
        .select('*')
        .eq('user_id', session.user!.id)
        .eq('action', action)
        .eq('subject_key', subject.value)
        .maybeSingle()
      if (error) throw error
      return (data as AiBriefRow | null) ?? null
    },
  })

  const brief = computed(() => query.data.value ?? null)
  return {
    ...query,
    brief,
    parsed: computed(() =>
      brief.value ? parseBrief(brief.value.content) : { headlines: [], body: '' },
    ),
    hasBrief: computed(() => !!brief.value?.content),
  }
}

/** (Re)generate one action's brief. All cost control lives in the function. */
export function useGenerateAiBrief() {
  const qc = useQueryClient()

  return useMutation({
    mutationFn: async (input: {
      action: string
      subject_key?: string
    }): Promise<AiBriefResult> => {
      const { data, error } = await supabase.functions.invoke<AiBriefResult>(
        'ai-brief',
        { body: { action: input.action, subject_key: input.subject_key ?? '' } },
      )
      if (error) throw new Error(await functionErrorMessage(error))
      if (!data) throw new Error('The brief service returned nothing.')
      return data
    },
    onSuccess: (result, input) => {
      // Seed the read cache with the row the function returned — but only
      // when it returned one; 'insufficient_data'/'cooldown' carry no brief
      // and writing null would blank a good cached row (see useAiSummary.ts).
      if (result.brief) {
        qc.setQueryData(
          qk.aiBrief(input.action, input.subject_key ?? ''),
          result.brief,
        )
      }
    },
  })
}
