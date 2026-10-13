/**
 * Unit tests for lib/scoreReasons.ts — account_signals.factors as the
 * call list's "why".
 *
 * Run with:  npm run test:unit -- scoreReasons
 *
 * No test framework (see ffl.test.ts for why). The fixtures are the exact
 * sentences score_account() (019_account_scoring.sql) writes, because the
 * chip shortening matches on them: if the SQL wording drifts, these fail
 * here instead of a chip silently showing the long form.
 */
import {
  explainScore,
  parseFactors,
  reasonLabel,
  rowChips,
  topReasons,
  ytdChange,
} from '../../src/lib/scoreReasons'

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

/** A blob as score_account() builds it: value/weight/contribution/why. */
const FACTORS = {
  cadence: {
    value: 100,
    weight: 30,
    contribution: 37.5,
    why: 'Usually orders every 34 days — 96 since the last one',
  },
  recency: { value: 40, weight: 20, contribution: 10, why: 'No contact logged in 36 days' },
  trend: {
    value: 62,
    weight: 20,
    contribution: 15.5,
    why: '$48,000 trailing 12 months, down 31% from last year',
  },
  value: { value: 81, weight: 20, contribution: 20.3, why: '$48,000 trailing 12 months' },
  mix: {
    value: 49,
    weight: 10,
    contribution: 6.1,
    why: 'Bought 2 product families last year that they have not this year',
  },
}

/* --- explainScore: the SQL port ---------------------------------------- */
t(
  'explainScore joins the top two by contribution with ". "',
  explainScore(FACTORS),
  'Usually orders every 34 days — 96 since the last one. $48,000 trailing 12 months',
)
t('explainScore of {} is null', explainScore({}), null)
t('explainScore of null is null', explainScore(null), null)
t(
  'explainScore of a single factor is that sentence alone',
  explainScore({ value: FACTORS.value }),
  '$48,000 trailing 12 months',
)
t(
  'factors without a why are skipped (string_agg over why is not null)',
  explainScore({
    cadence: { value: 90, weight: 30, contribution: 50 },
    trend: FACTORS.trend,
  }),
  '$48,000 trailing 12 months, down 31% from last year',
)
t(
  'a jsonb blob that arrives as a JSON string still parses',
  explainScore(JSON.stringify({ mix: FACTORS.mix })),
  'Bought 2 product families last year that they have not this year',
)
t('junk is no reasons, not a crash', explainScore('not json'), null)
t('an array is no reasons', explainScore([1, 2]), null)
t(
  'numeric strings rank as numbers ("9" < "20")',
  topReasons({
    a: { contribution: '9', why: 'nine' },
    b: { contribution: '20', why: 'twenty' },
  }).map((r) => r.why),
  ['twenty', 'nine'],
)
t(
  'a missing contribution sorts last, not first',
  topReasons({
    a: { why: 'no contribution' },
    b: { contribution: 1, why: 'one point' },
  }).map((r) => r.why),
  ['one point', 'no contribution'],
)
t(
  'equal contributions break by weight, then name — stable',
  topReasons({
    zeta: { contribution: 5, weight: 10, why: 'z' },
    alpha: { contribution: 5, weight: 10, why: 'a' },
    heavy: { contribution: 5, weight: 30, why: 'h' },
  }).map((r) => r.factor),
  ['heavy', 'alpha'],
)
t('parseFactors drops non-object entries', Object.keys(parseFactors({ a: 1, b: null, c: { why: 'x' } })), ['c'])

/* --- topReasons / labels ------------------------------------------------ */
t(
  'topReasons keeps the full sentence and a chip label',
  topReasons(FACTORS),
  [
    {
      factor: 'cadence',
      why: 'Usually orders every 34 days — 96 since the last one',
      label: 'Usually orders every 34 days — 96 since the last one',
      contribution: 37.5,
    },
    {
      factor: 'value',
      why: '$48,000 trailing 12 months',
      label: '$48,000 in the last 12 months',
      contribution: 20.3,
    },
  ],
)
t('topReasons n=0 is empty', topReasons(FACTORS, 0), [])
t('topReasons n=5 is all five', topReasons(FACTORS, 5).length, 5)

