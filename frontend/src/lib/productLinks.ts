/**
 * SKU → christensenarms.com product page.
 *
 * There are no product images anywhere in the ERP or the app, but the public
 * website has a page per product FAMILY with photography and specs, and the
 * family slugs are predictable: "Ridgeline FFT" lives at
 * https://christensenarms.com/product/ridgeline-fft/. So a SKU cell links out
 * to the family page in a new tab — the rep gets the picture without us
 * building an image pipeline.
 *
 * The slug is derived (lowercase, non-alphanumeric runs → '-'), which is a
 * guess that happens to be right for the families checked so far; OVERRIDES
 * is the correction channel for any family whose site slug differs — add an
 * entry the moment a 404 is reported. Blank/'N/A' families get no link.
 */

/** ERP family name → site slug, for the ones the slugifier gets wrong. */
const OVERRIDES: Record<string, string> = {
  // 'Some ERP Family Name': 'site-slug',
}

/** Mirrors useIntel's hasSpec(): dim_part writes 'N/A' where a spec doesn't apply. */
function hasFamily(value: string | null | undefined): value is string {
  const v = (value ?? '').trim()
  return v !== '' && v.toUpperCase() !== 'N/A'
}

function slugify(family: string): string {
  return family
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

/**
 * The product page for a part's family, or null when there is nothing to
 * link (blank family, 'N/A', or a name that slugifies to nothing).
 */
export function productFamilyUrl(family: string | null | undefined): string | null {
  if (!hasFamily(family)) return null
  const slug = OVERRIDES[family.trim()] ?? slugify(family)
  if (!slug) return null
  return `https://christensenarms.com/product/${slug}/`
}
