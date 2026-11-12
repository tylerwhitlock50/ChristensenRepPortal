/*============================================================================
  orderDocuments.test.ts — the MCP server names and types order documents
  exactly as the portal does.

      deno test --allow-env --allow-net --allow-read supabase/functions/mcp/

  mcp/orderDocuments.ts is a copy of the pure rules in
  frontend/src/lib/orderDocuments.ts (see its header). This imports both and
  runs one shared table of file names through each: a difference means
  someone edited one and not the other. The portal's own suite
  (frontend/tests/unit/orderDocuments.test.ts) pins the same answers.
============================================================================*/

import * as copy from './orderDocuments.ts'
import * as portal from '../../../frontend/src/lib/orderDocuments.ts'

function eq(got: unknown, want: unknown, what: string): void {
  const g = JSON.stringify(got)
  const w = JSON.stringify(want)
  if (g !== w) throw new Error(`FAILED: ${what}\n  got:  ${g}\n  want: ${w}`)
}

/** input → the stored name both sides must produce. */
export const DOCUMENT_NAME_CASES: ReadonlyArray<readonly [string, string, string]> = [
  ['a clean name is kept', 'PO-4471_rev2.pdf', 'PO-4471_rev2.pdf'],
  ['spaces and symbols become one underscore', 'PO #4471  (signed).pdf', 'PO_4471_signed.pdf'],
  ['slashes cannot make a folder', '../../etc/passwd', 'etc_passwd'],
  ['a backslash path is flattened', 'C:\\Users\\me\\PO.pdf', 'C_Users_me_PO.pdf'],
  ['accents fold to letters', 'Commandé façade.pdf', 'Commande_facade.pdf'],
  ['an accent folds, a letter with no plain form is one _', 'größe.xlsx', 'gro_e.xlsx'],
  ['a non-Latin name keeps its extension', '注文書.pdf', 'file.pdf'],
  ['a Cyrillic name keeps its extension', 'заказ 17.xlsx', '17.xlsx'],
  ['a dot-leading name keeps its extension', '.pdf.pdf', 'pdf.pdf'],
  ['a dot file alone is a name, not an extension', '.pdf', 'pdf'],
  ['leading dots and dashes go', '.-draft.pdf', 'draft.pdf'],
  ['a mid-name run of dots and underscores is one dot', 'a_._.b.pdf', 'a.b.pdf'],
  ['a symbol stuck to the extension is not an extension', 'po.pdf#1', 'po.pdf_1'],
  ['repeated dots collapse', 'a..b...pdf', 'a.b.pdf'],
  ['a space before the extension does not break it', 'PO .pdf', 'PO.pdf'],
  ['an empty name is still a name', '   ', 'file'],
  ['only symbols is still a name', '###', 'file'],
  ['case is kept', 'Signed PO.PDF', 'Signed_PO.PDF'],
  ['an email keeps its extension', 'RE: PO 197065.msg', 'RE_PO_197065.msg'],
]

Deno.test('document names: the shared table, both sides', () => {
  for (const [what, input, want] of DOCUMENT_NAME_CASES) {
    eq(copy.sanitizeDocumentName(input), want, `MCP: ${what}`)
    eq(portal.sanitizeDocumentName(input), want, `portal: ${what}`)
  }
})

Deno.test('document names: long names are cut the same way, extension kept', () => {
  for (const input of [`${'a'.repeat(300)}.xlsx`, 'b'.repeat(300), `${'é'.repeat(120)}.pdf`, `${'x '.repeat(80)}.docx`]) {
    const mine = copy.sanitizeDocumentName(input)
    eq(mine, portal.sanitizeDocumentName(input), `same cut for ${input.slice(0, 12)}…`)
    if (mine.length > 100) throw new Error(`FAILED: ${mine} is over 100 characters`)
  }
  const long = copy.sanitizeDocumentName(`${'a'.repeat(300)}.xlsx`)
  eq([long.length, long.endsWith('.xlsx')], [100, true], 'cut to 100, extension kept')
})

Deno.test('document types: the same table, the same extension rule', () => {
  eq(copy.ORDER_DOCUMENT_TYPES, portal.ORDER_DOCUMENT_TYPES, 'extension → content type')
  for (const name of ['PO 4471.PDF', 'order.v2.final.xlsx', 'Scan', '.pdf', 'file.', '12/1700000000000-a.b/readme', 'x.HEIC']) {
    eq(copy.fileExtension(name), portal.fileExtension(name), `extension of ${name}`)
  }
  eq(copy.ORDER_DOCUMENT_TYPES[copy.fileExtension('PO 197065.msg')], 'application/vnd.ms-outlook', '.msg')
  eq(copy.ORDER_DOCUMENT_TYPES[copy.fileExtension('scan.tif')], undefined, '.tif is not taken')
})

Deno.test('document paths: <order id>/<epoch ms>-<name>, read back the same way', () => {
  for (const [id, name] of [[8123, 'PO #4471.pdf'], [42, 'a/b/c.pdf'], [7, '注文書.pdf']] as const) {
    eq(copy.orderDocumentPath(id, name, 1763000000000), portal.orderDocumentPath(id, name, 1763000000000), `path ${id} ${name}`)
  }
  eq(copy.orderDocumentPath(8123, 'PO #4471.pdf', 1763000000000), '8123/1763000000000-PO_4471.pdf', 'the shape')
  for (const bad of [0, -3, 1.5]) {
    let threw = false
    try {
      copy.orderDocumentPath(bad, 'x.pdf')
    } catch {
      threw = true
    }
    eq(threw, true, `no path for order id ${bad}`)
  }
  for (const object of ['1763000000000-PO_4471.pdf', '8123/1763000000000-PO_4471.pdf', '2024-report.pdf', '1700000000-x.pdf']) {
    eq(copy.documentDisplayName(object), portal.documentDisplayName(object), `display name of ${object}`)
  }
  eq(copy.documentDisplayName('8123/1763000000000-Signed_PO.pdf'), 'Signed_PO.pdf', 'stamp and folder dropped')
})
