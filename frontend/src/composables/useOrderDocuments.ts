import { computed, reactive, ref, unref, type MaybeRef } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { useSessionStore } from '@/stores/session'
import {
  ORDER_DOCUMENTS_BUCKET,
  ORDER_DOCUMENT_URL_SECONDS,
  documentErrorText,
  isBucketMissing,
  opensInBrowser,
  orderDocumentFolder,
  orderDocumentPath,
  toOrderDocuments,
  validateDocumentFile,
  type DocumentAction,
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
type DocumentsBucket = ReturnType<typeof bucket>

function isOrderId(id: number): boolean {
  return Number.isSafeInteger(id) && id > 0
}

/**
 * True once Storage has answered an upload, a sign or a remove with
 * 'Bucket not found': a database without 20261113090000. Learned from a
 * failure that actually happens, because a listing never says so (it
 * answers an unknown bucket with an empty list). The bucket is one for the
 * whole app, so this is too; a reload asks again.
 */
export const orderDocumentsUnavailable = ref(false)

/** Storage's refusal as the Error a screen shows, noting a missing bucket on the way. */
function storageFailure(error: unknown, fileName: string, action: DocumentAction): Error {
  if (isBucketMissing(error)) orderDocumentsUnavailable.value = true
  return new Error(documentErrorText(error, fileName, action))
}

/* ---- what this browser uploaded ------------------------------------------
   Storage lets whoever added a file remove it, but a listing does not say
   who that was. The paths this browser uploaded are remembered, per order
   and with the user they were uploaded for, until the page is reloaded:
   that is what lets the card offer a rep Remove on the PO they attached by
   mistake a minute ago (canOfferRemove in lib/orderDocuments.ts).
--------------------------------------------------------------------------- */

/** order id → (object path → id of the user who uploaded it). */
const uploadedHere = reactive(new Map<number, Map<string, string>>())

export function rememberUploadedDocument(orderId: number, path: string, userId: string): void {
  const paths = uploadedHere.get(orderId)
  if (paths) paths.set(path, userId)
  else uploadedHere.set(orderId, new Map([[path, userId]]))
}

/** Whether `userId` uploaded this object from this browser since the page loaded. */
export function wasUploadedHere(
  orderId: number,
  path: string,
  userId: string | null | undefined,
): boolean {
  return !!userId && uploadedHere.get(orderId)?.get(path) === userId
}

export function forgetUploadedDocument(orderId: number, path: string): void {
  uploadedHere.get(orderId)?.delete(path)
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
      if (error) {
        // Storage does not say this to a listing today; if it ever does, the
        // card can stop offering uploads before the first one fails.
        if (isBucketMissing(error)) orderDocumentsUnavailable.value = true
        throw error
      }
      return toOrderDocuments(id, data ?? [])
    },
  })
}

function useInvalidateDocuments() {
  const qc = useQueryClient()
  return (orderId: number) =>
    qc.invalidateQueries({ queryKey: qk.orders.documents(orderId) })
}

export interface UploadOrderDocumentInput {
  orderId: number
  file: File
  /** The timestamp for the stored name (the card numbers a batch). */
  at?: number
  /** Who is uploading: remembered with the path (wasUploadedHere). */
  uploaderId?: string | null
}

/**
 * Add one file to an order, and say where it went. Checked here before it
 * leaves the device (size, type), then by the bucket. The Storage call
 * itself, apart from useMutation so it can be tested against a stub bucket.
 */
export async function uploadOrderDocument(
  target: Pick<DocumentsBucket, 'upload'>,
  input: UploadOrderDocumentInput,
): Promise<string> {
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

  let error: unknown
  try {
    ;({ error } = await target.upload(path, body, {
      contentType: check.contentType,
      upsert: false,
      cacheControl: '3600',
    }))
  } catch (thrown) {
    error = thrown
  }
  if (error) throw storageFailure(error, input.file.name, 'upload')
  if (input.uploaderId) rememberUploadedDocument(input.orderId, path, input.uploaderId)
  return path
}

/**
 * Remove one document. Storage RLS decides (the uploader, an admin, inside
 * sales), and a remove it filters out is not an error, it just removes
 * nothing (an empty list back) — hence the check.
 */
export async function removeOrderDocument(
  target: Pick<DocumentsBucket, 'remove'>,
  input: { orderId: number; document: OrderDocument },
): Promise<void> {
  const name = input.document.displayName
  let result: Awaited<ReturnType<DocumentsBucket['remove']>>
  try {
    result = await target.remove([input.document.path])
  } catch (thrown) {
    throw storageFailure(thrown, name, 'remove')
  }
  if (result.error) throw storageFailure(result.error, name, 'remove')
  if (!result.data?.length) {
    throw new Error(
      `${name} wasn't removed. Only the person who added it, an admin or inside sales can remove a document.`,
    )
  }
  forgetUploadedDocument(input.orderId, input.document.path)
}

/** Add one file to an order (uploadOrderDocument), as the signed-in user. */
export function useUploadOrderDocument() {
  const invalidate = useInvalidateDocuments()
  const session = useSessionStore()
  return useMutation({
    mutationFn: (input: { orderId: number; file: File; at?: number }) =>
      uploadOrderDocument(bucket(), { ...input, uploaderId: session.user?.id ?? null }),
    // Settled, not success: a batch that fails halfway still added files.
    // Not awaited: mutateAsync would wait for the list to come back before
    // the card sends the next file, and Storage calls have no read timeout,
    // so one stalled refresh would hold the rest of the batch for good.
    onSettled: (_data, _error, input) => {
      void invalidate(input.orderId)
    },
  })
}

