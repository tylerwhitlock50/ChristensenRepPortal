<script lang="ts">
import { reactive } from 'vue'

/* ---- what the card is saying, per order ------------------------------------
   The page reuses this card when the route moves to another order (header
   search, Back), or mounts a fresh one, while a batch keeps going for the
   order it was dropped on. So every line the card shows belongs to one
   order id and is only shown on that order: order B never reads "Uploading
   1 of 1" or "1 document added" about order A. Kept for the module, not the
   instance, so a card mounted again on A mid-batch still shows the batch
   (and still refuses to start a second one beside it).
--------------------------------------------------------------------------- */
interface OrderNotes {
  progress: { index: number; total: number; name: string } | null
  notice: string
  problems: string[]
  /** Files were dropped while a batch was running (and not taken). */
  stillUploading: boolean
  /** No tab could be opened: the document's link, to tap. */
  link: { url: string; name: string } | null
}

const notes = reactive(new Map<number, OrderNotes>())

function notesFor(orderId: number): OrderNotes {
  if (!notes.has(orderId)) {
    notes.set(orderId, {
      progress: null,
      notice: '',
      problems: [],
      stillUploading: false,
      link: null,
    })
  }
  return notes.get(orderId)!
}

/** Done with an order: forget what was said about it, unless its batch is still going. */
function leaveNotes(orderId: number | null | undefined) {
  if (orderId != null && !notes.get(orderId)?.progress) notes.delete(orderId)
}
</script>

<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue'
import { useEventListener } from '@vueuse/core'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import {
  openOrderDocument,
  orderDocumentsUnavailable,
  useOrderDocuments,
  useRemoveOrderDocument,
  useUploadOrderDocument,
  wasUploadedHere,
} from '@/composables/useOrderDocuments'
import {
  ORDER_DOCUMENTS_NOT_SET_UP,
  ORDER_DOCUMENT_ACCEPT,
  ORDER_DOCUMENT_MAX_BYTES,
  ORDER_DOCUMENT_URL_SECONDS,
  canOfferRemove,
  formatFileSize,
  isBucketMissing,
  opensInBrowser,
  validateDocumentFile,
  type OrderDocument,
} from '@/lib/orderDocuments'
import { useSessionStore } from '@/stores/session'
import { shortDate } from '@/lib/format'

/**
 * The files that belong with an order — above all the customer's PO as it
 * arrived (20261113090000). Shown at every status, to everyone who can open
 * the order: the signed PO often turns up after the order was submitted, and
 * inside sales keys from it.
 *
 * Reading is for everyone here. Adding is offered whenever the session can
 * write at all (not while viewing as someone, not offline). Removing follows
 * the bucket's rule as far as the card can know it (canOfferRemove): admins
 * and inside sales on every file, anyone else on the files this browser
 * uploaded for them since the page loaded. A listing does not say who added
 * an older file, so it is not offered on a guess; if the bucket filters a
 * remove out anyway, the card says it wasn't removed.
 *
 * On a database without the bucket the listing still answers (an empty
 * list), so the card learns it from the first upload or open that Storage
 * refuses with 'Bucket not found': the drop zone goes and one line says
 * documents aren't set up yet.
 */
const props = defineProps<{ orderId: number }>()

const session = useSessionStore()
const documents = useOrderDocuments(computed(() => props.orderId))
const upload = useUploadOrderDocument()
const removeDocument = useRemoveOrderDocument()

const rows = computed(() => documents.data.value ?? [])
const unavailable = computed(
  () => orderDocumentsUnavailable.value || isBucketMissing(documents.error.value),
)

const canAdd = computed(() => session.canWrite)
/** Whether files can be dropped or picked right now. */
const dropOpen = computed(() => canAdd.value && !unavailable.value)

function offersRemove(doc: OrderDocument): boolean {
  return canOfferRemove(
    { canWrite: session.canWrite, isAdmin: session.isAdmin, isOrderEntry: session.isOrderEntry },
    wasUploadedHere(props.orderId, doc.path, session.user?.id),
  )
}

