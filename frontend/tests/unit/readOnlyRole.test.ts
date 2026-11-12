/**
 * Unit tests for the read-only role (inside sales, profiles.role =
 * 'order_entry', 20261113090000): the database refuses their writes outside
 * orders with 'read_only_role: inside sales can view <table> but not change
 * it' (42501), and every screen should say the same plain sentence.
 *
 * Run with:  npm run test:unit -- readOnlyRole
 *
 * What matters: the refusal is recognised however it arrives, the read path
 * (describeError → AsyncState) and the order screens (rpcErrorText) both
 * translate it, and a mutation that fails with it reaches its caller already
 * translated — which is what covers every `catch (e) { … e.message }` in
 * the app without each one knowing about the role.
 */
import { MutationObserver } from '@tanstack/vue-query'
import {
  READ_ONLY_ROLE_MESSAGE,
  READ_ONLY_ROLE_ORIGINAL,
  isReadOnlyRoleError,
  readOnlyRoleOriginal,
} from '../../src/lib/readOnlyRole'
import { describeError } from '../../src/lib/supabase'
import { rpcErrorText } from '../../src/lib/mcpOrders'
import { queryClient } from '../../src/lib/queryClient'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(`FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`)
  }
}

const RAW = 'read_only_role: inside sales can view account_notes but not change it'
/** The shape PostgREST hands back for the trigger's exception. */
const postgrest = () => ({ message: RAW, code: '42501', details: null, hint: null })

// ------------------------------------------------------------ recognising
t('the message is plain words', READ_ONLY_ROLE_MESSAGE, 'Inside sales can view this but not change it.')
t('a PostgREST error object', isReadOnlyRoleError(postgrest()), true)
t('an Error', isReadOnlyRoleError(new Error(RAW)), true)
t('a bare message', isReadOnlyRoleError(RAW), true)
t('wrapped by another function', isReadOnlyRoleError({ message: `could not save: ${RAW}` }), true)
t('another 42501 is not it', isReadOnlyRoleError({ message: 'new row violates row-level security policy', code: '42501' }), false)
t('the view-as refusal is not it', isReadOnlyRoleError({ message: 'read_only_while_viewing_as: writes are disabled', code: '42501' }), false)
t('no error', isReadOnlyRoleError(null), false)
t('no message', isReadOnlyRoleError({ code: '42501' }), false)
// The code with its ': ', not the bare word: the trigger function and the
// triggers are named after it, and an error naming one is not the refusal.
t('the trigger function named in an error is not it',
  isReadOnlyRoleError({ message: 'function block_writes_for_read_only_role() does not exist' }), false)
t('a trigger named in an error is not it',
  isReadOnlyRoleError({ message: 'trigger "trg_account_notes_read_only_role" for relation "account_notes" already exists' }), false)
t('the bare word is not it', isReadOnlyRoleError('read_only_role'), false)
t('the code at the very start is', isReadOnlyRoleError('read_only_role: x'), true)
t('the original of a raw refusal is its message', readOnlyRoleOriginal(postgrest()), RAW)
t('another error has no original', readOnlyRoleOriginal(new Error('Order 5 is not a draft')), null)

// ------------------------------------------------- where text is mapped
t('describeError (every AsyncState)', describeError(postgrest()), READ_ONLY_ROLE_MESSAGE)
t('rpcErrorText (the order screens)', rpcErrorText(RAW), READ_ONLY_ROLE_MESSAGE)
t('describeError leaves other errors alone', describeError({ message: 'Order 5 is not a draft' }), 'Order 5 is not a draft')

// ------------------------------------------------------- every mutation
/** Run a mutation on the app's own client and hand back what its caller would catch. */
async function failWith(error: unknown): Promise<unknown> {
  const observer = new MutationObserver(queryClient, {
    mutationFn: async () => {
      throw error
    },
  })
  try {
    await observer.mutate()
    return null
  } catch (caught) {
    return caught
  }
}

// The rewrite logs the database's own words: the only record of which table refused.
const warned: unknown[][] = []
const warn = console.warn
console.warn = (...args: unknown[]) => {
  warned.push(args)
}
const caught = (await failWith(postgrest())) as { message: string; code: string }
console.warn = warn
t('a refused mutation reaches its caller translated', caught.message, READ_ONLY_ROLE_MESSAGE)
t('…with its code intact', caught.code, '42501')
t('…its original words kept on it', (caught as unknown as Record<string, unknown>)[READ_ONLY_ROLE_ORIGINAL], RAW)
t('…and still recognised as the refusal after the rewrite', isReadOnlyRoleError(caught), true)
t('…which hands back the original', readOnlyRoleOriginal(caught), RAW)
t('…and describeError still words it', describeError(caught), READ_ONLY_ROLE_MESSAGE)
t('the original went to the console', warned.length === 1 && warned[0].includes(RAW), true)

const asError = (await failWith(new Error(RAW))) as Error
t('an Error thrown from a mutationFn too', asError.message, READ_ONLY_ROLE_MESSAGE)
t('…and it is still an Error', asError instanceof Error, true)

const other = (await failWith(new Error('Order 5 is not a draft'))) as Error
t('any other failure keeps its own words', other.message, 'Order 5 is not a draft')

const frozen = (await failWith(Object.freeze(postgrest()))) as { message: string }
t('a frozen error is left as it is, not a crash', frozen.message, RAW)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
