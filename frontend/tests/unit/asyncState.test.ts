/**
 * Unit tests for components/ui/AsyncState.vue — which branch renders.
 *
 * Run with:  npm run test:unit
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. Rendered with Vue's own server renderer (no DOM, no test-utils),
 * which is enough to see which of skeleton / error card / stale bar / empty /
 * slot came out.
 *
 * The case this exists for: TanStack keeps a query's data when a background
 * refetch fails and sets `error` beside it. With has-data set, that must keep
 * the data on screen under a quiet bar — not swap it for the full error card.
 */
import { createSSRApp, h } from 'vue'
import { renderToString } from 'vue/server-renderer'
import AsyncState from '../../src/components/ui/AsyncState.vue'

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

async function render(props: Record<string, unknown>): Promise<string> {
  const app = createSSRApp({
    render: () =>
      h(AsyncState, props, {
        default: () => h('p', 'THE DATA'),
        'empty-action': () => h('span', 'ADD ONE'),
      }),
  })
  return renderToString(app)
}

/** Which pieces are on screen, as a short list. */
async function shows(props: Record<string, unknown>): Promise<string[]> {
  const html = await render(props)
  const out: string[] = []
  if (html.includes('aria-busy="true"')) out.push('skeleton')
  if (html.includes("Couldn&#39;t load this") || html.includes("Couldn't load this")) out.push('error-card')
  if (html.includes('role="status"')) out.push('stale-bar')
  if (html.includes('EMPTY TITLE')) out.push('empty')
  if (html.includes('THE DATA')) out.push('slot')
  return out
}

const boom = { message: 'Failed to fetch' }
const base = { emptyTitle: 'EMPTY TITLE' }

async function main() {
  /* --- unchanged without has-data ------------------------------------- */
  t('loading → skeleton', await shows({ ...base, loading: true }), ['skeleton'])
  t('error → card', await shows({ ...base, error: boom }), ['error-card'])
  t('empty → empty', await shows({ ...base, empty: true }), ['empty'])
  t('data → slot', await shows({ ...base }), ['slot'])
  t('error beats empty', await shows({ ...base, error: boom, empty: true }), ['error-card'])

  /* --- has-data ------------------------------------------------------- */
  t(
    'failed refresh over data → slot under the stale bar',
    await shows({ ...base, error: boom, hasData: true }),
    ['stale-bar', 'slot'],
  )
  t(
    'failed refresh over an empty result → empty state under the bar',
    await shows({ ...base, error: boom, hasData: true, empty: true }),
    ['stale-bar', 'empty'],
  )
  t(
    'first load failed (no data) → full card',
    await shows({ ...base, error: boom, hasData: false }),
    ['error-card'],
  )
  t(
    'refetching with data on screen → no skeleton',
    await shows({ ...base, loading: true, hasData: true }),
    ['slot'],
  )

  /* --- the bar's words ------------------------------------------------- */
  const now = new Date()
  now.setHours(7, 42, 0, 0)
  const html = await render({ ...base, error: boom, hasData: true, updatedAt: now.getTime() })
  t('bar says when the data is from', html.includes('Showing data from 7:42 AM'), true)
  t('bar has a Retry button', /<button[^>]*>\s*Retry\s*<\/button>/.test(html), true)
  t('bar is not an alert', html.includes('role="alert"'), false)
  const live = /role="status"[^>]*>([\s\S]*?)<\/p>/.exec(html)?.[1] ?? ''
  t('the live region is the sentence, not the button', [live.includes('refresh'), live.includes('Retry')], [true, false])

  const noTime = await render({ ...base, error: boom, hasData: true })
  t('no updatedAt: no time', noTime.includes('Showing data from'), false)
  t('no updatedAt: still says it could not refresh', noTime.includes('refresh.'), true)

  // setDate, not minus 6×24h: across a DST change that would move the hour.
  const lastWeek = new Date(now)
  lastWeek.setDate(now.getDate() - 6)
  const older = await render({ ...base, error: boom, hasData: true, updatedAt: lastWeek.getTime() })
  t('older than today: the date is included', /Showing data from [A-Z][a-z]{2} \d{1,2}, 7:42 AM/.test(older), true)

  console.log(`\n${pass} passed, ${fail} failed`)
  if (fail > 0) process.exit(1)
}

void main()
