import { computed, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import {
  ORDER_DOCUMENTS_BUCKET,
  ORDER_DOCUMENT_URL_SECONDS,
  documentErrorText,
  opensInBrowser,
  orderDocumentFolder,
  orderDocumentPath,
  toOrderDocuments,
  validateDocumentFile,
  type OrderDocument,
} from '@/lib/orderDocuments'

/**
 * An order's documents: the files under `<order id>/` in the private
 * `order-documents` bucket (20261113090000). No table — the bucket listing
 * is the list — and no Edge Function: every call goes straight to Storage
 * with the signed-in user's JWT, exactly like account photos (lib/photos.ts)
 * and the price sheets (usePriceListFiles.ts). Storage RLS is the boundary:
 * whoever can read the order can list, open and add; removing is the
 * uploader, an admin or inside sales. The naming and file rules are in
 * lib/orderDocuments.ts.
 */

const bucket = () => supabase.storage.from(ORDER_DOCUMENTS_BUCKET)

function isOrderId(id: number): boolean {
  return Number.isSafeInteger(id) && id > 0
}

/** The order's documents, newest first. */
export function useOrderDocuments(orderId: MaybeRef<number>) {
  return useQuery({
    queryKey: computed(() => qk.orders.documents(unref(orderId))),
    enabled: computed(() => isOrderId(unref(orderId))),
    queryFn: async (): Promise<OrderDocument[]> => {
      const id = unref(orderId)
      const { data, error } = await bucket().list(orderDocumentFolder(id), {
        // An order has a handful; this is the ceiling, not a page size.
        limit: 500,
        sortBy: { column: 'created_at', order: 'desc' },
      })
      if (error) throw error
      return toOrderDocuments(id, data ?? [])
    },
  })
}

function useInvalidateDocuments() {
  const qc = useQueryClient()
  return (orderId: number) =>
    qc.invalidateQueries({ queryKey: qk.orders.documents(orderId) })
}

/**
 * Add one file to an order. Checked here before it leaves the device (size,
 * type), then by the bucket. `at` is the timestamp for the stored name: the
 * card numbers a batch so two files dropped together never share one.
 */
export function useUploadOrderDocument() {
  const invalidate = useInvalidateDocuments()
  return useMutation({
    mutationFn: async (input: { orderId: number; file: File; at?: number }) => {
      const check = validateDocumentFile(input.file)
      if (!check.ok) throw new Error(check.error)
      const path = orderDocumentPath(input.orderId, check.fileName, input.at)

      // storage-js sends a File as a multipart part, and the part's own type
      // is what Storage records and holds against the bucket's allowed
      // types; the contentType option only reaches a non-Blob body. A browser
      // reports no type at all for .msg and .eml, so the body is re-typed
      // (slice copies nothing) whenever it disagrees with what we decided.
      const body =
        input.file.type === check.contentType
          ? input.file
          : input.file.slice(0, input.file.size, check.contentType)

      const { error } = await bucket().upload(path, body, {
        contentType: check.contentType,
        upsert: false,
        cacheControl: '3600',
      })
      if (error) throw new Error(documentErrorText(error, input.file.name))
      return path
    },
    // Settled, not success: a batch that fails halfway still added files.
    onSettled: (_data, _error, input) => invalidate(input.orderId),
  })
}

/**
 * Remove one document. Storage RLS decides (the uploader, an admin, inside
 * sales), and a remove it filters out is not an error, it just removes
 * nothing — hence the check.
 */
export function useRemoveOrderDocument() {
  const invalidate = useInvalidateDocuments()
  return useMutation({
    mutationFn: async (input: { orderId: number; document: OrderDocument }) => {
      const { data, error } = await bucket().remove([input.document.path])
      if (error) throw new Error(documentErrorText(error, input.document.displayName))
      if (!data?.length) {
        throw new Error(
          `${input.document.displayName} wasn't removed. Only the person who added it, an admin or inside sales can remove a document.`,
        )
      }
    },
    onSettled: (_data, _error, input) => invalidate(input.orderId),
  })
}

/**
 * A link to one document, good for a few minutes. The bucket is private:
 * `getPublicUrl` 400s, as it does for account photos. A type the browser can
 * only save comes back as a download under its own name, not the stored one.
 */
export async function orderDocumentUrl(doc: OrderDocument): Promise<string> {
  const { data, error } = await bucket().createSignedUrl(
    doc.path,
    ORDER_DOCUMENT_URL_SECONDS,
    opensInBrowser(doc.name) ? undefined : { download: doc.displayName },
  )
  if (error) throw new Error(documentErrorText(error, doc.displayName))
  return data.signedUrl
}

/**
 * Open a document: in a new tab when the browser can show it (PDF, picture,
 * text), as a download otherwise. Call it straight from the click.
 *
 * The tab is opened BEFORE the link is fetched. A window.open() after an
 * await is no longer "in" the tap, and Safari — every iPhone — blocks it as
 * a pop-up. So an empty tab opens now and is pointed at the document when
 * its link arrives; if even that was blocked, this tab goes there instead.
 */
export async function openOrderDocument(doc: OrderDocument): Promise<void> {
  if (!opensInBrowser(doc.name)) {
    const url = await orderDocumentUrl(doc)
    // Same move as downloadPriceListFile: the link answers with
    // Content-Disposition: attachment, so this saves the file and the page
    // stays where it is.
    const link = document.createElement('a')
    link.href = url
    link.rel = 'noopener'
    link.style.display = 'none'
    document.body.appendChild(link)
    link.click()
    link.remove()
    return
  }

  const tab = window.open('', '_blank')
  // The document must not be able to reach back into the portal.
  if (tab) tab.opener = null
  try {
    const url = await orderDocumentUrl(doc)
    if (tab && !tab.closed) tab.location.replace(url)
    else window.location.assign(url)
  } catch (error) {
    tab?.close()
    throw error
  }
}
