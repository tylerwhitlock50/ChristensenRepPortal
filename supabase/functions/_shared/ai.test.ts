/*============================================================================
  ai.test.ts — which failed model calls still count as paid.

      deno test --allow-env supabase/functions/
============================================================================*/

import { wasBilled } from './ai.ts'
import { HttpError } from './supabase.ts'

function assertEquals(got: unknown, want: unknown, what: string): void {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    throw new Error(`FAILED: ${what}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`)
  }
}

Deno.test('a reply that came back unusable was billed; a call that never answered was not', () => {
  const billed = ['ai_truncated', 'ai_empty', 'ai_refused']
    .map((code) => wasBilled(new HttpError(502, code, 'x')))
  assertEquals(billed, [true, true, true], 'cut off, empty and refused replies are ledgered')
  const notBilled = [
    new HttpError(504, 'ai_unavailable', 'x'),
    new HttpError(502, 'ai_error', 'x'),
    new HttpError(429, 'ai_rate_limited', 'x'),
    new HttpError(429, 'daily_limit_reached', 'x'),
    new Error('ai_truncated'),
    null,
  ].map(wasBilled)
  assertEquals(notBilled, [false, false, false, false, false, false],
    'no answer, an error status, a cap, or a non-HttpError is not')
})
