/*============================================================================
  mcp/legal.ts — Claude reads nothing for someone who has not agreed to the
  portal's Terms of Use and Privacy Policy.

  The portal has two doors: the SPA, whose router guard sends a signed-in
  person to the agreement screen until they have agreed to the current
  version of both documents, and this endpoint. Without this check a rep who
  connected Claude last month would go on reading their book through it
  after a new version was published, without ever seeing it.

  The question is asked of the database as the caller (their own minted
  JWT, the same legal_status() the SPA reads, migration 20261124090000), once
  per HTTP request, and only for tools/call: initialize and tools/list still
  answer, so the connector stays connected and the person is told what to do
  the moment they ask for something.

  There is deliberately no tool to agree. accept_legal_documents() refuses an
  MCP session outright: only the person, in the portal.
============================================================================*/

export type LegalGate = { ok: true } | { ok: false; message: string }

/** What the person is told, through Claude, until they have agreed. */
export function legalRequiredMessage(portalUrl: string): string {
  const where = portalUrl ? `the Rep Portal (${portalUrl})` : 'the Rep Portal'
  return (
    `Before Claude can use the portal for you, open ${where} and read and agree to ` +
    'the current Terms of Use and Privacy Policy. You are asked as soon as you open it. ' +
    'Claude cannot agree for you. Once you have agreed, ask again.'
  )
}

export const LEGAL_CHECK_FAILED_MESSAGE =
  "Could not check whether you have agreed to the portal's Terms of Use and Privacy Policy. " +
  'Try again in a moment.'

/**
 * legal_status()'s answer → open or not. Open only on an unambiguous yes:
 * all_accepted true AND every listed document carries an accepted_at.
 */
export function legalGateFrom(data: unknown, portalUrl = ''): LegalGate {
  if (data && typeof data === 'object') {
    const docs = (data as { documents?: unknown }).documents
    const all = (data as { all_accepted?: unknown }).all_accepted
    if (
      all === true &&
      Array.isArray(docs) &&
      docs.every((d) => !!d && typeof d === 'object' && typeof (d as { accepted_at?: unknown }).accepted_at === 'string')
    ) {
      return { ok: true }
    }
  }
  return { ok: false, message: legalRequiredMessage(portalUrl) }
}

/**
 * A database without migration 20261124090000 has nothing to agree to: the
 * function ITSELF is missing. PostgREST says so with PGRST202 ("Could not
 * find the function public.legal_status … in the schema cache"), or, with a
 * stale schema cache right after a drop, Postgres says 42883 naming
 * legal_status(). Anything else — a 42883 for a function legal_status()
 * calls, a missing column or table inside it — is a broken gate, not an
 * absent one, and fails closed.
 */
export function isMissingLegalFunction(error: { code?: string; message?: string } | null): boolean {
  if (!error) return false
  const message = error.message ?? ''
  if (error.code === 'PGRST202') return !message || /\blegal_status\b/i.test(message)
  if (error.code === '42883') return /^function (public\.)?legal_status\(\) does not exist/i.test(message)
  return false
}

interface RpcCapable {
  rpc(fn: string, args?: Record<string, unknown>): PromiseLike<{
    data: unknown
    error: { code?: string; message?: string } | null
  }>
}

/** Ask the database, as the caller. Never throws. */
export async function readLegalGate(db: RpcCapable, portalUrl = ''): Promise<LegalGate> {
  try {
    const { data, error } = await db.rpc('legal_status')
    if (error) {
      if (isMissingLegalFunction(error)) {
        // Open, and said so where an operator will see it.
        console.warn('mcp legal gate OPEN: legal_status() is not in this database', error)
        return { ok: true }
      }
      console.error('mcp legal_status failed', error)
      return { ok: false, message: LEGAL_CHECK_FAILED_MESSAGE }
    }
    return legalGateFrom(data, portalUrl)
  } catch (error) {
    console.error('mcp legal_status threw', error)
    return { ok: false, message: LEGAL_CHECK_FAILED_MESSAGE }
  }
}
