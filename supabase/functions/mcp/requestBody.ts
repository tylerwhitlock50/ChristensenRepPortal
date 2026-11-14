/*============================================================================
  mcp/requestBody.ts — the request body, read with a size cap.

  attach_order_document and create_order_draft take a file inline (5 MB
  decoded, MCP_INLINE_MAX_BYTES: about 6.7 MB as base64), so a body is no
  longer always small. index.ts reads it through readBodyCapped instead of
  req.json(): a body over MAX_BODY_BYTES is refused with 413 without being
  buffered whole, whether or not it declares a Content-Length (a chunked
  body has none). The cap is for the whole HTTP body, which may be a JSON-RPC
  batch; the 5 MB limit is per call, and stays well under it so a 413 (a
  transport error the model may not see as a tool result) is reached only by
  abuse.
============================================================================*/

/** 5 MB decoded ≈ 6.7 MB of base64, plus the JSON-RPC envelope. */
export const MAX_BODY_BYTES = 8 * 1024 * 1024

export const BODY_TOO_LARGE_MESSAGE =
  'Request body is over 8 MB. Send files of 5 MB or less inline, or call attach_order_document ' +
  'without content for an upload URL.'

/** A declared Content-Length over the cap (a missing or bad header is not). */
export function declaredTooLarge(req: Request, maxBytes = MAX_BODY_BYTES): boolean {
  const declared = Number(req.headers.get('content-length') ?? '')
  return Number.isFinite(declared) && declared > maxBytes
}

/**
 * The body as UTF-8 text, or null once it passes `maxBytes` (the rest is
 * not read). An empty body is ''.
 */
export async function readBodyCapped(req: Request, maxBytes = MAX_BODY_BYTES): Promise<string | null> {
  if (!req.body) return ''
  const reader = req.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > maxBytes) {
      await reader.cancel().catch(() => {})
      return null
    }
    chunks.push(value)
  }
  const all = new Uint8Array(total)
  let at = 0
  for (const c of chunks) {
    all.set(c, at)
    at += c.byteLength
  }
  return new TextDecoder().decode(all)
}
