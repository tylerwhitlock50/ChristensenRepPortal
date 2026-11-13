/*============================================================================
  orderDocumentsInline.test.ts — the MCP-only inline upload rules in
  orderDocuments.ts (base64, the magic-byte sniff, one document input), and
  requestBody.ts's size cap. Pure: no network.

      deno test --allow-env supabase/functions/mcp/
============================================================================*/

import {
  contentMismatch,
  decodeBase64Strict,
  decodeDocumentInput,
  DocumentContentError,
  MCP_INLINE_MAX_BYTES,
} from './orderDocuments.ts'
import { declaredTooLarge, readBodyCapped } from './requestBody.ts'

function assert(ok: unknown, what: string): void {
  if (!ok) throw new Error(`FAILED: ${what}`)
}

function eq(got: unknown, want: unknown, what: string): void {
  assert(JSON.stringify(got) === JSON.stringify(want), `${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`)
}

function codeOf(fn: () => unknown): string | null {
  try {
    fn()
  } catch (e) {
    return e instanceof DocumentContentError ? e.code : `other: ${e}`
  }
  return null
}

async function codeOfAsync(p: Promise<unknown>): Promise<string | null> {
  try {
    await p
  } catch (e) {
    return e instanceof DocumentContentError ? e.code : `other: ${e}`
  }
  return null
}

const b64 = (bytes: Uint8Array) => btoa(String.fromCharCode(...bytes))
const bytesOf = (...xs: number[]) => new Uint8Array(xs)
const text = (s: string) => new TextEncoder().encode(s)

Deno.test('decodeBase64Strict: round trip, data: prefix, newlines, url-safe without padding', () => {
  const raw = crypto.getRandomValues(new Uint8Array(1024))
  const std = b64(raw)
  eq([...decodeBase64Strict(std, 2048)], [...raw], 'round trip')
  eq([...decodeBase64Strict(`data:application/pdf;base64,${std}`, 2048)], [...raw], 'data: prefix')
  eq([...decodeBase64Strict(std.replace(/(.{76})/g, '$1\r\n'), 2048)], [...raw], 'wrapped lines')
  const url = std.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
  eq([...decodeBase64Strict(url, 2048)], [...raw], 'url-safe, unpadded')
})

Deno.test('decodeBase64Strict: refusals, and the size is checked before decoding', () => {
  eq(codeOf(() => decodeBase64Strict('abc!', 100)), 'invalid_base64', 'a bad character')
  eq(codeOf(() => decodeBase64Strict('abcde', 100)), 'invalid_base64', 'length % 4 == 1')
  eq(codeOf(() => decodeBase64Strict('ab=c', 100)), 'invalid_base64', 'padding in the middle')
  eq(codeOf(() => decodeBase64Strict('', 100)), 'document_empty', 'empty')
  eq(codeOf(() => decodeBase64Strict('data:text/csv;base64,', 100)), 'document_empty', 'only a prefix')
  // Not decodable at all, but over the cap: refused as too large, so atob never ran.
  const huge = '!'.repeat(Math.ceil(((MCP_INLINE_MAX_BYTES + 1) * 4) / 3) + 4)
  const t0 = performance.now()
  eq(codeOf(() => decodeBase64Strict(huge, MCP_INLINE_MAX_BYTES)), 'document_too_large', 'over the cap')
  assert(performance.now() - t0 < 500, 'refused without decoding')
  eq(decodeBase64Strict('YWJj', 3).length, 3, 'exactly at the cap is fine')
  eq(codeOf(() => decodeBase64Strict('YWJjZA==', 3)), 'document_too_large', 'one byte over')
})

Deno.test('contentMismatch: the bytes are what the extension says', () => {
  const PDF = 'application/pdf'
  const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  const XLS = 'application/vnd.ms-excel'
  const ZIP = bytesOf(0x50, 0x4b, 0x03, 0x04, 0, 0)
  const OLE = bytesOf(0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0)
  const PNG = bytesOf(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0)
  const ftyp = (brand: string) => text(`\0\0\0\x18ftyp${brand}\0\0\0\0`)
  eq(contentMismatch(PDF, text('%PDF-1.7\n...')), null, 'a PDF')
  eq(contentMismatch(PDF, new Uint8Array([...new Uint8Array(500), ...text('%PDF-1.4')])), null, 'PDF header after junk')
  assert(contentMismatch(PDF, PNG), 'a PNG called .pdf')
  eq(contentMismatch('image/png', PNG), null, 'a PNG')
  eq(contentMismatch('image/jpeg', bytesOf(0xff, 0xd8, 0xff, 0xe0)), null, 'a JPEG')
  eq(contentMismatch('image/webp', text('RIFF\0\0\0\0WEBPVP8 ')), null, 'a WebP')
  for (const brand of ['heic', 'heix', 'mif1', 'hevc', 'heim', 'heis', 'hevm', 'hevs', 'hevx']) {
    eq(contentMismatch('image/heic', ftyp(brand)), null, `HEIC brand ${brand}`)
  }
  assert(contentMismatch('image/heic', ftyp('isom')), 'an MP4 is not HEIC')
  eq(contentMismatch(XLSX, ZIP), null, 'a zip as .xlsx')
  assert(/xlsx/.test(String(contentMismatch(XLS, ZIP))), 'a zip as .xls: says to name it .xlsx')
  eq(contentMismatch(XLS, OLE), null, 'OLE as .xls')
  eq(contentMismatch('application/vnd.ms-outlook', OLE), null, 'OLE as .msg')
  assert(contentMismatch('text/csv', bytesOf(0x61, 0, 0x62)), 'a NUL byte in a CSV')
  eq(contentMismatch('text/csv', bytesOf(0xef, 0xbb, 0xbf, 0x61, 0x2c, 0x62)), null, 'a BOM-prefixed CSV')
  eq(contentMismatch('text/csv', bytesOf(0x43, 0x61, 0x66, 0xe9)), null, 'Windows-1252 "Café" is still a CSV')
  eq(contentMismatch('text/csv', bytesOf(0xc3, 0x28)), null, 'invalid UTF-8 is not refused (the portal takes it)')
})

