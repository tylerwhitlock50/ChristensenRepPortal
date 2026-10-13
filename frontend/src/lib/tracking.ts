/**
 * UPS tracking links, shared by Find, the activity feed and the account
 * page's order sheets. Its own tiny module so a page that only draws links
 * doesn't pull in the whole dealer-message composer (orderStatusMessage.ts,
 * which re-exports these).
 */

/** UPS is the only carrier; the number goes straight to their tracking page. */
export function upsTrackUrl(trackingNumber: string): string {
  return `https://www.ups.com/track?tracknum=${encodeURIComponent(trackingNumber.trim())}`
}

/** A row can carry several parcels' numbers, comma-joined by the database. */
export function trackingList(value: string | null | undefined): string[] {
  return [
    ...new Set(
      (value ?? '')
        .split(',')
        .map((v) => v.trim())
        .filter(Boolean),
    ),
  ]
}
