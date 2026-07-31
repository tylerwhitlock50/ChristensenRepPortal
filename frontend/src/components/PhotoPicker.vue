<script setup lang="ts">
/**
 * Camera-first photo capture — TECH_STACK §2.5.
 *
 * `capture="environment"` puts the rear camera one tap away on a phone and is
 * ignored on desktop, so the same control works in both places. The preview
 * appears the instant the file is picked; compression happens afterwards, one
 * photo at a time (decoding five 4 MB JPEGs at once is how you get killed by
 * iOS memory pressure mid-visit).
 *
 * Works with `visitId` null, so a rep can photograph an endcap from the account
 * page without starting a survey.
 *
 * Honesty rules, because a rep who sees a photo disappear stops trusting the
 * whole app: nothing is removed from the strip until it is actually in Storage
 * *and* `public.photos`, a failed upload says so and offers Retry, and an
 * upload that failed because the signal died retries itself on reconnect.
 */
import { computed, onBeforeUnmount, ref, toRaw, watch } from 'vue'
import { useOnline } from '@vueuse/core'
import {
  attachVisitToPhotos,
  compressPhoto,
  formatBytes,
  newPhotoId,
  uploadPhoto,
  type Photo,
} from '@/lib/photos'
import type { QueuedPhoto } from '@/lib/submitQueue'
import { humanize } from '@/lib/format'
import { PHOTO_CATEGORIES, type PhotoCategory } from '@/types/domain'

const props = withDefaults(
  defineProps<{
    /** Gates Storage RLS via the object path. Required. */
    customerKey: string
    /** Null until the visit row exists — that is a supported state, not an error. */
    visitId?: number | null
    /** Fixes the category and hides the picker chips. */
    category?: PhotoCategory | null
    caption?: string | null
    /**
     * false = collect and compress only, never upload. Use this inside the
     * visit survey so the blobs travel with the survey through the submit
     * queue instead of racing it.
     */
    autoUpload?: boolean
    max?: number
    disabled?: boolean
  }>(),
  {
    visitId: null,
    category: null,
    caption: null,
    autoUpload: true,
    max: 8,
    disabled: false,
  },
)

const emit = defineEmits<{
  /** Rows that made it all the way into `public.photos`. */
  uploaded: [photos: Photo[]]
  /**
   * Everything not yet uploaded, as plain (structured-cloneable) objects. The
   * visit survey hands these to `enqueue()` / `stashDraftPhotos()`.
   */
  pending: [photos: QueuedPhoto[]]
}>()

type ItemStatus =
  | 'compressing'
  | 'ready'
  | 'uploading'
  | 'done'
  | 'waiting'
  | 'failed'

interface LocalPhoto {
  id: string
  previewUrl: string
  originalBytes: number
  compressedBytes: number | null
  status: ItemStatus
  error: string | null
  /** Raw File — Vue does not proxy File, so this stays clone-safe. */
  file: File
  compressed: boolean
  category: PhotoCategory | null
  row: Photo | null
}

const items = ref<LocalPhoto[]>([])
const online = useOnline()
const activeCategory = ref<PhotoCategory | null>(props.category)
const banner = ref('')

const atLimit = computed(() => items.value.length >= props.max)
const showCategoryChips = computed(() => props.category == null)
const busy = computed(() =>
  items.value.some((i) => i.status === 'compressing' || i.status === 'uploading'),
)
const waitingCount = computed(
  () => items.value.filter((i) => i.status === 'waiting').length,
)
const failedCount = computed(
  () => items.value.filter((i) => i.status === 'failed').length,
)

watch(
  () => props.category,
  (next) => {
    if (next != null) activeCategory.value = next
  },
)

/** Plain objects only — these get structured-cloned into IndexedDB. */
function pendingPhotos(): QueuedPhoto[] {
  return items.value
    .filter((i) => i.status !== 'done')
    .map((i) => ({
      id: i.id,
      blob: toRaw(i.file) as Blob,
      fileName: i.file.name || 'photo.jpg',
      contentType: i.file.type || 'image/jpeg',
      category: i.category,
      caption: props.caption ?? null,
      compressed: i.compressed,
      originalBytes: i.originalBytes,
    }))
}

watch(items, () => emit('pending', pendingPhotos()), { deep: true })

function onPick(event: Event): void {
  const input = event.target as HTMLInputElement
  const picked = Array.from(input.files ?? [])
  // Reset so picking the exact same file again still fires `change`.
  input.value = ''
  if (picked.length === 0) return

  banner.value = ''
  const room = Math.max(0, props.max - items.value.length)
  if (picked.length > room) {
    banner.value = `Only ${props.max} photos per visit — kept the first ${room}.`
  }

  for (const file of picked.slice(0, room)) {
    items.value.push({
      id: newPhotoId(),
      // Preview from the ORIGINAL so the thumbnail is on screen before
      // compression starts. Nothing about this waits on the network.
      previewUrl: URL.createObjectURL(file),
      originalBytes: file.size,
      compressedBytes: null,
      status: 'compressing',
      error: null,
      file,
      compressed: false,
      category: activeCategory.value,
      row: null,
    })
  }

  void processAll()
}