const hint = computed(() => {
  if (unavailable.value || documents.data.value === undefined) return undefined
  return rows.value.length === 1 ? '1 file' : `${rows.value.length} files`
})

/** What a row says under the name: "287 KB · Nov 12, 2026". */
function meta(doc: OrderDocument): string {
  return [formatFileSize(doc.size), doc.uploadedAt ? shortDate(doc.uploadedAt) : '']
    .filter(Boolean)
    .join(' · ')
}

/** What the card is saying about the order on screen (module state, above). */
const here = computed(() => notes.get(props.orderId))
const progress = computed(() => here.value?.progress ?? null)

/** Clear what the last action said, before the next one speaks. */
function startOver(n: OrderNotes) {
  if (!n.progress) n.problems = []
  n.notice = ''
  n.link = null
}

/* ---- adding ---------------------------------------------------------------
   One file at a time, in the order given: a phone on LTE sending three scans
   at once finishes none of them. Every file is checked first, so a wrong
   type or a 40 MB scan is named before anything uploads; the rest still go.
--------------------------------------------------------------------------- */
async function addFiles(list: FileList | File[] | null | undefined) {
  const files = Array.from(list ?? [])
  if (files.length === 0 || !dropOpen.value) return
  // Captured once: a batch belongs to the order it was dropped on.
  const orderId = props.orderId
  const n = notesFor(orderId)
  if (n.progress) {
    // A second drop mid-batch is not queued behind it, and must not vanish.
    n.stillUploading = true
    return
  }
  n.problems = []
  n.notice = ''
  n.link = null

  const accepted: File[] = []
  for (const file of files) {
    const check = validateDocumentFile(file)
    if (check.ok) accepted.push(file)
    else n.problems.push(check.error)
  }

  // Stored names start with a timestamp; giving each file in the batch the
  // next millisecond keeps two that sanitize to the same name from colliding.
  const startedAt = Date.now()
  let added = 0
  for (const [i, file] of accepted.entries()) {
    n.progress = { index: i + 1, total: accepted.length, name: file.name }
    try {
      await upload.mutateAsync({ orderId, file, at: startedAt + i })
      added += 1
    } catch (e) {
      // No bucket: the card now says so once, and no other file can go.
      if (orderDocumentsUnavailable.value) break
      n.problems.push((e as Error).message || `${file.name} didn't upload.`)
    }
  }
  n.progress = null
  n.stillUploading = false
  if (added > 0) n.notice = added === 1 ? '1 document added.' : `${added} documents added.`
}

function onPick(event: Event) {
  const input = event.target as HTMLInputElement
  const picked = Array.from(input.files ?? [])
  // Reset so picking the exact same file again still fires `change`.
  input.value = ''
  void addFiles(picked)
}

/* Drag and drop, for a desk: the PO is usually sitting in a downloads folder
   or an email. Anywhere on the card counts as the drop zone. Only file drags
   light it up (not a dragged link or a text selection), and leaving a child
   element is not leaving the card. */
const dragging = ref(false)

function isFileDrag(event: DragEvent): boolean {
  return Array.from(event.dataTransfer?.types ?? []).includes('Files')
}

function onDragOver(event: DragEvent) {
  if (!isFileDrag(event)) return
  event.preventDefault()
  if (!dropOpen.value) {
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'none'
    return
  }
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
  dragging.value = true
}

function onDragLeave(event: DragEvent) {
  const card = event.currentTarget as HTMLElement
  if (event.relatedTarget instanceof Node && card.contains(event.relatedTarget)) return
  dragging.value = false
}

function onDrop(event: DragEvent) {
  if (!isFileDrag(event)) return
  event.preventDefault()
  dragging.value = false
  if (dropOpen.value) void addFiles(event.dataTransfer?.files)
}

/* While the card is on screen it invites dragging, and a file released just
   outside it would be opened by the browser in place of the portal (an
   unsaved draft and all: the router's leave guard never sees it). So a file
   drag anywhere else on the page is refused. The card's own handlers run
   first and mark the event handled. */
