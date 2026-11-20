import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { qk } from '@/lib/queryClient'
import { newPhotoId } from '@/lib/photos'
import { trackAction } from '@/lib/usage'
import {
  RESOURCE_BUCKET,
  audienceColumns,
  resourceContentType,
  resourcePath,
  validateResourceFile,
  type Audience,
  type ResourceRow,
} from '@/lib/resources'

/**
 * Resources: documents published to reps (public.rep_resources + the
 * private `rep-resources` bucket, migration 20261120120000).
 *
 * No owner filter is written here. RLS decides which rows a caller sees
 * (everyone's files, their agency's, their accounts'), and the bucket's read
 * policy follows the rows, so a signed URL can only be minted for a file
 * the caller may see. Admin writes go straight to Storage and the table
 * with the admin's JWT, like the price-list sheets.
 */

/** Table lands after database.types.ts was last generated — same untyped-
 *  handle convention as usePriceListFiles.ts; delete after types regenerate. */
const db = supabase as unknown as SupabaseClient

async function fetchResources(): Promise<ResourceRow[]> {
  const { data, error } = await db
    .from('rep_resources')
    .select('*')
    .order('updated_at', { ascending: false })
  if (error) throw error
  return (data ?? []) as ResourceRow[]
}

/** Every file the caller may see; an admin's is every file. */
export function useResources() {
  return useQuery({ queryKey: qk.resources.list(), queryFn: fetchResources })
}

/**
 * Start a browser download. The `download` option makes the signed URL
 * serve Content-Disposition: attachment with the original file name.
 */
export async function downloadResource(row: ResourceRow): Promise<void> {
  const { data, error } = await supabase.storage
    .from(RESOURCE_BUCKET)
    .createSignedUrl(row.storage_path, 60, { download: row.file_name })
  if (error) throw error

  const link = document.createElement('a')
  link.href = data.signedUrl
  link.rel = 'noopener'
  link.style.display = 'none'
  document.body.appendChild(link)
  link.click()
  link.remove()

  trackAction('download', { what: 'resource', id: row.id, category: row.category })
}

export interface SaveResourceInput {
  /** The row being edited; absent to publish a new one. */
  existing?: ResourceRow | null
  title: string
  description: string
  category: string
  audience: Audience
  /** Required for a new resource; on an edit, replaces the file. */
  file?: File | null
}

/**
 * Admin: publish a resource, or edit one (and optionally swap its file).
 * The new object goes up first, then the row, then the old object is
 * removed, so a failure at any step never leaves a row pointing at a
 * missing object. Worst case is an orphaned object, which only an admin
 * can see and which is harmless.
 */
export function useSaveResource() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (input: SaveResourceInput): Promise<ResourceRow> => {
      const title = input.title.trim()
      if (!title) throw new Error('A title is required.')
      if (!input.existing && !input.file) throw new Error('Choose a file to publish.')
      if (input.file) {
        const problem = validateResourceFile(input.file)
        if (problem) throw new Error(problem)
      }

      let uploaded: { path: string; file: File } | null = null
      if (input.file) {
        const path = resourcePath(input.category, newPhotoId(), input.file.name)
        const { error } = await supabase.storage.from(RESOURCE_BUCKET).upload(path, input.file, {
          contentType: resourceContentType(input.file) ?? undefined,
          upsert: false,
          cacheControl: '3600',
        })
        if (error) throw error
        uploaded = { path, file: input.file }
      }

      const fields = {
        title,
        description: input.description.trim() || null,
        category: input.category,
        ...audienceColumns(input.audience),
        ...(uploaded
          ? {
              storage_path: uploaded.path,
              file_name: uploaded.file.name,
              content_type: resourceContentType(uploaded.file),
              file_size: uploaded.file.size,
            }
          : {}),
      }

      const write = input.existing
        ? db.from('rep_resources').update(fields).eq('id', input.existing.id)
        : db.from('rep_resources').insert({
            ...fields,
            uploaded_by: (await supabase.auth.getUser()).data.user?.id ?? null,
          })
      const { data, error } = await write.select().single()
      if (error) {
        if (uploaded) {
          void supabase.storage
            .from(RESOURCE_BUCKET)
            .remove([uploaded.path])
            .catch(() => undefined)
        }
        throw error
      }

      if (uploaded && input.existing) {
        void supabase.storage
          .from(RESOURCE_BUCKET)
          .remove([input.existing.storage_path])
          .catch(() => undefined)
      }
      return data as ResourceRow
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.resources.root() })
    },
  })
}

/** Admin: take a resource down. The row goes first; the object follows. */
export function useDeleteResource() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (row: ResourceRow) => {
      const { error } = await db.from('rep_resources').delete().eq('id', row.id)
      if (error) throw error
      void supabase.storage
        .from(RESOURCE_BUCKET)
        .remove([row.storage_path])
        .catch(() => undefined)
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.resources.root() })
    },
  })
}
