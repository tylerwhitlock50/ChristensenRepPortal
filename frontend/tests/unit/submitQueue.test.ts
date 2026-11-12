/**
 * Unit tests for lib/submitQueue.ts and the read-only role (inside sales,
 * 20261113090000). A visit queued on a phone whose user is now inside sales
 * is refused by the database with 'read_only_role: …' on every attempt; the
 * queue must keep it (nothing is ever dropped), word it plainly, and stop
 * sending it while the role is still read-only, instead of retrying with
 * backoff for ever. Any other failure still backs off and retries.
 *
 * Run with:  npm run test:unit -- submitQueue
 *
 * Supabase is stubbed at supabase.from; IndexedDB is fake-indexeddb.
 */
import 'fake-indexeddb/auto'
import { supabase } from '../../src/lib/supabase'
import { READ_ONLY_ROLE_MESSAGE } from '../../src/lib/readOnlyRole'
import {
  clearQueue,
  enqueue,
  flush,
  isStuck,
  refresh,
  type VisitSubmission,
} from '../../src/lib/submitQueue'

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

const RAW = 'read_only_role: inside sales can view visits but not change it'

/** What the next visits insert answers. */
let answer: { data: unknown; error: unknown } = { data: null, error: null }
let inserts = 0
;(supabase as unknown as { from: unknown }).from = () => ({
  insert: () => ({
    select: () => ({
      single: async () => {
        inserts += 1
        return answer
      },
    }),
  }),
})

const USER = '00000000-0000-0000-0000-00000000000a'
const payload = (): VisitSubmission => ({
  userId: USER,
  customerKey: 'C100',
  visit: { visit_type: 'in_person', visit_date: '2026-11-10' } as VisitSubmission['visit'],
  action: null,
  photos: [],
})

await clearQueue()

// ------------------------------------------------- the read-only refusal
await enqueue(payload())
answer = { data: null, error: { message: RAW, code: '42501', details: null, hint: null } }
const first = await flush({ userId: USER })
let [item] = await refresh()
t('the refused visit was sent once', inserts, 1)
t('…counted as failed', first.failed, 1)
t('…and kept: nothing is ever dropped', first.remaining, 1)
t('…marked as a refusal no retry can fix', item.blocked, 'read_only_role')
t('…shown as stuck at once', isStuck(item), true)
t('…in plain words, not the database code', item.lastError, READ_ONLY_ROLE_MESSAGE)
t('…with no retry scheduled', item.nextAttemptAt, null)

await flush({ userId: USER, readOnlyRole: true })
await flush({ userId: USER, readOnlyRole: true, force: true })
await flush({ userId: USER })
t('not sent again while the role is read-only, not even by Try now', inserts, 1)

// The role is a rep's again (the admin changed it back): it goes up.
answer = { data: { id: 77 }, error: null }
const later = await flush({ userId: USER, readOnlyRole: false })
t('sent once the role can write it', [inserts, later.sent, later.remaining], [2, 1, 0])

// ------------------------------------------------- any other failure
await enqueue(payload())
answer = { data: null, error: { message: 'canceling statement due to statement timeout', code: '57014' } }
await flush({ userId: USER })
;[item] = await refresh()
t('an ordinary failure is not blocked', item.blocked ?? null, null)
t('…keeps its own words', item.lastError, 'canceling statement due to statement timeout')
t('…and backs off to retry', item.nextAttemptAt !== null && item.attempts === 1, true)
t('…so it is not stuck yet', isStuck(item), false)

await clearQueue()
console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