let working = false

/** One photo at a time: compress, then upload if we're allowed to. */
async function processAll(): Promise<void> {
  if (working) return
  working = true
  try {
    for (;;) {
      const next = items.value.find(
        (i) =>
          i.status === 'compressing' || (props.autoUpload && i.status === 'ready'),
      )
      if (!next) break

      if (!next.compressed) {
        const original = toRaw(next.file)
        const smaller = await compressPhoto(original)
        next.file = smaller
        next.compressed = true
        next.compressedBytes = smaller.size
      }

      if (!props.autoUpload) {
        // Nothing more to do for this one; it leaves via the `pending` emit.
        next.status = 'ready'
        continue
      }

      if (!online.value) {
        next.status = 'waiting'
        continue
      }

      await uploadOne(next)
    }
  } finally {
    working = false
  }

  // A photo picked while the loop was draining would otherwise be stranded.
  if (items.value.some((i) => i.status === 'compressing')) void processAll()
}

async function uploadOne(item: LocalPhoto): Promise<void> {
  item.status = 'uploading'
  item.error = null
  try {
    const row = await uploadPhoto({
      file: toRaw(item.file),
      customerKey: props.customerKey,
      visitId: props.visitId,
      category: item.category,
      caption: props.caption,
      skipCompression: item.compressed,
    })
    item.row = row
    item.status = 'done'
    emit('uploaded', [row])
  } catch (err) {
    item.error = messageFor(err)
    // Offline is a wait, not a failure — say the true thing.
    item.status = online.value ? 'failed' : 'waiting'
  }
}

/** The reconnect path: anything parked on bad signal goes up by itself. */
watch(online, (isOnline) => {
  if (!isOnline || !props.autoUpload) return
  for (const item of items.value) {
    if (item.status === 'waiting') item.status = 'ready'
  }
  void processAll()
})

/**
 * The survey saves and `visitId` arrives. Anything already uploaded went in
 * with visit_id = null, so link it now — otherwise a photo taken during the
 * visit is never associated with it.
 */
watch(
  () => props.visitId,
  async (visitId, previous) => {
    if (!visitId || previous === visitId) return
    const orphans = items.value
      .map((i) => i.row)
      .filter((r): r is Photo => !!r && r.visit_id == null)
    if (orphans.length === 0) return
    try {
      const updated = await attachVisitToPhotos(
        orphans.map((r) => r.id),
        visitId,
      )
      const byId = new Map(updated.map((r) => [r.id, r]))
      for (const item of items.value) {
        const next = item.row ? byId.get(item.row.id) : undefined
        if (next) item.row = next
      }
    } catch {
      // A photo that is stored but unlinked is a far better outcome than an
      // error the rep cannot act on. Stay quiet; the image is safe.
    }
  },
)

function retry(item: LocalPhoto): void {
  item.status = 'ready'
  item.error = null
  void processAll()
}

/**
 * Two-tap confirm, matching ContactsCard and TasksView. For a photo still in
 * `failed` or `waiting` the in-memory blob is the ONLY copy — a mis-tap next
 * to a 4px-away Retry button used to destroy it with no undo.
 */
const confirmingRemove = ref<string | null>(null)

function askRemove(item: LocalPhoto): void {
  confirmingRemove.value = item.id
}

function cancelRemove(): void {
  confirmingRemove.value = null
}

function remove(item: LocalPhoto): void {
  confirmingRemove.value = null
  URL.revokeObjectURL(item.previewUrl)
  items.value = items.value.filter((i) => i.id !== item.id)
}

/** Clear the strip. Call after the survey submits so the next visit starts clean. */
function reset(): void {
  for (const item of items.value) URL.revokeObjectURL(item.previewUrl)
  items.value = []
  banner.value = ''
}

onBeforeUnmount(() => {
  for (const item of items.value) URL.revokeObjectURL(item.previewUrl)
})

function messageFor(err: unknown): string {
  if (err && typeof err === 'object' && 'message' in err) {
    return String((err as { message: unknown }).message)
  }
  return 'Upload failed.'
}

function statusLabel(item: LocalPhoto): string {
  switch (item.status) {
    case 'compressing':
      return 'Shrinking…'
    case 'uploading':
      return 'Sending…'
    case 'done':
      return 'Saved'
    case 'waiting':
      return 'Waiting for signal'
    case 'failed':
      return item.error ?? 'Failed'
    case 'ready':
      return props.autoUpload ? 'Queued' : 'Ready'
  }
}

function sizeLabel(item: LocalPhoto): string {
  if (item.compressedBytes == null) return formatBytes(item.originalBytes)
  if (item.compressedBytes >= item.originalBytes) {
    return formatBytes(item.originalBytes)
  }
  return `${formatBytes(item.originalBytes)} → ${formatBytes(item.compressedBytes)}`
}

