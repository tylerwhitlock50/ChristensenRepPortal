/*============================================================================
  _shared/aiSummary.ts

  The model call, the cost gates, and the generate-or-return-cached decision —
  everything both the interactive path and the nightly batch have to agree on.

  Notes on the request shape, because three of them look like mistakes:

  - `max_completion_tokens`, not `max_tokens`. The gpt-5 family rejects
    `max_tokens` outright; it is not merely deprecated. The budget covers
    REASONING TOKENS AS WELL AS the visible reply and reasoning is spent
    first, which is why it is 2000 for a ~150-word answer. Sizing it to the
    answer returns an empty message with finish_reason 'length'. Unused
    budget is never billed.

  - There is NO `temperature`. gpt-5 reasoning models accept only the default
    and 400 on anything else. Determinism comes from the prompt, minimal
    reasoning effort, and the context-hash cache — which makes a repeated ask
    literally the same bytes rather than merely a similar sample.

  - The system prompt is the FIRST message and is byte-identical across every
    account. OpenAI caches prompt prefixes automatically above ~1024 tokens;
    there is no field to set, but the ordering matters — anything
    account-specific placed before it breaks the shared prefix for every
    other account. Watch usage.prompt_tokens_details.cached_tokens.
============================================================================*/

import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2'
import { HttpError } from './supabase.ts'
import { buildContext, canonical, sha256Hex } from './accountContext.ts'
import { PROMPT_VERSION, SYSTEM_PROMPT } from '../ai-account-summary/prompt.ts'

export const MODEL = Deno.env.get('OPENAI_MODEL') ?? 'gpt-5-mini'
export const REASONING_EFFORT = Deno.env.get('OPENAI_REASONING_EFFORT') ?? 'minimal'

const MAX_COMPLETION_TOKENS = 2000
const OPENAI_TIMEOUT_MS = 60_000

export const INSUFFICIENT_DATA_MESSAGE = 'Not enough activity to summarize'

export function envInt(name: string, fallback: number): number {
  const raw = Deno.env.get(name)
  const parsed = raw ? Number.parseInt(raw, 10) : NaN
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback
}

/** Below this many invoice lines AND with no notes, we never call the API. */
export const MIN_INVOICE_LINES = envInt('AI_SUMMARY_MIN_INVOICE_LINES', 5)

export type SummaryRow = {
  customer_key: string
  content: string
  headline: string | null
  model: string | null
  context_hash: string | null
  prompt_version: string | null
  generated_at: string
  generated_by: string | null
}

type OpenAIResponse = {
  choices?: Array<{
    message?: { content?: string | null; refusal?: string | null }
    finish_reason?: string
  }>
  usage?: {
    prompt_tokens?: number
    completion_tokens?: number
    prompt_tokens_details?: { cached_tokens?: number }
    completion_tokens_details?: { reasoning_tokens?: number }
  }
  error?: { message?: string; type?: string; code?: string }
}

export type Briefing = { headline: string; briefing: string }

/**
 * One call, two outputs.
 *
 * The headline comes back from the SAME call as the briefing, via a strict
 * json_schema, rather than being parsed off a "HEADLINE:" prefix or sliced
 * out of the prose. A prefix convention is a second thing to keep in sync
 * with the prompt and it fails silently the first time the model reformats;
 * truncating the briefing instead produces a sentence that stops mid-thought,
 * which is worse on a card than the deterministic reason string it replaces.
 */