useEventListener('dragover', (event: DragEvent) => {
  if (!isFileDrag(event) || event.defaultPrevented) return
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'none'
})
useEventListener('drop', (event: DragEvent) => {
  if (isFileDrag(event) && !event.defaultPrevented) event.preventDefault()
})

// Leaving an order drops what the card said about it, unless its batch is
// still going (that batch's result is waiting for the way back).
watch(
  () => props.orderId,
  (_next, prev) => {
    leaveNotes(prev)
    dragging.value = false
  },
)
onBeforeUnmount(() => leaveNotes(props.orderId))

/* ---- opening and removing ------------------------------------------------ */
const busyPath = ref<string | null>(null)
/** A remove on this order is in flight (the paths start with the order id). */
const removing = computed(() => !!busyPath.value?.startsWith(`${props.orderId}/`))

async function open(doc: OrderDocument) {
  const n = notesFor(props.orderId)
  startOver(n)
  try {
    // Nothing is awaited ahead of this call: openOrderDocument opens its tab
    // first thing, while the browser still counts this as the tap.
    const result = await openOrderDocument(doc)
    if (!result.opened) showLink(n, result.url, doc.displayName)
  } catch (e) {
    if (orderDocumentsUnavailable.value) return
    n.problems = [(e as Error).message || `${doc.displayName} couldn't be opened.`]
  }
}

/** The link Storage signed lasts this long; the line goes with it. */
const linkMinutes = Math.round(ORDER_DOCUMENT_URL_SECONDS / 60)

function showLink(n: OrderNotes, url: string, name: string) {
  const link = { url, name }
  n.link = link
  setTimeout(() => {
    if (n.link?.url === link.url) n.link = null
  }, ORDER_DOCUMENT_URL_SECONDS * 1000)
}

const heading = ref<HTMLElement | null>(null)
const list = ref<HTMLElement | null>(null)

/**
 * After a remove the row and its button are gone; without this, focus falls
 * to the page body and the next Tab starts from the top. The row now in its
 * place (or the last one), else the card's heading.
 */
function focusAfterRemoval(index: number) {
  const items = list.value ? Array.from(list.value.children) : []
  const row = items[Math.min(index, items.length - 1)]
  const target =
    row?.querySelector<HTMLElement>('[data-remove]') ??
    row?.querySelector<HTMLElement>('button') ??
    heading.value
  target?.focus()
}

async function remove(doc: OrderDocument) {
  if (busyPath.value) return
  if (!window.confirm(`Remove ${doc.displayName} from this order? This can't be undone.`)) return
  const orderId = props.orderId
  const index = rows.value.findIndex((d) => d.path === doc.path)
  const n = notesFor(orderId)
  startOver(n)
  busyPath.value = doc.path
  let removed = false
  try {
    await removeDocument.mutateAsync({ orderId, document: doc })
    n.notice = `${doc.displayName} removed.`
    removed = true
  } catch (e) {
    if (!orderDocumentsUnavailable.value) {
      n.problems = [(e as Error).message || `${doc.displayName} wasn't removed.`]
    }
  } finally {
    busyPath.value = null
  }
  if (removed && props.orderId === orderId) {
    await nextTick()
    focusAfterRemoval(Math.max(index, 0))
  }
}
</script>

