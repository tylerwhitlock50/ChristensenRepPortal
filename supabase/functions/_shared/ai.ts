/*============================================================================
  _shared/ai.ts — the OpenAI call + hashing helpers the AI Actions layer
  shares. Extracted from ai-account-summary (whose copy is left in place —
  a working function was not refactored just to deduplicate; fold it in the
  next time that file changes for a real reason).

  Everything here embodies the same three non-obvious request rules the
  original documents at length:
    - `max_completion_tokens`, never `max_tokens` (gpt-5 rejects the latter)
    - NO `temperature` (gpt-5 reasoning models 400 on non-default)
    - a large token budget, because reasoning tokens are spent before the
      visible reply and an exact-sized budget returns empty + 'length'.
============================================================================*/

import { HttpError } from './supabase.ts'

export const MODEL = Deno.env.get('OPENAI_MODEL') ?? 'gpt-5-mini'
export const REASONING_EFFORT =
  Deno.env.get('OPENAI_REASONING_EFFORT') ?? 'minimal'
const MAX_COMPLETION_TOKENS = 2000
const OPENAI_TIMEOUT_MS = 60_000

export function envInt(name: string, fallback: number): number {
  const raw = Deno.env.get(name)
  const parsed = raw ? Number.parseInt(raw, 10) : NaN
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback
}

export function round(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value ?? 0)
  return Number.isFinite(n) ? Math.round(n) : 0
}

export function isoDaysAgo(days: number): string {
  const d = new Date()
  d.setUTCDate(d.getUTCDate() - days)
  return d.toISOString().slice(0, 10)
}

/** Deterministic key order, so unchanged data always hashes the same. */
export function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical)
  if (value && typeof value === 'object') {
    const source = value as Record<string, unknown>
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(source).sort()) out[key] = canonical(source[key])
    return out
  }
  return value
}

export async function sha256Hex(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
}

/** Tolerant query unwrap — a missing slice of context never fails a brief. */
// deno-lint-ignore no-explicit-any
export function rows(result: { data: any; error: any }, label: string): any[] {
  if (result.error) {
    console.error(`context query failed: ${label}`, result.error)
    return []
  }
  return result.data ?? []
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

/**
 * One chat completion. The system prompt must be the FIRST message and
 * byte-identical across calls of the same action so OpenAI's automatic
 * prefix caching engages (needs ~1024+ tokens; watch cached_tokens in logs).
 */
export async function callOpenAI(
  systemPrompt: string,
  userMessage: string,
): Promise<string> {
  const apiKey = Deno.env.get('OPENAI_API_KEY')
  if (!apiKey) {
    throw new HttpError(500, 'missing_env', 'OPENAI_API_KEY is not set on this function.')
  }

  const body = {
    model: MODEL,
    max_completion_tokens: MAX_COMPLETION_TOKENS,
    reasoning_effort: REASONING_EFFORT,
    messages: [
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userMessage },
    ],
  }

  let res: Response
  try {
    res = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(OPENAI_TIMEOUT_MS),
    })
  } catch (cause) {
    console.error('openai request failed', cause)
    throw new HttpError(
      504,
      'ai_unavailable',
      'The brief service did not respond. Try again in a moment.',
    )
  }

  if (!res.ok) {
    const detail = await res.text()
    console.error('openai returned', res.status, detail)
    throw new HttpError(
      res.status === 429 ? 429 : 502,
      res.status === 429 ? 'ai_rate_limited' : 'ai_error',
      res.status === 429
        ? 'The brief service is busy. Try again in a minute.'
        : 'The brief service returned an error.',
    )
  }

  const payload = (await res.json()) as OpenAIResponse
  const choice = payload.choices?.[0]

  // Refusal before content: on a refusal `content` is null.
  if (choice?.message?.refusal) {
    console.warn('openai refused', choice.message.refusal)
    throw new HttpError(502, 'ai_refused', 'The brief service declined to answer.')
  }

  const text = (choice?.message?.content ?? '').trim()
  if (!text) {
    if (choice?.finish_reason === 'length') {
      console.error('openai hit the token ceiling before replying', payload.usage)
      throw new HttpError(
        502,
        'ai_truncated',
        'The brief service ran out of tokens before answering. Raise ' +
          'MAX_COMPLETION_TOKENS or lower OPENAI_REASONING_EFFORT.',
      )
    }
    throw new HttpError(502, 'ai_empty', 'The brief service returned nothing.')
  }

  console.log('openai usage', {
    model: MODEL,
    finish_reason: choice?.finish_reason,
    input: payload.usage?.prompt_tokens,
    output: payload.usage?.completion_tokens,
    reasoning: payload.usage?.completion_tokens_details?.reasoning_tokens,
    cache_read: payload.usage?.prompt_tokens_details?.cached_tokens,
  })

  return text
}
