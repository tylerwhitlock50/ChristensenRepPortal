/**
 * Unit tests for deleteDraftOrder (composables/useOrders.ts) against a
 * stubbed database and bucket: deleting a draft takes its documents with it,
 * and must never take them off an order that is no longer a draft.
 *
 * Run with:  npm run test:unit -- deleteDraftOrder
 *
 * What matters: the row is read fresh first, and a submitted order (a
 * writer showing a cached draft, or one another device just submitted) is
 * refused before a single document is listed or removed; the delete itself
 * is pinned to status = 'draft', because RLS lets an admin delete an order
 * in any status; a delete that matches no row is a refusal, not a success.
 */
import { deleteDraftOrder } from '../../src/composables/useOrders'

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

async function rejection(promise: Promise<unknown>): Promise<string | null> {
  try {
    await promise
    return null
  } catch (e) {
    return (e as Error).message
  }
}

/**
 * A PostgREST client that records each query as one string and answers the
 * fresh read with `row`, the delete with `deleted`.
 */
function fakeDb(row: { id: number; status: string } | null, deleted: unknown[] | null = [{ id: 8123 }]) {
  const queries: string[] = []
  return {
    queries,
    from(table: string) {
      const chain = [`from(${table})`]
      const builder = {
        select(cols: string) {
          chain.push(`select(${cols})`)
          return builder
        },
        delete() {
          chain.push('delete()')
          return builder
        },
        eq(column: string, value: unknown) {
          chain.push(`eq(${column},${value})`)
          return builder
        },
        async maybeSingle() {
          queries.push(chain.join('.'))
          return { data: row, error: null }
        },
        then(resolve: (v: unknown) => unknown, reject: (e: unknown) => unknown) {
          queries.push(chain.join('.'))
          return Promise.resolve({ data: deleted, error: null }).then(resolve, reject)
        },
      }
      return builder
    },
  }
}

/** A bucket holding these file names under the order, removing `removable` of them. */
function fakeBucket(names: string[], removable = names.length) {
  const calls: string[] = []
  return {
    calls,
    list: async (folder: string) => {
      calls.push(`list(${folder})`)
      return { data: names.map((name) => ({ id: name, name, metadata: { size: 10 } })), error: null }
    },
    remove: async (paths: string[]) => {
      calls.push(`remove(${paths.join(',')})`)
      return { data: paths.slice(0, removable).map((name) => ({ name })), error: null }
    },
  }
}

const READ = 'from(orders).select(id, status).eq(id,8123)'
const DELETE = 'from(orders).delete().eq(id,8123).eq(status,draft).select(id)'

{
  // A writer opened from cache, or Delete tapped after another device submitted.
  const db = fakeDb({ id: 8123, status: 'submitted' })
  const bucket = fakeBucket(['1763000000000-PO.pdf'])
  const message = await rejection(deleteDraftOrder(db as never, bucket as never, 8123))
  t('a submitted order is refused', message, 'This order is no longer a draft; open its page.')
  t('…before any document is listed or removed', bucket.calls, [])
  t('…and nothing is deleted', db.queries, [READ])
}
{
  const db = fakeDb(null)
  const bucket = fakeBucket(['1763000000000-PO.pdf'])
  const message = await rejection(deleteDraftOrder(db as never, bucket as never, 8123))
  t('an order that is gone (or unreadable) is refused too', message,
    "That draft wasn't found: it may have been deleted already.")
  t('…without touching the bucket', bucket.calls, [])
}
{
  const db = fakeDb({ id: 8123, status: 'draft' })
  const bucket = fakeBucket(['1763000000000-PO.pdf'])
  t('a draft is deleted', await rejection(deleteDraftOrder(db as never, bucket as never, 8123)), null)
  t('…its documents first', bucket.calls, ['list(8123)', 'remove(8123/1763000000000-PO.pdf)'])
  t('…then the row, and only while it is still a draft (an admin may delete any status)',
    db.queries, [READ, DELETE])
}
{
  const db = fakeDb({ id: 8123, status: 'draft' })
  const bucket = fakeBucket(['1763000000000-PO.pdf', '1763000000001-Email.msg'], 1)
  const message = await rejection(deleteDraftOrder(db as never, bucket as never, 8123))
  t('a document someone else added stops the delete', message?.startsWith("This draft wasn't deleted: 1 of its documents was added by someone else"), true)
  t('…and the row stays', db.queries, [READ])
}
{
  // Submitted between the read and the delete: the status filter matches nothing.
  const db = fakeDb({ id: 8123, status: 'draft' }, [])
  const bucket = fakeBucket([])
  t('a delete that matches no row is a refusal',
    await rejection(deleteDraftOrder(db as never, bucket as never, 8123)),
    "That draft wasn't deleted. Only its owner or an admin can delete a draft, and only while it is a draft.")
}

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
