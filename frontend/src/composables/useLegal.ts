import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { fetchAllRows } from '@/lib/fetchAll'
import { parseLegalDocuments, type LegalDocKey, type LegalDocument } from '@/lib/legal'

/** 20261124090000 lands after database.types.ts was last generated. */
const db = supabase as unknown as SupabaseClient

/**
 * The Terms of Use and Privacy Policy in force, full text. Readable signed
 * out (the public /terms and /privacy pages) as well as signed in.
 */
export function useLegalDocuments(opts: { forAgreement?: boolean } = {}) {
  return useQuery({
    queryKey: qk.legal.current(),
    queryFn: async (): Promise<LegalDocument[]> => {
      const { data, error } = await db.rpc('legal_current_documents')
      if (error) throw error
      return parseLegalDocuments(data)
    },
    // A new version is a migration, not a minute-by-minute change.
    staleTime: 5 * 60_000,
    // The agreement screen reads the text fresh when it opens (never from a
    // copy another page cached), and does not swap it under the person's
    // eyes on a refocus: a version published meanwhile comes back as a
    // "not current" refusal, which reloads it and asks again.
    ...(opts.forAgreement
      ? { refetchOnMount: 'always' as const, refetchOnWindowFocus: false, refetchOnReconnect: false }
      : {}),
  })
}

/* ---- Admin › Users ------------------------------------------------------ */

export interface AdminLegalRow {
  user_id: string
  all_accepted: boolean
  /** When the last of the current documents was agreed to (all agreed only). */
  accepted_at: string | null
  /** doc_keys still outstanding for the current versions. */
  pending: LegalDocKey[]
  /** The newest agreement to any version, current or not. */
  last_accepted_at: string | null
}

/** admin_legal_status(): one row per profile. Empty for a non-admin. */
export function useAdminLegalStatus() {
  return useQuery({
    queryKey: qk.admin.legalStatus(),
    queryFn: async (): Promise<AdminLegalRow[]> => {
      const { data, error } = await db.rpc('admin_legal_status')
      if (error) throw error
      return ((data ?? []) as AdminLegalRow[]).map((r) => ({
        ...r,
        pending: (r.pending ?? []).filter((k): k is LegalDocKey => k === 'terms' || k === 'privacy'),
      }))
    },
  })
}

/** A row of public.legal_acceptances: the evidence, for the admin's download. */
export interface LegalAcceptanceRow {
  id: number
  user_id: string | null
  document_id: number
  doc_key: LegalDocKey
  version: string
  content_sha256: string
  accepted_at: string
  full_name: string | null
  email: string | null
  role: string | null
  ip_address: string | null
  user_agent: string | null
}

/**
 * Every agreement on record, newest first (admins read all rows; RLS). On
 * demand from the Users page's download, not a query: it is only ever
 * wanted as a file.
 */
export async function fetchLegalAcceptanceLog(): Promise<LegalAcceptanceRow[]> {
  // Paged oldest id first: the table is append-only, so an agreement made
  // while this runs lands after every window already worked out, and no
  // row shifts into or out of one (newest-first paging would duplicate one
  // and drop the oldest). Newest first again for the file, one row per id.
  const rows = await fetchAllRows<LegalAcceptanceRow>((from, to) =>
    db
      .from('legal_acceptances')
      .select(
        'id, user_id, document_id, doc_key, version, content_sha256, accepted_at, full_name, email, role, ip_address, user_agent',
        { count: 'exact' },
      )
      .order('id', { ascending: true })
      .range(from, to),
  )
  return [...new Map(rows.map((r) => [r.id, r])).values()].sort(
    (a, b) => b.accepted_at.localeCompare(a.accepted_at) || b.id - a.id,
  )
}
