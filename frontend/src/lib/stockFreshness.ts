/**
 * When the In stock list's "Stock as of" turns amber.
 *
 * The stock table loads every 15 minutes, Monday to Friday, 05:00 to 17:45
 * on the ETL server's clock (America/Denver — the server and the database
 * both run on Mountain time). Three missed loads in a row means something
 * upstream has stopped, and a rep quoting availability off that list should
 * know before the dealer does. Outside those hours (evenings, weekends) no
 * load is due, so an old stamp is expected and stays plain: a Saturday
 * stamp from Friday 5:45 PM is current, not stale.
 *
 * The window opens at 05:30, not 05:00, so the first load of the morning
 * has run (and the Friday-evening stamp has been replaced) before anything
 * is judged. Pure and dependency-free, for tests/unit/freshness.test.ts.
 */

/** Three missed 15-minute loads. */
export const ATS_STALE_AFTER_MS = 45 * 60_000

/** The ETL server's (and the database's) zone — not the rep's. */
const LOAD_ZONE = 'America/Denver'
/** 05:30 and 18:00, as minutes after midnight. */
const WINDOW_OPENS = 5 * 60 + 30
const WINDOW_CLOSES = 18 * 60

const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri']

const zoneParts = new Intl.DateTimeFormat('en-US', {
  timeZone: LOAD_ZONE,
  weekday: 'short',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
})

/** True while a stock load is due: a weekday, 05:30–18:00 Mountain. */
export function inStockLoadWindow(now: Date): boolean {
  const parts = Object.fromEntries(zoneParts.formatToParts(now).map((p) => [p.type, p.value]))
  if (!WEEKDAYS.includes(parts.weekday ?? '')) return false
  // Some engines write midnight as "24" even under h23.
  const minutes = (Number(parts.hour) % 24) * 60 + Number(parts.minute)
  return minutes >= WINDOW_OPENS && minutes < WINDOW_CLOSES
}

/**
 * True when the stock stamp is older than three loads while loads are due.
 * No stamp, or one that does not parse, is not "stale" — there is nothing
 * to warn about that the page does not already say.
 */
export function isAtsStale(asOf: string | Date | null | undefined, now: Date = new Date()): boolean {
  if (!asOf) return false
  const at = asOf instanceof Date ? asOf.getTime() : Date.parse(asOf)
  if (!Number.isFinite(at)) return false
  return now.getTime() - at > ATS_STALE_AFTER_MS && inStockLoadWindow(now)
}

/**
 * The newest `loaded_at` on the rows themselves: the stock stamp on a
 * database without v_data_freshness.ats_loaded_at. Every row of a load
 * carries the same value (the table is replaced whole), so the max is that
 * load's time.
 */
export function newestLoadedAt(rows: readonly { loaded_at: string | null }[]): string | null {
  let best: string | null = null
  let bestAt = -Infinity
  for (const r of rows) {
    if (!r.loaded_at) continue
    const at = Date.parse(r.loaded_at)
    if (Number.isFinite(at) && at > bestAt) {
      best = r.loaded_at
      bestAt = at
    }
  }
  return best
}
