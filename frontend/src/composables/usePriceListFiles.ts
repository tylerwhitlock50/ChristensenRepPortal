import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { newPhotoId } from '@/lib/photos'

/**
 * The downloadable approved price sheets (public.price_list_files + the
 * private `price-lists` bucket, migration 20260817000100).
 *
 * Reps read the metadata table and download through short-lived signed URLs
 * — the bucket is private, `getPublicUrl` 400s, exactly like account-photos.
 * Admin uploads go straight to Storage with the admin's JWT (no Edge
 * Function), then the metadata row; Storage RLS is the enforcement.
 */

/** Tables land after database.types.ts was last generated — same untyped-
 *  handle convention as useAppSettings.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

export const PRICE_LIST_BUCKET = 'price-lists'

export interface PriceListFileRow {
  id: number
  customer_type: string
  title: string
  storage_path: string
  file_name: string
  file_size: number | null
  uploaded_by: string | null
  uploaded_at: string
}

async function fetchFiles(): Promise<PriceListFileRow[]> {
  const { data, error } = await db
    .from('price_list_files')
    .select('*')
    .order('customer_type')
    .order('uploaded_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as PriceListFileRow[]
}

export function usePriceListFiles() {
  return useQuery({ queryKey: qk.priceLists.files(), queryFn: fetchFiles })
}

/**
 * Start a browser download of one sheet. The `download` option makes the
 * signed URL serve Content-Disposition: attachment with the original file
 * name, so navigating to it saves the file instead of opening a tab of
 * base64 soup.
 */
export async function downloadPriceListFile(file: PriceListFileRow): Promise<void> {
  const { data, error } = await supabase.storage
    .from(PRICE_LIST_BUCKET)
    .createSignedUrl(file.storage_path, 60, { download: file.file_name })
  if (error) throw error

  const link = document.createElement('a')
  link.href = data.signedUrl
  link.rel = 'noopener'
  link.style.display = 'none'
  document.body.appendChild(link)
  link.click()
  link.remove()
}

/** `Dealer / Range Program` → `dealer-range-program`; the path's 1st folder. */
function slugify(value: string): string {
  return (
    value
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'general'
  )
}

const EXT_BY_MIME: Record<string, string> = {
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'application/vnd.ms-excel': 'xls',
  'text/csv': 'csv',
  'application/pdf': 'pdf',
}

function extensionFor(file: File): string {
  const byMime = EXT_BY_MIME[file.type.toLowerCase()]
  if (byMime) return byMime
  const match = /\.([a-z0-9]{1,5})$/i.exec(file.name)
  return match ? match[1].toLowerCase() : 'xlsx'
}

export interface UploadPriceListFileInput {
  file: File
  customerType: string
  title: string
  /** Row being replaced — its object and metadata are removed on success. */
  replaces?: PriceListFileRow | null
}

/**
 * Admin: publish (or replace) the sheet for one customer type. Upload the
 * new object first, then the metadata row, then clean up the old pair —
 * so a failure at any step never leaves the page pointing at a missing
 * object. Worst case is an orphaned blob, which an admin can sweep.
 */
export function useUploadPriceListFile() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: UploadPriceListFileInput) => {
      const path = `${slugify(input.customerType)}/${newPhotoId()}.${extensionFor(input.file)}`

      const { error: uploadError } = await supabase.storage
        .from(PRICE_LIST_BUCKET)
        .upload(path, input.file, {
          contentType: input.file.type || undefined,
          upsert: false,
          cacheControl: '3600',
        })
      if (uploadError) throw uploadError

      const { data, error } = await db
        .from('price_list_files')
        .insert({
          customer_type: input.customerType.trim(),
          title: input.title.trim(),
          storage_path: path,
          file_name: input.file.name,
          file_size: input.file.size,
          uploaded_by: (await supabase.auth.getUser()).data.user?.id ?? null,
        })
        .select()
        .single()
      if (error) {
        void supabase.storage
          .from(PRICE_LIST_BUCKET)
          .remove([path])
          .catch(() => undefined)
        throw error
      }

      if (input.replaces) {
        await db.from('price_list_files').delete().eq('id', input.replaces.id)
        void supabase.storage
          .from(PRICE_LIST_BUCKET)
          .remove([input.replaces.storage_path])
          .catch(() => undefined)
      }
      return data as PriceListFileRow
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.priceLists.files() })
    },
  })
}

export function useDeletePriceListFile() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (file: PriceListFileRow) => {
      const { error } = await db.from('price_list_files').delete().eq('id', file.id)
      if (error) throw error
      void supabase.storage
        .from(PRICE_LIST_BUCKET)
        .remove([file.storage_path])
        .catch(() => undefined)
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.priceLists.files() })
    },
  })
}
