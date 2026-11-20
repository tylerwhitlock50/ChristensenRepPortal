/**
 * The rules around Resources (public.rep_resources + the private
 * `rep-resources` bucket, migration 20261120120000) that do not need a
 * network: categories, who a file is for, the object path, which files the
 * bucket will take, and how the page groups and filters the list.
 *
 * Kept out of the composable so tests/unit/resources.test.ts can pin them
 * without Supabase.
 */

export const RESOURCE_BUCKET = 'rep-resources'

export const RESOURCE_CATEGORIES = [
  { key: 'price_list', label: 'Price lists' },
  { key: 'program', label: 'Programs' },
  { key: 'marketing', label: 'Marketing' },
  { key: 'training', label: 'Training' },
  { key: 'other', label: 'Other' },
] as const

export type ResourceCategory = (typeof RESOURCE_CATEGORIES)[number]['key']

export function categoryLabel(key: string): string {
  return RESOURCE_CATEGORIES.find((c) => c.key === key)?.label ?? 'Other'
}

export interface ResourceRow {
  id: number
  title: string
  description: string | null
  category: string
  rep_group_vendor_id: string | null
  customer_key: string | null
  storage_path: string
  file_name: string
  content_type: string | null
  file_size: number | null
  uploaded_by: string | null
  uploaded_at: string
  updated_at: string
}

/* ---- who a file is for ------------------------------------------------- */

export type Audience =
  | { kind: 'everyone' }
  | { kind: 'agency'; vendorId: string }
  | { kind: 'account'; customerKey: string }

export function audienceOf(
  row: Pick<ResourceRow, 'rep_group_vendor_id' | 'customer_key'>,
): Audience {
  if (row.customer_key) return { kind: 'account', customerKey: row.customer_key }
  if (row.rep_group_vendor_id) return { kind: 'agency', vendorId: row.rep_group_vendor_id }
  return { kind: 'everyone' }
}

/** The two columns an audience is stored as. One is always null (DB check). */
export function audienceColumns(audience: Audience): {
  rep_group_vendor_id: string | null
  customer_key: string | null
} {
  switch (audience.kind) {
    case 'agency':
      return { rep_group_vendor_id: audience.vendorId.trim() || null, customer_key: null }
    case 'account':
      return { rep_group_vendor_id: null, customer_key: audience.customerKey || null }
    default:
      return { rep_group_vendor_id: null, customer_key: null }
  }
}

/**
 * The tag beside a file. A rep is told whose it is ("Your agency", the
 * account's name); an admin is told the agency id too, since they publish
 * for every agency. Null for an everyone file: no tag.
 */
export function audienceTag(
  row: Pick<ResourceRow, 'rep_group_vendor_id' | 'customer_key'>,
  accountNames: Readonly<Record<string, string>>,
  forAdmin = false,
): string | null {
  const a = audienceOf(row)
  if (a.kind === 'account') return `For ${accountNames[a.customerKey] ?? a.customerKey}`
  if (a.kind === 'agency') return forAdmin ? `Agency ${a.vendorId}` : 'Your agency'
  return forAdmin ? 'Everyone' : null
}

/* ---- files the bucket takes -------------------------------------------- */

/** Mirrors the bucket's file_size_limit. */
export const RESOURCE_MAX_BYTES = 50 * 1024 * 1024

/** Extension → MIME, and exactly the bucket's allowed_mime_types. */
export const RESOURCE_TYPES: Readonly<Record<string, string>> = {
  pdf: 'application/pdf',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  xls: 'application/vnd.ms-excel',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  doc: 'application/msword',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  ppt: 'application/vnd.ms-powerpoint',
  csv: 'text/csv',
  txt: 'text/plain',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  zip: 'application/zip',
}

/** For the file input's accept attribute. */
export const RESOURCE_ACCEPT = Object.keys(RESOURCE_TYPES)
  .map((ext) => `.${ext}`)
  .join(',')

export function fileExtensionOf(name: string): string {
  const match = /\.([a-z0-9]{1,5})$/i.exec(name.trim())
  return match ? match[1].toLowerCase() : ''
}

/**
 * What to tell Storage the object is. The extension decides, not the
 * browser: Windows hands over an empty type for .xlsx on some builds, and
 * some browsers say application/octet-stream, which the bucket refuses.
 */
export function resourceContentType(file: { name: string; type?: string }): string | null {
  const byExt = RESOURCE_TYPES[fileExtensionOf(file.name)]
  if (byExt) return byExt
  const t = (file.type ?? '').toLowerCase()
  return Object.values(RESOURCE_TYPES).includes(t) ? t : null
}

/** Why the bucket would refuse this file, in the admin's words; null if fine. */
export function validateResourceFile(file: { name: string; size: number; type?: string }): string | null {
  if (!resourceContentType(file)) {
    return 'That kind of file can’t be published here. Use PDF, Excel, Word, PowerPoint, CSV, an image or a zip.'
  }
  if (file.size <= 0) return 'That file is empty.'
  if (file.size > RESOURCE_MAX_BYTES) return 'That file is over 50 MB.'
  return null
}

/**
 * '<category>/<uuid>.<ext>' — never the original name, which goes in the
 * row for the download instead (names carry spaces, accents and the odd
 * slash; a uuid never collides with the unique storage_path).
 */
export function resourcePath(category: string, id: string, fileName: string): string {
  const cat = RESOURCE_CATEGORIES.some((c) => c.key === category) ? category : 'other'
  const ext = fileExtensionOf(fileName)
  return `${cat}/${id}${ext ? `.${ext}` : ''}`
}

/* ---- the page ----------------------------------------------------------- */

export interface ResourceGroup<T extends ResourceRow = ResourceRow> {
  category: string
  label: string
  files: T[]
}

/**
 * Words a search should match: the title, the description, the file name,
 * and the account name of an account's file ("midway" finds MidwayUSA's
 * price list).
 */
export function resourceMatches(
  row: ResourceRow,
  term: string,
  accountNames: Readonly<Record<string, string>>,
): boolean {
  const q = term.trim().toLowerCase()
  if (!q) return true
  const account = row.customer_key ? (accountNames[row.customer_key] ?? row.customer_key) : ''
  return [row.title, row.description ?? '', row.file_name, account, categoryLabel(row.category)]
    .join(' ')
    .toLowerCase()
    .includes(q)
}

/**
 * Category sections in the fixed order above, empty ones dropped. Inside a
 * section: files for one of the rep's accounts or their agency first (they
 * were put there for this rep), then newest first.
 */
export function groupResources<T extends ResourceRow>(rows: readonly T[]): ResourceGroup<T>[] {
  const rank = (r: ResourceRow) => (r.customer_key ? 0 : r.rep_group_vendor_id ? 1 : 2)
  return RESOURCE_CATEGORIES.map(({ key, label }) => ({
    category: key,
    label,
    files: rows
      .filter((r) => (RESOURCE_CATEGORIES.some((c) => c.key === r.category) ? r.category : 'other') === key)
      .sort(
        (a, b) =>
          rank(a) - rank(b) ||
          b.updated_at.localeCompare(a.updated_at) ||
          a.title.localeCompare(b.title),
      ),
  })).filter((g) => g.files.length > 0)
}