export async function callOpenAI(contextJson: string): Promise<Briefing> {
  const apiKey = Deno.env.get('OPENAI_API_KEY')
  if (!apiKey) {
    throw new HttpError(500, 'missing_env', 'OPENAI_API_KEY is not set on this function.')
  }

  const body = {
    model: MODEL,
    max_completion_tokens: MAX_COMPLETION_TOKENS,
    reasoning_effort: REASONING_EFFORT,
    messages: [
      { role: 'system', content: SYSTEM_PROMPT },
      {
        role: 'user',
        content:
          'Write the account briefing for this dealer.\n\n<account_context>\n' +
          contextJson +
          '\n</account_context>',
      },
    ],
    response_format: {
      type: 'json_schema',
      json_schema: {
        name: 'account_briefing',
        strict: true,
        schema: {
          type: 'object',
          additionalProperties: false,
          required: ['headline', 'briefing'],
          properties: {
            headline: {
              type: 'string',
              description:
                'One sentence, at most 140 characters. The single most ' +
                'important thing the data shows about this account right ' +
                'now, stated as an observation — never an instruction. ' +
                'No markdown.',
            },
            briefing: {
              type: 'string',
              description:
                'The full Sales Brief described in the system prompt: the ' +
                'HEADLINES block, then the three paragraphs.',
            },
          },
        },
      },
    },
  }

  let res: Response
  try {
    res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(OPENAI_TIMEOUT_MS),
    })
  } catch (cause) {
    console.error('openai request failed', cause)
    throw new HttpError(504, 'ai_unavailable',
      'The summary service did not respond. Try again in a moment.')
  }

  if (!res.ok) {
    const detail = await res.text()
    console.error('openai returned', res.status, detail)
    throw new HttpError(
      res.status === 429 ? 429 : 502,
      res.status === 429 ? 'ai_rate_limited' : 'ai_error',
      res.status === 429
        ? 'The summary service is busy. Try again in a minute.'
        : 'The summary service returned an error.')
  }

  const payload = (await res.json()) as OpenAIResponse
  const choice = payload.choices?.[0]

  // Refusal before content: on a refusal `content` is null and the reason
  // lives in its own field.
  if (choice?.message?.refusal) {
    console.warn('openai refused', choice.message.refusal)
    throw new HttpError(502, 'ai_refused',
      'The summary service declined to answer for this account.')
  }

  const text = (choice?.message?.content ?? '').trim()
  if (!text) {
    if (choice?.finish_reason === 'length') {
      console.error('openai hit the token ceiling before replying', payload.usage)
      throw new HttpError(502, 'ai_truncated',
        'The summary service ran out of tokens before answering. Raise ' +
        'MAX_COMPLETION_TOKENS or lower OPENAI_REASONING_EFFORT.')
    }
    throw new HttpError(502, 'ai_empty', 'The summary service returned nothing.')
  }

  console.log('openai usage', {
    model: MODEL,
    finish_reason: choice?.finish_reason,
    input: payload.usage?.prompt_tokens,
    output: payload.usage?.completion_tokens,
    reasoning: payload.usage?.completion_tokens_details?.reasoning_tokens,
    cache_read: payload.usage?.prompt_tokens_details?.cached_tokens,
  })

  let parsed: Partial<Briefing>
  try {
    parsed = JSON.parse(text) as Partial<Briefing>
  } catch {
    // strict json_schema makes this close to impossible, but a summary is
    // still worth more than a 502: fall back to treating the whole reply as
    // the briefing and let the card use the deterministic reason string.
    console.warn('openai returned non-JSON under json_schema; using it as prose')
    return { headline: '', briefing: text }
  }

  const briefing = (parsed.briefing ?? '').trim()
  if (!briefing) {
    throw new HttpError(502, 'ai_empty', 'The summary service returned nothing.')
  }
  return { headline: (parsed.headline ?? '').trim().slice(0, 140), briefing }
}

/**
 * The context hash. PROMPT_VERSION and the model id are folded in, so tuning
 * either re-baselines every account exactly once — which is the only way to
 * get a consistent corpus after a prompt change instead of a mix nobody can
 * tell apart.
 */
export async function contextHashFor(contextJson: string): Promise<string> {
  return await sha256Hex(
    JSON.stringify({ prompt_version: PROMPT_VERSION, model: MODEL, context: contextJson }),
  )
}

export type BuildResult = Awaited<ReturnType<typeof buildContext>>

export type PreparedContext = {
  built: BuildResult
  contextJson: string
  contextHash: string
  /** True when there is too little here to be worth a token. */
  insufficient: boolean
}

/** Everything up to (but not including) the decision to spend money. */
export async function prepareContext(
  client: SupabaseClient,
  customerKey: string,
): Promise<PreparedContext> {
  const built = await buildContext(client, customerKey)
  const contextJson = JSON.stringify(canonical(built.context))
  return {
    built,
    contextJson,
    contextHash: await contextHashFor(contextJson),
    insufficient: built.invoiceLineCount < MIN_INVOICE_LINES && built.noteCount === 0,
  }
}

export { PROMPT_VERSION }