t(
  'trend: the dollar half goes (the value chip carries it)',
  reasonLabel('trend', '$48,000 trailing 12 months, down 31% from last year'),
  'Down 31% from last year',
)
t(
  'trend up reads up',
  reasonLabel('trend', '$1,200,000 trailing 12 months, up 4% from last year'),
  'Up 4% from last year',
)
t(
  'value: "trailing" becomes "in the last"',
  reasonLabel('value', '$1,250,000 trailing 12 months'),
  '$1,250,000 in the last 12 months',
)
t(
  'mix dropped, plural',
  reasonLabel('mix', 'Bought 2 product families last year that they have not this year'),
  'Stopped buying 2 product families',
)
t(
  'mix dropped, singular',
  reasonLabel('mix', 'Bought 1 product family last year that they have not this year'),
  'Stopped buying 1 product family',
)
t('mix breadth passes through', reasonLabel('mix', 'Buying 1 product family'), 'Buying 1 product family')
t('unconfident cadence passes through', reasonLabel('cadence', 'No order in 96 days'), 'No order in 96 days')
t('recency passes through', reasonLabel('recency', 'No contact ever logged'), 'No contact ever logged')
t(
  'an unrecognised sentence is shown as written',
  reasonLabel('trend', 'Something new the SQL says'),
  'Something new the SQL says',
)
t('an unknown factor is shown as written', reasonLabel('weather', 'Snowed in'), 'Snowed in')

/* --- rowChips: score reasons + the classifier ---------------------------- */
const reasons = topReasons(FACTORS)
t(
  'backlog is not a score factor, so it takes the last slot',
  rowChips(reasons, { kind: 'backlog', chip: '$14,000 past promise date' }).map((c) => c.label),
  ['Usually orders every 34 days — 96 since the last one', '$14,000 past promise date'],
)
t(
  'a cadence observation is already said by the cadence factor',
  rowChips(reasons, { kind: 'cadence', chip: 'Usually orders every 34 days — 96 since the last one' }).map(
    (c) => c.key,
  ),
  ['cadence', 'value'],
)
t(
  'dormant counts as the cadence topic too',
  rowChips(reasons, { kind: 'dormant', chip: 'No invoice in 120 days' }).map((c) => c.key),
  ['cadence', 'value'],
)
t(
  'decline is covered when trend is among the reasons',
  rowChips(topReasons({ trend: FACTORS.trend }), { kind: 'decline', chip: 'Down 50% vs this time last year' }).map(
    (c) => c.key,
  ),
  ['trend'],
)
t(
  'decline adds a chip when trend is not a reason',
  rowChips(topReasons({ value: FACTORS.value }), { kind: 'decline', chip: 'Down 50% vs this time last year' }).map(
    (c) => c.key,
  ),
  ['value', 'obs-decline'],
)
t('no reasons, no observation: no chips', rowChips([], null), [])
t(
  'observation alone is one chip',
  rowChips([], { kind: 'dormant', chip: 'No invoice in 95 days' }),
  [{ key: 'obs-dormant', label: 'No invoice in 95 days', detail: 'No invoice in 95 days' }],
)
t('max caps the chips', rowChips(topReasons(FACTORS, 5), null, 2).length, 2)

/* --- ytdChange ---------------------------------------------------------- */
const usd = (n: number) => `$${n.toLocaleString('en-US')}`
t('up', ytdChange(84250, 71400, usd), { text: '▲ $12,850', sr: 'up $12,850 on this time last year', direction: 'up' })
t('down', ytdChange(9800, 31000, usd), { text: '▼ $21,200', sr: 'down $21,200 on this time last year', direction: 'down' })
t('even', ytdChange(500, 500, usd)?.direction, 'even')
t('nothing either year is nothing to say', ytdChange(0, 0, usd), null)
t('unknown is nothing to say', ytdChange(null, 100, usd), null)
t('new this year reads as up', ytdChange(12500, 0, usd)?.text, '▲ $12,500')

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
