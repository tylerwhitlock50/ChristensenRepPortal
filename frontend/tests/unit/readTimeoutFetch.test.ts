/**
 * Unit tests for readTimeoutFetch() in lib/supabase.ts — the fetch wrapper
 * that gives up on a read that never answers.
 *
 * Run with:  npm run test:unit -- readTimeout
 *
 * The rules under test: GET and HEAD time out, with an AbortError (so
 * postgrest-js does not retry it three more times); writes and Storage never
 * do; the caller's own abort signal still works; a response that arrives in
 * time is passed through untouched. global fetch is replaced with a fake that
 * answers after a chosen delay, or never.
 */
import { describeError, readTimeoutFetch } from '../../src/lib/supabase'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(
      `FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`,
    )
  }
}

/** A fetch that answers after `ms`, or never (null), and honours its signal. */
function fakeFetch(ms: number | null) {
  return (_input: RequestInfo | URL, init?: RequestInit) =>
    new Promise<Response>((resolve, reject) => {
      const signal = init?.signal
      if (signal?.aborted) return reject(signal.reason)
      signal?.addEventListener('abort', () => reject(signal.reason), { once: true })
      if (ms != null) setTimeout(() => resolve(new Response('ok')), ms)
    })
}

async function outcome(p: Promise<Response>): Promise<string> {
  try {
    const res = await p
    return `ok:${await res.text()}`
  } catch (e) {
    const err = e as { name?: string; message?: string }
    return `${err.name}:${err.message}`
  }
}

const URL_REST = 'https://x.supabase.co/rest/v1/v_account_summary?select=*'
const URL_STORAGE = 'https://x.supabase.co/storage/v1/object/account-photos/a.jpg'
const fetch30 = readTimeoutFetch(30)

/* --- reads that hang are cut off ----------------------------------------- */
globalThis.fetch = fakeFetch(null) as typeof fetch
const hung = await outcome(fetch30(URL_REST))
t('a GET that never answers is aborted', hung.startsWith('AbortError:'), true)
t('…with the message describeError recognises', /timed out on a slow connection/.test(hung), true)
t('HEAD times out too', (await outcome(fetch30(URL_REST, { method: 'HEAD' }))).startsWith('AbortError:'), true)
t('lower-case method still counts as a read', (await outcome(fetch30(URL_REST, { method: 'get' }))).startsWith('AbortError:'), true)
t(
  'a Request object with no init is a GET',
  (await outcome(fetch30(new Request(URL_REST)))).startsWith('AbortError:'),
  true,
)

/* --- writes and Storage are never timed out ------------------------------ */
globalThis.fetch = fakeFetch(80) as typeof fetch
t('POST outlives the timeout', await outcome(fetch30(URL_REST, { method: 'POST', body: '{}' })), 'ok:ok')
t('PATCH outlives the timeout', await outcome(fetch30(URL_REST, { method: 'PATCH', body: '{}' })), 'ok:ok')
t('DELETE outlives the timeout', await outcome(fetch30(URL_REST, { method: 'DELETE' })), 'ok:ok')
t('a Storage GET outlives the timeout', await outcome(fetch30(URL_STORAGE)), 'ok:ok')

/* --- in-time answers pass through ---------------------------------------- */
globalThis.fetch = fakeFetch(5) as typeof fetch
t('a GET that answers in time', await outcome(fetch30(URL_REST)), 'ok:ok')

/* --- the caller's own signal --------------------------------------------- */
globalThis.fetch = fakeFetch(null) as typeof fetch
{
  const caller = new AbortController()
  const p = outcome(readTimeoutFetch(5_000)(URL_REST, { signal: caller.signal }))
  caller.abort(new DOMException('rep navigated away', 'AbortError'))
  t('the caller can still cancel', await p, 'AbortError:rep navigated away')
}
{
  const caller = new AbortController()
  caller.abort(new DOMException('already gone', 'AbortError'))
  t(
    'an already-aborted caller signal aborts at once',
    await outcome(readTimeoutFetch(5_000)(URL_REST, { signal: caller.signal })),
    'AbortError:already gone',
  )
}

/* --- what the rep reads -------------------------------------------------- */
t(
  'describeError turns the postgrest-js wrapping into a sentence',
  /too weak to load this/.test(
    describeError({ message: 'AbortError: The request timed out on a slow connection' }),
  ),
  true,
)
t(
  'an ordinary network failure keeps its own sentence',
  /couldn't reach the network/.test(describeError({ message: 'TypeError: Failed to fetch' })),
  true,
)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
