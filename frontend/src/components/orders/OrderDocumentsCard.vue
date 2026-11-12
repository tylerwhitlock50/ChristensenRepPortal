<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import {
  openOrderDocument,
  useOrderDocuments,
  useRemoveOrderDocument,
  useUploadOrderDocument,
} from '@/composables/useOrderDocuments'
import {
  ORDER_DOCUMENT_ACCEPT,
  ORDER_DOCUMENT_MAX_BYTES,
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
 * write at all (not while viewing as someone, not offline); removing to
 * admins and inside sales. The bucket's own rules decide in the end — it
 * also lets whoever added a file remove it, but a listing does not say who
 * that was, so the button is not offered on a guess.
 *
 * Renders nothing on a database without the bucket, like every feature that
 * reads something newer than the last migration applied everywhere.
 */
const props = defineProps<{ orderId: number }>()

const session = useSessionStore()
const documents = useOrderDocuments(computed(() => props.orderId))
const upload = useUploadOrderDocument()
const removeDocument = useRemoveOrderDocument()

const rows = computed(() => documents.data.value ?? [])
const unavailable = computed(() => isBucketMissing(documents.error.value))

const canAdd = computed(() => session.canWrite)
const canRemove = computed(
  () => session.canWrite && (session.isAdmin || session.isOrderEntry),
)

const hint = computed(() => {
  if (documents.data.value === undefined) return undefined
  return rows.value.length === 1 ? '1 file' : `${rows.value.length} files`
})

/** What a row says under the name: "287 KB · Nov 12, 2026". */
function meta(doc: OrderDocument): string {
  return [formatFileSize(doc.size), doc.uploadedAt ? shortDate(doc.uploadedAt) : '']
    .filter(Boolean)
    .join(' · ')
}

/* ---- adding ---------------------------------------------------------------
   One file at a time, in the order given: a phone on LTE sending three scans
   at once finishes none of them. Every file is checked first, so a wrong
   type or a 40 MB scan is named before anything uploads; the rest still go.
--------------------------------------------------------------------------- */
const progress = ref<{ index: number; total: number; name: string } | null>(null)
const problems = ref<string[]>([])
const notice = ref('')

async function addFiles(list: FileList | File[] | null | undefined) {
  const files = Array.from(list ?? [])
  if (files.length === 0) return
  if (progress.value) {
    // A second drop mid-batch is not queued behind it, and must not vanish.
    problems.value.push('Still uploading. Add more files when this batch has finished.')
    return
  }
  // Captured once: the page reuses this card when the route moves to another
  // order, and a batch belongs to the order it was dropped on.
  const orderId = props.orderId
  problems.value = []
  notice.value = ''

  const accepted: File[] = []
  for (const file of files) {
    const check = validateDocumentFile(file)
    if (check.ok) accepted.push(file)
    else problems.value.push(check.error)
  }

  // Stored names start with a timestamp; giving each file in the batch the
  // next millisecond keeps two that sanitize to the same name from colliding.
  const startedAt = Date.now()
  let added = 0
  for (const [i, file] of accepted.entries()) {
    progress.value = { index: i + 1, total: accepted.length, name: file.name }
    try {
      await upload.mutateAsync({ orderId, file, at: startedAt + i })
      added += 1
    } catch (e) {
      problems.value.push((e as Error).message || `${file.name} didn't upload.`)
    }
  }
  progress.value = null
  if (added > 0) notice.value = added === 1 ? '1 document added.' : `${added} documents added.`
}

function onPick(event: Event) {
  const input = event.target as HTMLInputElement
  const picked = Array.from(input.files ?? [])
  // Reset so picking the exact same file again still fires `change`.
  input.value = ''
  void addFiles(picked)
}

/* Drag and drop, for a desk: the PO is usually sitting in a downloads folder
   or an email. Only file drags light the zone up (not a dragged link or a
   text selection), and leaving a child element is not leaving the zone. */
const dragging = ref(false)

function isFileDrag(event: DragEvent): boolean {
  return Array.from(event.dataTransfer?.types ?? []).includes('Files')
}

function onDragOver(event: DragEvent) {
  if (!isFileDrag(event)) return
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
  dragging.value = true
}

function onDragLeave(event: DragEvent) {
  const zone = event.currentTarget as HTMLElement
  if (event.relatedTarget instanceof Node && zone.contains(event.relatedTarget)) return
  dragging.value = false
}

function onDrop(event: DragEvent) {
  if (!isFileDrag(event)) return
  event.preventDefault()
  dragging.value = false
  void addFiles(event.dataTransfer?.files)
}

/* ---- opening and removing ------------------------------------------------ */
const busyPath = ref<string | null>(null)

async function open(doc: OrderDocument) {
  problems.value = []
  notice.value = ''
  try {
    // Nothing is awaited ahead of this call: openOrderDocument opens its tab
    // first thing, while the browser still counts this as the tap.
    await openOrderDocument(doc)
  } catch (e) {
    problems.value = [(e as Error).message || `${doc.displayName} couldn't be opened.`]
  }
}

async function remove(doc: OrderDocument) {
  if (busyPath.value) return
  if (!window.confirm(`Remove ${doc.displayName} from this order? This can't be undone.`)) return
  problems.value = []
  notice.value = ''
  busyPath.value = doc.path
  try {
    await removeDocument.mutateAsync({ orderId: props.orderId, document: doc })
    notice.value = `${doc.displayName} removed.`
  } catch (e) {
    problems.value = [(e as Error).message || `${doc.displayName} wasn't removed.`]
  } finally {
    busyPath.value = null
  }
}

// Another order's messages mean nothing on this one.
watch(
  () => props.orderId,
  () => {
    problems.value = []
    notice.value = ''
    dragging.value = false
  },
)
</script>

<template>
  <AppCard v-if="!unavailable" title="Documents" :hint="hint">
    <!-- Add: a drop zone at a desk, the picker everywhere (on a phone it
         offers the camera, the photo library and Files). -->
    <div
      v-if="canAdd"
      class="mb-4 border border-dashed px-4 py-4 text-center"
      :class="dragging ? 'border-ink bg-canvas' : 'border-line-2'"
      @dragenter="onDragOver"
      @dragover="onDragOver"
      @dragleave="onDragLeave"
      @drop="onDrop"
    >
      <p class="text-ink-2 text-[14px]">
        The customer's PO, or anything else that belongs with this order.
      </p>
      <label
        class="btn-secondary mt-3 cursor-pointer"
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
    <p v-else-if="notice" role="status" class="text-ink mb-3 text-[14px] font-medium break-words">
      {{ notice }}
    </p>
    <ul
      v-if="problems.length"
      role="alert"
      class="text-danger mb-3 space-y-1 text-[14px] font-medium"
    >
      <li v-for="(problem, i) in problems" :key="i" class="break-words">{{ problem }}</li>
    </ul>

    <AsyncState
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
      <ul v-else class="divide-line divide-y">
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
            v-if="canRemove"
            type="button"
            class="text-muted hover:text-danger tap-target shrink-0 px-2 text-[13px] font-semibold uppercase disabled:opacity-50"
            :disabled="busyPath !== null"
            :aria-label="`Remove ${doc.displayName}`"
            @click="remove(doc)"
          >
            {{ busyPath === doc.path ? 'Removing…' : 'Remove' }}
          </button>
        </li>
      </ul>
    </AsyncState>
  </AppCard>
</template>
