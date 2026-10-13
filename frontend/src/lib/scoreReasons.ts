/**
 * "Why is this account on the list?" — account_signals.factors as plain
 * English. Pure functions, no Vue.
 *
 * The nightly score (019_account_scoring.sql) stores, per factor, the value,
 * its weight, its contribution to the composite and a `why` sentence written
 * for a rep ("Usually orders every 34 days — 96 since the last one").
 * explain_score() (020_recommendation_engine_v2.sql) joins the two biggest
 * contributors into the reason on a recommendation. explainScore() below is
 * that function in TypeScript, so the call list says exactly what a
 * recommendation would have said; topReasons() is the same pick, kept as
 * separate lines so each can be a chip.
 */

/** The five factors score_account() can write. Anything else is passed through. */
export const FACTOR_KEYS = ['cadence', 'recency', 'trend', 'value', 'mix'] as const
export type FactorKey = (typeof FACTOR_KEYS)[number]

export interface ScoreFactor {
  value: number | null
  weight: number | null
  /** Points of the composite this factor produced. The ranking key. */
  contribution: number | null
  why: string | null
}

/** account_signals.factors, keyed by factor name. */
export type ScoreFactors = Record<string, ScoreFactor>

export interface ScoreReason {
  factor: string
  /** The sentence score_account() wrote, untouched. */
  why: string
  /** The same fact, trimmed for a chip. */
  label: string
  contribution: number
}