/** Remove one document (removeOrderDocument). */
export function useRemoveOrderDocument() {
  const qc = useQueryClient()
  const invalidate = useInvalidateDocuments()
  return useMutation({
    mutationFn: (input: { orderId: number; document: OrderDocument }) =>
      removeOrderDocument(bucket(), input),
    // Off the list at once, so the card can move focus to the row after it;
    // the refresh below confirms it without anyone waiting on it.
    onSuccess: (_data, input) => {
      qc.setQueryData<OrderDocument[]>(qk.orders.documents(input.orderId), (rows) =>
        rows?.filter((d) => d.path !== input.document.path),
      )
    },
    onSettled: (_data, _error, input) => {
      void invalidate(input.orderId)
    },
  })
}

/**
 * A link to one document, good for a few minutes. The bucket is private:
 * `getPublicUrl` 400s, as it does for account photos. A type the browser can
 * only save comes back as a download under its own name, not the stored one.
 */
export async function orderDocumentUrl(doc: OrderDocument): Promise<string> {
  let result: Awaited<ReturnType<DocumentsBucket['createSignedUrl']>>
  try {
    result = await bucket().createSignedUrl(
      doc.path,
      ORDER_DOCUMENT_URL_SECONDS,
      opensInBrowser(doc.name) ? undefined : { download: doc.displayName },
    )
  } catch (thrown) {
    throw storageFailure(thrown, doc.displayName, 'open')
  }
  if (result.error) throw storageFailure(result.error, doc.displayName, 'open')
  return result.data.signedUrl
}

/**
 * How opening went. `opened: false` means the browser would not open a tab
 * (a pop-up blocker, an in-app browser without window.open): the card shows
 * `url` as a link for the person to tap, which no blocker stops. The portal
 * tab itself is never sent to the document — it may be holding an unsaved
 * draft, and a router guard cannot see a full-page navigation.
 */
export type OpenedDocument = { opened: true } | { opened: false; url: string }

/**
 * How long a pre-opened tab may stay blank before it is taken to have
 * become a download. A tab still waiting for Storage's first reply also
 * reads about:blank, so this is long enough for a slow connection to start
 * showing a PDF (the first bytes, not the whole file); an empty tab left a
 * little longer costs far less than a document closed while it loads.
 */
export const BLANK_TAB_GRACE_MS = 20_000

type MatchMedia = (query: string) => Pick<MediaQueryList, 'matches'>

/**
 * Whether a blank tab should be closed at all on this device: only one with
 * a mouse or trackpad and no touch screen. The setting that turns a PDF into
 * a download (Chrome or Edge "download PDFs", Firefox "save") is a desktop
 * browser's; a phone or tablet, where reps open documents on a weak signal,
 * never has it, so a tab there that is still blank is still loading and is
 * left alone. No matchMedia: left alone too.
 */
export function blankTabCloserApplies(
  media: MatchMedia | null = typeof window !== 'undefined' && window.matchMedia
    ? (q) => window.matchMedia(q)
    : null,
): boolean {
  if (!media) return false
  return media('(pointer: fine)').matches && !media('(any-pointer: coarse)').matches
}

/**
 * Close a tab that was pointed at a document but is still about:blank a
 * while later: the browser saved the file instead of showing it (Chrome or
 * Edge set to download PDFs, Firefox set to save), and every tap would
 * otherwise leave one more empty tab. A tab showing the document is on
 * Storage's origin, so reading its location throws, and it is left be.
 * Only where blankTabCloserApplies().
 */
export function closeIfStillBlank(
  tab: Pick<Window, 'closed' | 'close' | 'location'>,
  wait: number = BLANK_TAB_GRACE_MS,
  schedule: (run: () => void, ms: number) => unknown = (run, ms) => setTimeout(run, ms),
): void {
  schedule(() => {
    try {
      if (!tab.closed && tab.location.href === 'about:blank') tab.close()
    } catch {
      /* cross-origin: it is showing the document */
    }
  }, wait)
}

/**
 * Whether a click now still counts as the person's tap. A link opened in a
 * new tab after an await is a pop-up unless it does; browsers without the
 * API are given the benefit of the doubt.
 */
function stillInTheTap(): boolean {
  const activation = (navigator as { userActivation?: { isActive: boolean } }).userActivation
  return activation ? activation.isActive : true
}

/**
 * Open a document: in a new tab when the browser can show it (PDF, picture,
 * text), as a download otherwise. Call it straight from the click.
 *
 * The tab is opened BEFORE the link is fetched. A window.open() after an
 * await is no longer "in" the tap, and Safari — every iPhone — blocks it as
 * a pop-up. So an empty tab opens now and is pointed at the document when
 * its link arrives. If no tab could be opened, the link comes back for the
 * card to show (OpenedDocument).
 */
export async function openOrderDocument(doc: OrderDocument): Promise<OpenedDocument> {
  if (!opensInBrowser(doc.name)) {
    const url = await orderDocumentUrl(doc)
    if (!stillInTheTap()) return { opened: false, url }
    // The link answers with Content-Disposition: attachment, so this saves
    // the file. In a new tab, not this one: if the connection drops between
    // the sign and the download, the browser's error page lands there
    // rather than in place of the portal.
    const link = document.createElement('a')
    link.href = url
    link.target = '_blank'
    link.rel = 'noopener'
    link.style.display = 'none'
    document.body.appendChild(link)
    link.click()
    link.remove()
    return { opened: true }
  }

  const tab = window.open('', '_blank')
  // The document must not be able to reach back into the portal.
  if (tab) tab.opener = null
  try {
    const url = await orderDocumentUrl(doc)
    if (!tab || tab.closed) return { opened: false, url }
    tab.location.replace(url)
    if (blankTabCloserApplies()) closeIfStillBlank(tab)
    return { opened: true }
  } catch (error) {
    tab?.close()
    throw error
  }
}