<template>
  <div @dragenter="onDragOver" @dragover="onDragOver" @dragleave="onDragLeave" @drop="onDrop">
    <AppCard>
      <template #header>
        <!-- Focusable from script only: where focus goes when the last row
             is removed. -->
        <h2 ref="heading" tabindex="-1" class="u-label text-ink">Documents</h2>
        <span v-if="hint" class="font-label text-muted text-xs tracking-[0.08em]">
          {{ hint }}
        </span>
      </template>

      <p v-if="unavailable" class="text-muted text-[14px]">{{ ORDER_DOCUMENTS_NOT_SET_UP }}</p>
      <div
        v-else-if="canAdd"
        class="mb-4 border border-dashed px-4 py-4 text-center"
        :class="dragging ? 'border-ink bg-canvas' : 'border-line-2'"
      >
        <!-- Add: a drop zone at a desk (the whole card takes the drop), the
             picker everywhere (on a phone it offers the camera, the photo
             library and Files). -->
        <p class="text-ink-2 text-[14px]">
          The customer's PO, or anything else that belongs with this order.
        </p>
        <!-- The input is visually hidden, so the ring a keyboard user needs
             is drawn on the label around it. -->
        <label
          class="btn-secondary has-[:focus-visible]:outline-brand mt-3 cursor-pointer has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2"
          :class="progress ? 'pointer-events-none opacity-50' : ''"
        >
          <span>Choose files</span>
          <input
            class="sr-only"
            type="file"
            multiple
            :accept="ORDER_DOCUMENT_ACCEPT"
            :disabled="!!progress"
            @change="onPick"
          />
        </label>
        <p class="text-muted mt-2 text-[13px]">
          <span class="hidden sm:inline">Or drop them here. </span>PDF, Excel, Word, CSV, text,
          email or a picture, up to {{ formatFileSize(ORDER_DOCUMENT_MAX_BYTES) }} each.
        </p>
      </div>

      <!-- One honest line about the batch, never a spinner with no words. -->
      <p v-if="progress" role="status" class="text-ink mb-3 text-[14px] font-medium break-words">
        Uploading {{ progress.index }} of {{ progress.total }}: {{ progress.name }}…
      </p>
      <p
        v-else-if="here?.notice"
        role="status"
        class="text-ink mb-3 text-[14px] font-medium break-words"
      >
        {{ here.notice }}
      </p>
      <p v-if="here?.link" role="status" class="text-ink mb-3 text-[14px] break-words">
        The browser didn't open a new tab.
        <a
          :href="here.link.url"
          target="_blank"
          rel="noopener"
          class="font-medium underline underline-offset-2"
          >Open {{ here.link.name }}</a
        >
        (the link works for {{ linkMinutes }} minutes).
      </p>
      <ul
        v-if="here && (here.problems.length || here.stillUploading)"
        role="alert"
        class="text-danger mb-3 space-y-1 text-[14px] font-medium"
      >
        <li v-for="(problem, i) in here.problems" :key="i" class="break-words">{{ problem }}</li>
        <li v-if="here.stillUploading">
          Still uploading. Add more files when this batch has finished.
        </li>
      </ul>

      <AsyncState
        v-if="!unavailable || rows.length"
        :loading="documents.isLoading.value"
        :error="documents.error.value"
        :has-data="documents.data.value !== undefined"
        :updated-at="documents.dataUpdatedAt.value"
        :rows="1"
        @retry="documents.refetch()"
      >
        <p v-if="rows.length === 0" class="text-muted text-[14px]">
          No documents on this order yet.
        </p>
        <ul v-else ref="list" class="divide-line divide-y">
          <li
            v-for="doc in rows"
            :key="doc.path"
            class="flex items-center justify-between gap-3 py-1 first:pt-0 last:pb-0"
          >
            <button
              type="button"
              class="tap-target min-w-0 flex-1 py-1.5 text-left"
              :title="opensInBrowser(doc.name) ? 'Open in a new tab' : 'Download'"
              @click="open(doc)"
            >
              <span
                class="text-ink block text-[15px] font-medium break-words underline underline-offset-2"
              >
                {{ doc.displayName }}
              </span>
              <span v-if="meta(doc)" class="text-muted block text-[13px]">{{ meta(doc) }}</span>
            </button>
            <button
              v-if="offersRemove(doc)"
              data-remove
              type="button"
              class="text-muted hover:text-danger tap-target shrink-0 px-2 text-[13px] font-semibold uppercase disabled:opacity-50"
              :disabled="removing"
              :aria-label="`Remove ${doc.displayName}`"
              @click="remove(doc)"
            >
              {{ busyPath === doc.path ? 'Removing…' : 'Remove' }}
            </button>
          </li>
        </ul>
      </AsyncState>
    </AppCard>
  </div>
</template>
