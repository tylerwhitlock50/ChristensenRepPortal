/**
 * Photo pipeline — TECH_STACK §2.5 and §3.2.
 *
 * A 4 MB phone photo becomes ~300 KB before it leaves the device. That is both
 * the UX fix (an upload that completes on one bar of LTE) and the answer to the
 * PRD's Storage-cost question: 5 photos/visit × 200 visits/season is ~300 MB
 * rather than ~4 GB.
 *
 * Upload goes straight to Storage with the rep's own JWT — no Edge Function
 * (§3.2). The bucket is private and its RLS reads the FIRST folder of the
 * object path, so the path must be exactly `<customer_key>/<uuid>.<ext>`:
 *
 *   has_account_access((storage.foldername(name))[1])   -- 009_storage.sql
 *
 * Get that segment wrong and the upload is rejected — which is the failure
 * mode we want, but it means the customer key is not cosmetic.
 */

import imageCompression from 'browser-image-compression'
import { supabase } from '@/lib/supabase'
import type { Tables } from '@/types/database.types'
import type { PhotoCategory } from '@/types/domain'

export type Photo = Tables<'photos'>

export const PHOTO_BUCKET = 'account-photos'
/** §2.5: ~1600px on the long edge. Plenty for a storefront or an endcap. */
export const PHOTO_MAX_DIMENSION = 1600
/** §2.5: ~300 KB. */
export const PHOTO_TARGET_MB = 0.3
const TARGET_BYTES = PHOTO_TARGET_MB * 1024 * 1024

/** What 009_storage.sql will accept. Anything else is converted to JPEG. */
const ALLOWED_MIME = [
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
] as const

const EXT_BY_MIME: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/heif': 'heic',
}

/**
 * Compress to ~1600px / ~300 KB, converting to JPEG on the way.
 *
 * Never throws and never returns something larger than it was given: a photo
 * the browser can't decode (some HEIC on non-Safari) is passed through
 * untouched rather than lost. The rep's picture matters more than our byte
 * budget.
 */
export async function compressPhoto(file: File): Promise<File> {
  if (!file.type.startsWith('image/')) return file

  // Already inside the budget — re-encoding a 180 KB shot only costs detail.
  if (file.size <= TARGET_BYTES) return file

  let out: File
  try {
    out = await imageCompression(file, {
      maxSizeMB: PHOTO_TARGET_MB,
      maxWidthOrHeight: PHOTO_MAX_DIMENSION,
      initialQuality: 0.8,
      fileType: 'image/jpeg',
      // Deliberately OFF. browser-image-compression's worker path does
      // `importScripts('https://cdn.jsdelivr.net/...')`, so on the bad-signal
      // connection this whole feature exists for it would stall on a CDN fetch
      // before falling back to the main thread anyway. Compressing on the main
      // thread costs a few hundred ms per photo and always works offline.
      useWebWorker: false,
      // EXIF orientation is already baked into the resized canvas; keeping the
      // rest of the EXIF would ship the dealer's GPS coordinates to Storage.
      preserveExif: false,
    })
  } catch (err) {
    console.warn('[photos] compression failed; uploading the original', err)
    return file
  }

  if (!out || out.size >= file.size) return file

  // The library copies the original filename onto its output, so a HEIC in
  // gives you "IMG_0001.heic" holding JPEG bytes. Rename to match the bytes.
  return renameFor(out, file.name)
}

/** `<customer_key>/<uuid>.<ext>` — the first segment is what Storage RLS reads. */
export function photoStoragePath(customerKey: string, mimeType: string, fileName = ''): string {
  return `${customerKey}/${newPhotoId()}.${extensionFor(mimeType, fileName)}`
}

export interface UploadPhotoInput {
  file: File | Blob
  /** Gates Storage RLS via the object path. Required, and never guessed. */
  customerKey: string
  /** Null when the photo is taken on the account page, before any visit exists. */
  visitId?: number | null
  /** Kept to the domain vocabulary even though the column is free text. */
  category?: PhotoCategory | null
  caption?: string | null
  /** Set when the blob came off the retry queue and was already compressed. */
  skipCompression?: boolean
}

/**
 * Compress → upload to the private bucket → insert the `public.photos` row.
 *
 * Resolves with the inserted row. Rejects if either half fails; on a failed
 * metadata insert it tries to remove the orphaned object first (see below).
 */