defineExpose({ reset, pendingPhotos })
</script>

<template>
  <div>
    <!-- Category applies to the next photos taken; hidden when the caller fixed it. -->
    <div v-if="showCategoryChips" class="mb-3">
      <p class="u-label mb-2">What is this a photo of?</p>
      <div class="flex flex-wrap gap-2">
        <button
          v-for="c in PHOTO_CATEGORIES"
          :key="c"
          type="button"
          class="font-label tap-target rounded-[2px] border px-3 text-[13px] font-semibold tracking-[0.1em] uppercase"
          :class="
            activeCategory === c
              ? 'border-ink bg-ink text-canvas'
              : 'border-line text-muted'
          "
          :aria-pressed="activeCategory === c"
          @click="activeCategory = activeCategory === c ? null : c"
        >
          {{ humanize(c) }}
        </button>
      </div>
    </div>

    <div class="flex flex-wrap gap-2">
      <label
        class="btn-secondary"
        :class="disabled || atLimit ? 'pointer-events-none opacity-50' : ''"
      >
        <span>Take photo</span>
        <input
          class="sr-only"
          type="file"
          accept="image/*"
          capture="environment"
          :disabled="disabled || atLimit"
          @change="onPick"
        />
      </label>

      <label
        class="btn-ghost"
        :class="disabled || atLimit ? 'pointer-events-none opacity-50' : ''"
      >
        <span>Choose photos</span>
        <input
          class="sr-only"
          type="file"
          accept="image/*"
          multiple
          :disabled="disabled || atLimit"
          @change="onPick"
        />
      </label>
    </div>

    <p v-if="banner" class="text-muted mt-2 text-sm">{{ banner }}</p>

    <!-- One honest line about the whole strip, never a spinner with no words. -->
    <p
      v-if="waitingCount > 0"
      class="text-accent mt-2 text-sm font-medium"
      role="status"
    >
      {{ waitingCount }}
      {{ waitingCount === 1 ? 'photo is' : 'photos are' }} saved on this phone —
      they'll upload when you're back online.
    </p>
    <p v-else-if="failedCount > 0" class="text-danger mt-2 text-sm font-medium" role="status">
      {{ failedCount }} {{ failedCount === 1 ? 'photo' : 'photos' }} didn't
      upload. They're still here — tap Retry.
    </p>
    <p v-else-if="busy" class="text-muted mt-2 text-sm" role="status">
      Working on your photos…
    </p>

    <ul v-if="items.length" class="mt-3 grid grid-cols-3 gap-2 sm:grid-cols-4">
      <li
        v-for="item in items"
        :key="item.id"
        class="border-line bg-surface border"
      >
        <div class="relative">
          <img
            :src="item.previewUrl"
            alt=""
            class="block aspect-square w-full object-cover"
          />
          <span
            v-if="item.status === 'done'"
            class="bg-brand text-canvas font-label absolute top-1 right-1 px-1.5 py-0.5 text-[11px] font-semibold tracking-[0.1em] uppercase"
          >
            Saved
          </span>
          <span
            v-else-if="item.status === 'waiting'"
            class="bg-accent font-label absolute top-1 right-1 px-1.5 py-0.5 text-[11px] font-semibold tracking-[0.1em] text-[#20100A] uppercase"
          >
            Waiting
          </span>
        </div>

        <div class="p-1.5">
          <p class="text-ink truncate text-[12px] leading-tight font-medium">
            {{ statusLabel(item) }}
          </p>
          <p class="text-muted truncate text-[11px] leading-tight">
            {{ sizeLabel(item) }}
          </p>

          <!--
            Full-width stacked rows, not a wrapped inline pair. In a ~91px
            grid cell these were 32px tall and 4px apart, and Remove is
            destructive — a cold thumb aiming for Retry hit it instead.
          -->
          <div class="mt-1 flex flex-col gap-1">
            <button
              v-if="item.status === 'failed'"
              type="button"
              class="tap-target text-ink w-full text-[13px] font-semibold underline underline-offset-2"
              @click="retry(item)"
            >
              Retry
            </button>

            <template v-if="item.status !== 'done' && item.status !== 'uploading'">
              <button
                v-if="confirmingRemove !== item.id"
                type="button"
                class="tap-target text-muted w-full text-[13px] underline underline-offset-2"
                @click="askRemove(item)"
              >
                Remove
              </button>
              <template v-else>
                <button
                  type="button"
                  class="tap-target text-danger w-full text-[13px] font-semibold underline underline-offset-2"
                  @click="remove(item)"
                >
                  Delete it
                </button>
                <button
                  type="button"
                  class="tap-target text-ink w-full text-[13px] underline underline-offset-2"
                  @click="cancelRemove"
                >
                  Keep
                </button>
              </template>
            </template>
          </div>
        </div>
      </li>
    </ul>

    <p v-if="!autoUpload && items.length" class="text-muted mt-2 text-sm">
      These go up with the visit when you submit it.
    </p>
  </div>
</template>
