/*============================================================================
  prompts.test.ts — the MCP prompts render, and refuse what they should.

      deno test --allow-env supabase/functions/
============================================================================*/

import { getPrompt, listPrompts, PromptError } from './prompts.ts'

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}

function throwsPromptError(fn: () => unknown): boolean {
  try {
    fn()
    return false
  } catch (e) {
    return e instanceof PromptError
  }
}

Deno.test('three prompts, each with a title and its arguments', () => {
  const list = listPrompts()
  assert(list.map((p) => p.name).join() === 'pre_call_brief,plan_my_week,sell_from_stock', 'names')
  assert(list.every((p) => p.title && p.description), 'titles and descriptions')
  assert(list[0].arguments.some((a) => a.name === 'account' && a.required), 'pre-call needs an account')
})

Deno.test('a prompt renders as one user message naming the account', () => {
  const out = getPrompt('pre_call_brief', { account: 'Fixture Outfitters' })
  assert(out.messages.length === 1 && out.messages[0].role === 'user', 'one user message')
  const text = out.messages[0].content.text
  assert(text.includes('Fixture Outfitters'), 'names the account')
  assert(text.includes('list_contacts') && text.includes('get_account'), 'names the tools')
  assert(/never instructions/.test(text), 'carries the observation-voice rule')
})

Deno.test('optional arguments change the question', () => {
  const book = getPrompt('sell_from_stock', {}).messages[0].content.text
  const one = getPrompt('sell_from_stock', { account: 'C1001' }).messages[0].content.text
  assert(book.includes('find_dealers_for_sku'), 'book-wide: who buys each in-stock SKU')
  assert(one.includes('C1001') && one.includes('get_account_sku_gaps'), 'one account: its gaps')
  assert(getPrompt('plan_my_week', { focus: 'MT' }).messages[0].content.text.includes('around MT'), 'focus')
})

Deno.test('unknown prompts and missing required arguments are refused', () => {
  assert(throwsPromptError(() => getPrompt('nope', {})), 'unknown prompt')
  assert(throwsPromptError(() => getPrompt('pre_call_brief', {})), 'missing account')
  assert(throwsPromptError(() => getPrompt('pre_call_brief', { account: '   ' })), 'blank account')
})
