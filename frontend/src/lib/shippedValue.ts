/**
 * The dollars shown for a shipment: its packlist value (shipped_value,
 * 20261027090300 — shipped qty × unit price net of trade discount).
 *
 * Shipped is not invoiced (Tyler, 2026-10-26): revenue counts only once a
 * line is invoiced, and shipping can packlist days ahead of billing, so
 * shipment dollars are labelled "Shipped value" everywhere and never called
 * revenue. On a database without the column the older shipped_revenue
 * figure stands in, under the same label, until the migration lands.
 *
 * Its own tiny module, like tracking.ts, so the account page's shipment
 * card and the activity feed share one rule without importing each other.
 */
export function shippedValue(row: {
  shipped_value?: number | null
  shipped_revenue?: number | null
}): number | null {
  return row.shipped_value ?? row.shipped_revenue ?? null
}
