/**
 * Unit tests for briefHeadlines() in composables/useAiBrief.ts — the
 * tappable headlines on the Sales Brief.
 *
 * Run with:  npm run test:unit -- briefHeadlines
 *
 * Same harness as ffl.test.ts. ai_briefs.items is JSON from the database,
 * written by an Edge Function that may be older or newer than this build:
 * anything not in the expected shape must fall back to the prose headlines
 * (null), never throw on the Overview.
 */
import { briefHeadlines, parseBrief } from '../../src/composables/useAiBrief'

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

t('no items → prose path', briefHeadlines({ items: undefined }), null)
t('null items → prose path', briefHeadlines({ items: null }), null)
t('null row', briefHeadlines(null), null)
t('items without headlines', briefHeadlines({ items: { foo: 1 } }), null)
t('headlines not an array', briefHeadlines({ items: { headlines: 'x' } }), null)
t('empty headlines → prose path', briefHeadlines({ items: { headlines: [] } }), null)

t(
  'tagged and untagged headlines',
  briefHeadlines({
    items: {
      headlines: [
        { text: 'Territory up 6%', customer_key: null, account_name: null },
        { text: ' Canyon Creek quiet since June ', customer_key: 'C9', account_name: 'Canyon Creek' },
      ],
    },
  }),
  [
    { text: 'Territory up 6%', customerKey: null, accountName: null },
    { text: 'Canyon Creek quiet since June', customerKey: 'C9', accountName: 'Canyon Creek' },
  ],
)

t(
  'junk entries are skipped, a key with no name keeps the key',
  briefHeadlines({
    items: {
      headlines: [null, 7, { text: '' }, { text: 'Big Sky up $58,000', customer_key: 'C2' }],
    },
  }),
  [{ text: 'Big Sky up $58,000', customerKey: 'C2', accountName: null }],
)

t(
  'a blank key is no key',
  briefHeadlines({ items: { headlines: [{ text: 'x', customer_key: '  ', account_name: 'Nope' }] } }),
  [{ text: 'x', customerKey: null, accountName: null }],
)

/* The prose path still parses the same content the server keeps writing. */
t(
  'parseBrief still splits the content of a tagged brief',
  parseBrief('HEADLINES\n• Territory up 6%\n• Canyon Creek quiet since June\n\nBody one.\n\nBody two.'),
  { headlines: ['Territory up 6%', 'Canyon Creek quiet since June'], body: 'Body one.\n\nBody two.' },
)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