export async function uploadPhoto(input: UploadPhotoInput): Promise<Photo> {
  const customerKey = input.customerKey?.trim()
  if (!customerKey) {
    throw new Error(
      'uploadPhoto needs a customerKey: it is the first path segment and the ' +
        'only thing Storage RLS checks.',
    )
  }
  if (customerKey.includes('/')) {
    throw new Error(
      `Customer key "${customerKey}" contains a slash, which would split the ` +
        'Storage path and break account-level access control.',
    )
  }

  const asFile = toFile(input.file)
  const file = input.skipCompression ? asFile : await compressPhoto(asFile)
  const contentType = uploadMimeFor(file)
  const path = photoStoragePath(customerKey, contentType, file.name)

  const { error: uploadError } = await supabase.storage
    .from(PHOTO_BUCKET)
    .upload(path, file, { contentType, upsert: false, cacheControl: '3600' })
  if (uploadError) throw uploadError

  const { data, error } = await supabase
    .from('photos')
    .insert({
      customer_key: customerKey,
      storage_path: path,
      visit_id: input.visitId ?? null,
      category: input.category ?? null,
      caption: input.caption?.trim() || null,
    })
    .select()
    .single()

  if (error) {
    // Best effort. The delete policy in 009_storage.sql is admin-only, so for a
    // rep this will fail and leave a ~300 KB object nothing points at. That is
    // the right trade: an orphaned blob is cheap, a silently dropped photo is
    // not, and an admin can sweep the bucket against public.photos later.
    void supabase.storage
      .from(PHOTO_BUCKET)
      .remove([path])
      .catch(() => undefined)
    throw error
  }

  return data
}

/**
 * A time-limited URL for a private object. `getPublicUrl` returns a 400 for
 * this bucket — it is not public and must not become public.
 */
export async function signedPhotoUrl(
  storagePath: string,
  expiresIn = 3600,
): Promise<string> {
  const { data, error } = await supabase.storage
    .from(PHOTO_BUCKET)
    .createSignedUrl(storagePath, expiresIn)
  if (error) throw error
  return data.signedUrl
}

/** One round trip for a whole gallery. Missing/denied paths come back null. */
export async function signedPhotoUrls(
  storagePaths: string[],
  expiresIn = 3600,
): Promise<Record<string, string | null>> {
  const result: Record<string, string | null> = {}
  if (storagePaths.length === 0) return result

  const { data, error } = await supabase.storage
    .from(PHOTO_BUCKET)
    .createSignedUrls(storagePaths, expiresIn)
  if (error) throw error

  for (const row of data ?? []) {
    if (row.path) result[row.path] = row.error ? null : row.signedUrl
  }
  for (const path of storagePaths) {
    if (!(path in result)) result[path] = null
  }
  return result
}

/** "4.1 MB", "287 KB" — for showing the rep what the compression bought. */
export function formatBytes(bytes: number | null | undefined): string {
  if (bytes == null || Number.isNaN(bytes)) return '—'
  if (bytes < 1024) return `${bytes} B`
  const kb = bytes / 1024
  if (kb < 1000) return `${Math.round(kb)} KB`
  return `${(kb / 1024).toFixed(1)} MB`
}

/**
 * UUID v4. `crypto.randomUUID` is undefined outside a secure context, and
 * on-device testing (TECH_STACK §11 step 6: "test on an actual phone") happens
 * over plain http://<lan-ip>, so the fallback is not theoretical.
 */
export function newPhotoId(): string {
  const c = globalThis.crypto
  if (typeof c?.randomUUID === 'function') return c.randomUUID()

  const bytes = new Uint8Array(16)
  if (typeof c?.getRandomValues === 'function') {
    c.getRandomValues(bytes)
  } else {
    for (let i = 0; i < 16; i += 1) bytes[i] = Math.floor(Math.random() * 256)
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
  return [
    hex.slice(0, 8),
    hex.slice(8, 12),
    hex.slice(12, 16),
    hex.slice(16, 20),
    hex.slice(20),
  ].join('-')
}

function extensionFor(mimeType: string, fileName: string): string {
  const byMime = EXT_BY_MIME[mimeType.toLowerCase()]
  if (byMime) return byMime
  const match = /\.([a-z0-9]{1,5})$/i.exec(fileName)
  return match ? match[1].toLowerCase() : 'jpg'
}

/** The bucket rejects anything outside its allow-list; claim JPEG rather than 400. */
function uploadMimeFor(file: File): string {
  const type = file.type.toLowerCase()
  return (ALLOWED_MIME as readonly string[]).includes(type) ? type : 'image/jpeg'
}

function renameFor(file: File, originalName: string): File {
  const base = (originalName || 'photo').replace(/\.[^.]+$/, '') || 'photo'
  const name = `${base}.${extensionFor(file.type, originalName)}`
  return new File([file], name, { type: file.type, lastModified: Date.now() })
}

/** Queued photos come back off IndexedDB as Blobs; the compressor wants a File. */
function toFile(input: File | Blob): File {
  if (input instanceof File) return input
  const ext = extensionFor(input.type, '')
  return new File([input], `photo.${ext}`, {
    type: input.type || 'image/jpeg',
    lastModified: Date.now(),
  })
}