Deno.test('decodeDocumentInput: one document in, checked bytes out', async () => {
  eq(await codeOfAsync(decodeDocumentInput({ file_name: 'po.pdf', content_text: '%PDF' }, 100)), 'invalid_input', 'content_text on a PDF')
  eq(await codeOfAsync(decodeDocumentInput({ file_name: 'po.csv', content_text: 'a', content_base64: 'YQ==' }, 100)),
    'invalid_input', 'both')
  eq(await codeOfAsync(decodeDocumentInput({ file_name: 'po.csv' }, 100)), 'invalid_input', 'neither')
  eq(await codeOfAsync(decodeDocumentInput({ content_text: 'a' }, 100)), 'invalid_input', 'no file name')
  eq(await codeOfAsync(decodeDocumentInput({ file_name: `${'x'.repeat(201)}.csv`, content_text: 'a' }, 100)),
    'invalid_input', 'a file name over 200 characters')
  eq(await codeOfAsync(decodeDocumentInput({ file_name: 'po.csv', content_text: '' }, 100)), 'document_empty', 'empty text')
  eq(await codeOfAsync(decodeDocumentInput({ file_name: 'po.csv', content_text: 'abcd' }, 3)), 'document_too_large',
    'over what is left of the cap')
  try {
    await decodeDocumentInput({ file_name: 'scan.tif', content_base64: 'YQ==' }, 100)
    assert(false, 'a .tif is refused')
  } catch (e) {
    assert(e instanceof DocumentContentError && e.code === 'unsupported_type' && /\.pdf, \.xlsx/.test(e.message), 'lists the types')
  }
  try {
    await decodeDocumentInput({ file_name: 'po.pdf', content_base64: b64(text('<html>')) }, 100)
    assert(false, 'HTML called .pdf is refused')
  } catch (e) {
    assert(e instanceof DocumentContentError && e.code === 'content_mismatch' && /says \.pdf/.test(e.message), 'content_mismatch')
  }

  // The real PO's shape: a header row and ~200 "D" rows, about 50 KB of ASCII.
  const csv = ['H,215647,SPOR SOU1,2026-11-10'].concat(
    Array.from({ length: 200 }, (_, i) => `D,${i + 1},801-${String(10000 + i)}-01,2,CHRIS RIDGELINE FFT 6.5 CRD 22" CARBON BURNT BRONZE LINE ${i}`),
  ).join('\n') + '\n'
  const doc = await decodeDocumentInput({ file_name: 'po215647_926271.csv', content_text: csv }, MCP_INLINE_MAX_BYTES)
  eq([doc.bytes.length, doc.contentType, doc.fileName], [text(csv).length, 'text/csv', 'po215647_926271.csv'], 'UTF-8 bytes, text/csv')
  assert(/^[0-9a-f]{64}$/.test(doc.sha256), 'a sha256')
  const same = await decodeDocumentInput({ file_name: 'po215647_926271.csv', content_base64: b64(text(csv)) }, MCP_INLINE_MAX_BYTES)
  eq(same.sha256, doc.sha256, 'the same bytes as base64 hash the same')
})

Deno.test('requestBody: a declared or streamed body over the cap is refused; a normal one reads', async () => {
  const post = (body: BodyInit, headers: Record<string, string> = {}) =>
    new Request('https://x.test/mcp', { method: 'POST', body, headers })
  assert(declaredTooLarge(post('{}', { 'content-length': '9000000' })), 'declared 9 MB')
  assert(!declaredTooLarge(new Request('https://x.test/mcp', { method: 'POST' })), 'no header is not too large')
  eq(await readBodyCapped(post('{"jsonrpc":"2.0","id":1}'), 1024), '{"jsonrpc":"2.0","id":1}', 'a normal body')
  eq(await readBodyCapped(post('x'.repeat(2048)), 1024), null, 'over the cap')
  // A chunked body (a stream, no length) over the cap.
  let sent = 0
  const stream = new ReadableStream<Uint8Array>({
    pull(c) {
      if (sent >= 10) return c.close()
      sent++
      c.enqueue(new Uint8Array(512))
    },
  })
  eq(await readBodyCapped(post(stream), 1024), null, 'a stream over the cap')
  assert(sent < 10, `stopped reading early (${sent} chunks)`)
  eq(await readBodyCapped(new Request('https://x.test/mcp', { method: 'POST' }), 1024), '', 'no body')
})
