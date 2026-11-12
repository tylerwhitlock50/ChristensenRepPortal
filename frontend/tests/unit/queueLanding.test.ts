/**
 * Unit tests for lib/queueLanding.ts: the per-tab flag that sends inside
 * sales from the Overview to the entry queue once (router/index.ts), and
 * that sign-out clears (stores/session.ts signOut).
 *
 * Run with:  npm run test:unit -- queueLanding
 *
 * What matters: once landed, the tab stays on the Overview; an explicit
 * sign-out forgets it, so signing in again in the same tab (the next
 * morning, in the same installed app window) starts in the queue; storage
 * that throws never breaks the guard or the sign-out.
 */
import {
  QUEUE_LANDING_KEY,
  forgetQueueLanding,
  landedOnQueueThisTab,
  rememberQueueLanding,
} from '../../src/lib/queueLanding'

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

const store = new Map<string, string>()
const memoryStorage = {
  getItem: (k: string) => store.get(k) ?? null,
  setItem: (k: string, v: string) => void store.set(k, v),
  removeItem: (k: string) => void store.delete(k),
}
const g = globalThis as unknown as { window?: { sessionStorage: unknown } }
g.window = { sessionStorage: memoryStorage }

t('the key the router and the session store share', QUEUE_LANDING_KEY, 'rep-portal:landed-on-queue')
t('a fresh tab has not landed yet', landedOnQueueThisTab(), false)
rememberQueueLanding()
t('after the landing, this tab stays on the Overview', landedOnQueueThisTab(), true)
forgetQueueLanding()
t('a sign-out forgets it: the next sign-in lands on the queue', landedOnQueueThisTab(), false)
t('…and leaves nothing behind', store.has(QUEUE_LANDING_KEY), false)
forgetQueueLanding()
t('forgetting twice is harmless', landedOnQueueThisTab(), false)

const throwing = () => {
  throw new DOMException('The operation is insecure.', 'SecurityError')
}
g.window = { sessionStorage: { getItem: throwing, setItem: throwing, removeItem: throwing } }
t('blocked storage reads as not landed (every arrival lands)', landedOnQueueThisTab(), false)
let threw = false
try {
  rememberQueueLanding()
  forgetQueueLanding()
} catch {
  threw = true
}
t('…and remembering or forgetting never throws', threw, false)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
