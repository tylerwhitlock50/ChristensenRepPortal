/**
 * The half of lib/legal.ts that every page load needs: the session store
 * reads legal_status() with it, and the router guard sends people on with
 * safeRedirect(). Kept apart from the agreement screen's helpers so the
 * app's entry chunk carries only this (scripts/check-bundle.mjs).
 * Import from '@/lib/legal' everywhere else; it re-exports all of this.
 */

export type LegalDocKey = 'terms' | 'privacy'

/** One entry of legal_status().documents. */
export interface LegalStatusEntry {
  document_id: number
  doc_key: LegalDocKey
  version: string
  title: string
  effective_at: string
  content_sha256: string
  /** When this person agreed to THIS version, or null. */
  accepted_at: string | null
  /** The newest version of this document they agreed to (may be older). */
  last_accepted_version: string | null
  last_accepted_at: string | null
}

export interface LegalStatus {
  documents: LegalStatusEntry[]
  all_accepted: boolean
}

/**
 * The status when the database has no agreement to ask for: the migration is
 * not applied yet (the portal deploys after it, but a preview build can run
 * against an older database). Nothing to agree to is not a reason to lock
 * everyone out.
 */
export const NO_LEGAL_REQUIREMENT: LegalStatus = Object.freeze({
  documents: [],
  all_accepted: true,
}) as LegalStatus

const isKey = (v: unknown): v is LegalDocKey => v === 'terms' || v === 'privacy'
const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null)

/**
 * The ONE failure that means "nothing to agree to": legal_status() itself
 * is not in the database (the migration is not applied yet). PostgREST
 * reports that as PGRST202 naming the function; a stale schema cache right
 * after a drop as 42883 naming it. Every other error — a function, table
 * or column that legal_status() needs — is a broken gate and keeps it shut.
 * The same rule as the MCP endpoint's (supabase/functions/mcp/legal.ts).
 */
export function isMissingLegalStatusFunction(error: unknown): boolean {
  const e = error as { code?: string; message?: string } | null
  if (!e) return false
  const message = e.message ?? ''
  if (e.code === 'PGRST202') return !message || /\blegal_status\b/i.test(message)
  if (e.code === '42883') return /^function (public\.)?legal_status\(\) does not exist/i.test(message)
  return false
}

/**
 * legal_status()'s jsonb, or null when it is not one. all_accepted is
 * recomputed from the entries rather than trusted on its own, so a malformed
 * answer can only ever read as "not agreed".
 */
export function parseLegalStatus(raw: unknown): LegalStatus | null {
  if (!raw || typeof raw !== 'object') return null
  const docs = (raw as { documents?: unknown }).documents
  if (!Array.isArray(docs)) return null
  const documents: LegalStatusEntry[] = []
  for (const d of docs) {
    if (!d || typeof d !== 'object') return null
    const e = d as Record<string, unknown>
    const id = Number(e.document_id)
    if (!Number.isSafeInteger(id) || !isKey(e.doc_key) || !str(e.version)) return null
    documents.push({
      document_id: id,
      doc_key: e.doc_key,
      version: String(e.version),
      title: str(e.title) ?? '',
      effective_at: str(e.effective_at) ?? '',
      content_sha256: str(e.content_sha256) ?? '',
      accepted_at: str(e.accepted_at),
      last_accepted_version: str(e.last_accepted_version),
      last_accepted_at: str(e.last_accepted_at),
    })
  }
  const flag = (raw as { all_accepted?: unknown }).all_accepted
  return {
    documents,
    all_accepted: flag === true && documents.every((d) => d.accepted_at !== null),
  }
}

/**
 * Where to go once agreed: the `redirect` the guard carried, if it is a path
 * inside this app, else the Overview. Never another origin (`//evil.test`,
 * `/\evil.test`), never back to the agreement screen itself.
 */
export function safeRedirect(raw: unknown, fallback = '/'): string {
  const value = Array.isArray(raw) ? raw[0] : raw
  if (typeof value !== 'string') return fallback
  if (!value.startsWith('/') || value.startsWith('//') || value.startsWith('/\\')) return fallback
  if (/^\/agreements(?:[/?#]|$)/.test(value)) return fallback
  return value
}

/* ---- the one fact the device remembers ---------------------------------- */

const STAMP_PREFIX = 'rep-portal:legal-accepted:'

interface Stamp {
  /** doc_key → version agreed to, as of the last check online. */
  versions: Partial<Record<LegalDocKey, string>>
  at: number
}

/**
 * Remember, per user, that this person had agreed to every current document
 * the last time the portal could check. Only that: no text, no timestamps
 * from the server. Forgotten the moment a check says otherwise.
 *
 * The offline open (no signal, the rep's saved copy) cannot ask the
 * database, and must not show anything to someone who never agreed; this is
 * what it asks instead. A new version published while the phone is offline
 * is asked for on the next open with a signal.
 */
export function rememberLegalStatus(userId: string, status: LegalStatus) {
  try {
    if (!status.all_accepted) {
      localStorage.removeItem(STAMP_PREFIX + userId)
      return
    }
    const versions: Stamp['versions'] = {}
    for (const d of status.documents) versions[d.doc_key] = d.version
    localStorage.setItem(STAMP_PREFIX + userId, JSON.stringify({ versions, at: Date.now() } satisfies Stamp))
  } catch {
    /* storage unavailable: the offline open then asks for a connection */
  }
}

/** Whether this device saw `userId` agree to everything current, last time it could check. */
export function agreedOnThisDevice(userId: string): boolean {
  try {
    const raw = localStorage.getItem(STAMP_PREFIX + userId)
    if (!raw) return false
    const stamp = JSON.parse(raw) as Partial<Stamp>
    return !!stamp && typeof stamp.at === 'number' && !!stamp.versions && typeof stamp.versions === 'object'
  } catch {
    return false
  }
}
