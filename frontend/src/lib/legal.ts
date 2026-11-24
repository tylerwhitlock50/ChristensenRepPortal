/**
 * The Terms of Use and the Privacy Policy every user agrees to before using
 * the portal (migration 20261124090000_legal_agreements.sql).
 *
 * The documents live in public.legal_documents, one immutable row per
 * published version; the agreement is a row per user per version in
 * public.legal_acceptances, written only by accept_legal_documents(). This
 * module is the pure half on the client: the shapes, reading the RPCs'
 * answers defensively, which documents are still to agree to, where to go
 * afterwards, and the one fact remembered on the device so the offline open
 * (stores/session.ts openOffline) can tell whether this person had agreed.
 *
 * The gate itself is the router guard (router/index.ts) plus useLegalGate()
 * for a status that changes mid-session; the screen is AgreementsView.vue.
 */

export * from './legalStatus'
import type {
  LegalDocKey,
  LegalStatus,
  LegalStatusEntry,
} from './legalStatus'

export const LEGAL_DOC_KEYS: readonly LegalDocKey[] = ['terms', 'privacy']

/** The public page each document is readable on, signed in or not. */
export const LEGAL_DOC_ROUTE: Readonly<Record<LegalDocKey, 'terms' | 'privacy'>> = {
  terms: 'terms',
  privacy: 'privacy',
}

/** What each document is called in the portal's own words (nav, buttons). */
export const LEGAL_DOC_LABEL: Readonly<Record<LegalDocKey, string>> = {
  terms: 'Terms of Use',
  privacy: 'Privacy Policy',
}

/** A row of legal_current_documents(): the version in force, full text. */
export interface LegalDocument {
  id: number
  doc_key: LegalDocKey
  version: string
  title: string
  summary: string | null
  body_md: string
  effective_at: string
  content_sha256: string
}

const isKey = (v: unknown): v is LegalDocKey => v === 'terms' || v === 'privacy'
const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null)

/** legal_current_documents()' rows, keeping only well-formed ones, terms first. */
export function parseLegalDocuments(raw: unknown): LegalDocument[] {
  if (!Array.isArray(raw)) return []
  const out: LegalDocument[] = []
  for (const r of raw) {
    if (!r || typeof r !== 'object') continue
    const e = r as Record<string, unknown>
    const id = Number(e.id)
    if (!Number.isSafeInteger(id) || !isKey(e.doc_key) || !str(e.version) || !str(e.body_md)) continue
    out.push({
      id,
      doc_key: e.doc_key,
      version: String(e.version),
      title: str(e.title) ?? LEGAL_DOC_LABEL[e.doc_key],
      summary: str(e.summary),
      body_md: String(e.body_md),
      effective_at: str(e.effective_at) ?? '',
      content_sha256: str(e.content_sha256) ?? '',
    })
  }
  return out.sort((a, b) => LEGAL_DOC_KEYS.indexOf(a.doc_key) - LEGAL_DOC_KEYS.indexOf(b.doc_key))
}

/**
 * The documents on screen that still need this person's agreement: every
 * current document whose version they have not agreed to. Matched by id,
 * not just by key, so a version published while the status was in flight
 * still counts as outstanding.
 */
export function documentsToAgree(
  documents: readonly LegalDocument[],
  status: LegalStatus | null,
): LegalDocument[] {
  return documents.filter((doc) => {
    const entry = status?.documents.find((d) => d.doc_key === doc.doc_key)
    return !entry || entry.document_id !== doc.id || entry.accepted_at === null
  })
}

/** True when the person agreed to an earlier version of this document. */
export function isUpdatedSinceAgreed(entry: LegalStatusEntry | undefined | null): boolean {
  return !!entry && entry.accepted_at === null && entry.last_accepted_version !== null
}

/** The portal's words for an accept_legal_documents() refusal. */
export function legalErrorMessage(error: unknown): string {
  const message = (error as { message?: string } | null)?.message ?? ''
  if (/legal_document_not_current/.test(message)) {
    return 'These documents were updated a moment ago. Read the current version below, then agree again.'
  }
  if (/inactive_profile/.test(message)) return 'This account has been deactivated. Ask your admin.'
  if (/legal_acceptance_in_portal_only/.test(message)) {
    return 'Only you can agree, here in the portal.'
  }
  if (/fetch|network|timeout|load failed|offline/i.test(message)) {
    return 'No connection. Check your signal and try again.'
  }
  return 'That did not go through. Try again, or ask your admin if it keeps happening.'
}