function numOrNull(value: unknown): number | null {
  if (value == null || value === '') return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

/**
 * Whatever came back for the jsonb column, as factors. Tolerates null, a
 * JSON string (some drivers hand jsonb back serialized) and junk entries —
 * a malformed blob means "no reasons", never a crash on the Overview.
 */
export function parseFactors(raw: unknown): ScoreFactors {
  let obj = raw
  if (typeof obj === 'string') {
    try {
      obj = JSON.parse(obj)
    } catch {
      return {}
    }
  }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return {}
  const out: ScoreFactors = {}
  for (const [key, f] of Object.entries(obj as Record<string, unknown>)) {
    if (!f || typeof f !== 'object' || Array.isArray(f)) continue
    const r = f as Record<string, unknown>
    const why = typeof r.why === 'string' && r.why.trim() ? r.why.trim() : null
    out[key] = {
      value: numOrNull(r.value),
      weight: numOrNull(r.weight),
      contribution: numOrNull(r.contribution),
      why,
    }
  }
  return out
}

/**
 * Factors with something to say, biggest contribution first — the ORDER BY
 * of explain_score(). Two deliberate differences from the SQL, neither of
 * which score_account() can produce today: a factor with no contribution
 * sorts last (Postgres would put the NULL first), and equal contributions
 * break by weight then name instead of arbitrarily, so the same blob always
 * reads the same way.
 */
function ranked(factors: ScoreFactors): [string, ScoreFactor & { why: string }][] {
  return Object.entries(factors)
    .filter((e): e is [string, ScoreFactor & { why: string }] => !!e[1].why)
    .sort(([ak, a], [bk, b]) => {
      const ac = a.contribution ?? Number.NEGATIVE_INFINITY
      const bc = b.contribution ?? Number.NEGATIVE_INFINITY
      if (ac !== bc) return bc - ac
      const aw = a.weight ?? 0
      const bw = b.weight ?? 0
      if (aw !== bw) return bw - aw
      return ak < bk ? -1 : ak > bk ? 1 : 0
    })
}

/**
 * explain_score() in TypeScript: the two highest-contributing `why`
 * sentences joined with '. ', or null when no factor has one.
 */
export function explainScore(raw: unknown): string | null {
  const top = ranked(parseFactors(raw)).slice(0, 2)
  return top.length ? top.map(([, f]) => f.why).join('. ') : null
}

const CADENCE_RE = /^Usually orders every (\d+) days? — (\d+) since the last one$/i
const TREND_RE = /^\$[\d,]+ trailing 12 months, (down|up) (\d+)% from last year$/i
const VALUE_RE = /^\$([\d,]+) trailing 12 months$/i
const MIX_DROPPED_RE = /^Bought (\d+) product (family|families) last year that they have not this year$/i

/**
 * A `why` trimmed for a chip. Sentence case and still a sentence — these
 * are read by people who skip dashboards, so "Down 31% from last year"
 * rather than "YoY −31%". Only the long forms are shortened; anything this
 * does not recognise (a reworded SQL sentence, a future factor) is shown as
 * written rather than guessed at.
 */
export function reasonLabel(factor: string, why: string): string {
  const text = why.trim()
  if (factor === 'cadence' && CADENCE_RE.test(text)) {
    // Already the shortest true version: the rhythm AND how late. Keep it.
    return text
  }
  if (factor === 'trend') {
    const m = TREND_RE.exec(text)
    // The dollar half repeats the value factor, which usually sits beside it.
    if (m) return `${m[1]![0]!.toUpperCase()}${m[1]!.slice(1).toLowerCase()} ${m[2]}% from last year`
  }
  if (factor === 'value') {
    const m = VALUE_RE.exec(text)
    if (m) return `$${m[1]} in the last 12 months`
  }
  if (factor === 'mix') {
    const m = MIX_DROPPED_RE.exec(text)
    if (m) return `Stopped buying ${m[1]} product ${m[2]!.toLowerCase()}`
  }
  return text
}

/** The top `n` reasons, each as its own line — explainScore() unjoined. */
export function topReasons(raw: unknown, n = 2): ScoreReason[] {
  return ranked(parseFactors(raw))
    .slice(0, Math.max(0, n))
    .map(([factor, f]) => ({
      factor,
      why: f.why,
      label: reasonLabel(factor, f.why),
      contribution: f.contribution ?? 0,
    }))
}

/* ------------------------------------------------------- one row's chips */

/**
 * What the Overview's classifier (useOverview.ts observeAccount) says about
 * an account, reduced to what a chip needs. Structural, so this file does not
 * import the composable.
 */
export interface ObservationChip {
  kind: 'cadence' | 'dormant' | 'decline' | 'backlog'
  chip: string
}

export interface ReasonChip {
  /** Stable key for v-for: the factor or observation kind. */
  key: string
  label: string
  /** The full sentence behind the chip, for title / screen readers. */
  detail: string
}

/** Which score factor already covers each observation kind. */
const SAME_TOPIC: Record<ObservationChip['kind'], string | null> = {
  cadence: 'cadence',
  dormant: 'cadence', // "No order in N days" is the cadence factor's unconfident line
  decline: 'trend',
  backlog: null, //      past-promise money is not a score factor at all
}

/**
 * Up to `max` chips for one call-list row: the score's own reasons first
 * (they are why the row is ranked where it is), with the classifier's
 * observation taking the last slot when it says something the score does
 * not — typically "$14,000 past promise date", which no factor measures.
 * Never two chips about the same thing.
 */
export function rowChips(
  reasons: ScoreReason[],
  observation: ObservationChip | null,
  max = 2,
): ReasonChip[] {
  const chips: ReasonChip[] = reasons.map((r) => ({
    key: r.factor,
    label: r.label,
    detail: r.why,
  }))
  if (observation) {
    const topic = SAME_TOPIC[observation.kind]
    const covered = topic != null && reasons.some((r) => r.factor === topic)
    if (!covered) {
      const obsChip = {
        key: `obs-${observation.kind}`,
        label: observation.chip,
        detail: observation.chip,
      }
      if (chips.length >= max) chips.splice(max - 1, chips.length, obsChip)
      else chips.push(obsChip)
    }
  }
  return chips.slice(0, Math.max(0, max))
}

/* ------------------------------------------------------------- money */

export interface YtdChange {
  /** "▲ $12,850", "▼ $3,100" or "even" — what the eye reads. */
  text: string
  /** The same for a screen reader, in words. */
  sr: string
  direction: 'up' | 'down' | 'even'
}

/**
 * This year so far against the same days last year, as one short mark.
 * Null when there is nothing to compare (no money either year, or unknown).
 * `formatMoney` is lib/format money(), passed in to keep this file free of
 * Intl setup in tests.
 */
export function ytdChange(
  ytd: number | null | undefined,
  priorYtd: number | null | undefined,
  formatMoney: (n: number) => string,
): YtdChange | null {
  if (ytd == null || priorYtd == null) return null
  if (!Number.isFinite(ytd) || !Number.isFinite(priorYtd)) return null
  if (ytd === 0 && priorYtd === 0) return null
  const d = ytd - priorYtd
  if (d === 0) return { text: 'even', sr: 'even with this time last year', direction: 'even' }
  const amount = formatMoney(Math.abs(d))
  return d > 0
    ? { text: `▲ ${amount}`, sr: `up ${amount} on this time last year`, direction: 'up' }
    : { text: `▼ ${amount}`, sr: `down ${amount} on this time last year`, direction: 'down' }
}

/** The house colours for a change: green up, ember down (as the movers card). */
export const YTD_TONE: Record<YtdChange['direction'], string> = {
  up: 'text-brand',
  down: 'text-accent',
  even: 'text-muted',
}
