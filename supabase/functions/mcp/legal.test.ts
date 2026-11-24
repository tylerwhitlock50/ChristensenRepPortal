/*============================================================================
  legal.test.ts — the MCP endpoint reads nothing for someone who has not
  agreed to the portal's Terms of Use and Privacy Policy.

      deno test --allow-env supabase/functions/
============================================================================*/

import {
  isMissingLegalFunction,
  LEGAL_CHECK_FAILED_MESSAGE,
  legalGateFrom,
  legalRequiredMessage,
  readLegalGate,
} from './legal.ts'

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}

const agreed = {
  documents: [
    { doc_key: 'terms', accepted_at: '2026-11-24T10:00:00Z' },
    { doc_key: 'privacy', accepted_at: '2026-11-24T10:00:00Z' },
  ],
  all_accepted: true,
}

/** A stand-in for the caller's supabase client: answers one rpc. */
function fakeDb(answer: { data: unknown; error: { code?: string; message?: string } | null } | Error) {
  const calls: string[] = []
  return {
    calls,
    rpc(fn: string) {
      calls.push(fn)
      return answer instanceof Error ? Promise.reject(answer) : Promise.resolve(answer)
    },
  }
}

Deno.test('open only on an unambiguous yes', () => {
  assert(legalGateFrom(agreed).ok, 'both agreed')
  assert(legalGateFrom({ documents: [], all_accepted: true }).ok, 'nothing published')
  assert(!legalGateFrom(null).ok, 'null')
  assert(!legalGateFrom('true').ok, 'a string')
  assert(!legalGateFrom({ ...agreed, all_accepted: false }).ok, 'all_accepted false')
  assert(!legalGateFrom({ documents: agreed.documents }).ok, 'all_accepted missing')
  assert(
    !legalGateFrom({ documents: [{ doc_key: 'terms', accepted_at: null }], all_accepted: true }).ok,
    'a flag that disagrees with its entries',
  )
  assert(!legalGateFrom({ documents: 'x', all_accepted: true }).ok, 'documents not a list')
})

Deno.test('the refusal tells the person where to go, and that Claude cannot agree', () => {
  const gate = legalGateFrom({ documents: [], all_accepted: false }, 'https://portal.example')
  assert(!gate.ok, 'refused')
  const text = gate.ok ? '' : gate.message
  assert(text.includes('https://portal.example'), 'names the portal')
  assert(/Terms of Use/.test(text) && /Privacy Policy/.test(text), 'names both documents')
  assert(/cannot agree for you/.test(text), 'Claude cannot agree')
  assert(!legalRequiredMessage('').includes('()'), 'no empty parentheses without a URL')
})

Deno.test('a database without the migration has nothing to agree to', async () => {
  assert(
    isMissingLegalFunction({
      code: 'PGRST202',
      message: 'Could not find the function public.legal_status without parameters in the schema cache',
    }),
    'PGRST202 for legal_status',
  )
  assert(isMissingLegalFunction({ code: 'PGRST202' }), 'PGRST202 with no message')
  assert(!isMissingLegalFunction({ code: 'PGRST202', message: 'Could not find the function public.other' }), 'PGRST202 for another function')
  assert(isMissingLegalFunction({ code: '42883', message: 'function public.legal_status() does not exist' }), '42883')
  assert(!isMissingLegalFunction({ code: '42883', message: 'operator does not exist: text = integer' }), 'an operator bug is not missing')
  assert(
    !isMissingLegalFunction({ code: '42883', message: 'function public.legal_current_documents() does not exist' }),
    'a function legal_status() calls is a broken gate, not a missing one',
  )
  assert(!isMissingLegalFunction({ code: '42703', message: 'column a.doc_key does not exist' }), 'a missing column is broken')
  assert(!isMissingLegalFunction({ code: '42P01', message: 'relation "public.legal_acceptances" does not exist' }), 'a missing table is broken')
  assert(!isMissingLegalFunction({ code: '42501', message: 'permission denied' }), 'a refusal is not missing')
  assert(!isMissingLegalFunction(null), 'no error')
  const db = fakeDb({ data: null, error: { code: 'PGRST202', message: 'Could not find the function public.legal_status' } })
  assert((await readLegalGate(db)).ok, 'open when the function is missing')
  assert(db.calls.join() === 'legal_status', 'asks legal_status, as the caller')
})

Deno.test('every other failure fails closed, and never throws', async () => {
  const denied = await readLegalGate(fakeDb({ data: null, error: { code: '42501', message: 'nope' } }))
  assert(!denied.ok && denied.message === LEGAL_CHECK_FAILED_MESSAGE, 'an error refuses')
  const broken = await readLegalGate(fakeDb({ data: null, error: { code: '42703', message: 'column a.doc_key does not exist' } }))
  assert(!broken.ok, 'a broken legal_status() refuses')
  const thrown = await readLegalGate(fakeDb(new Error('network down')))
  assert(!thrown.ok && thrown.message === LEGAL_CHECK_FAILED_MESSAGE, 'a throw refuses')
  const notYet = await readLegalGate(fakeDb({ data: { documents: [{ accepted_at: null }], all_accepted: false }, error: null }))
  assert(!notYet.ok && /agree to the current Terms of Use/.test(notYet.message), 'not agreed refuses with the way forward')
  assert((await readLegalGate(fakeDb({ data: agreed, error: null }))).ok, 'agreed opens')
})
