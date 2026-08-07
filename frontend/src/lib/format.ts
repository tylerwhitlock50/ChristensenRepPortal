import { differenceInCalendarDays, format, parseISO } from 'date-fns'

const currency0 = new Intl.NumberFormat('en-US', {
  style: 'currency',
  currency: 'USD',
  maximumFractionDigits: 0,
})

/** Money on a phone screen: no cents, always a dash for missing. */
export function money(value: number | null | undefined): string {
  if (value == null || Number.isNaN(value)) return '—'
  return currency0.format(value)
}

export function count(value: number | null | undefined): string {
  if (value == null) return '—'
  return new Intl.NumberFormat('en-US').format(value)
}

function toDate(value: string | Date | null | undefined): Date | null {
  if (!value) return null
  const d = value instanceof Date ? value : parseISO(value)
  return Number.isNaN(d.getTime()) ? null : d
}

export function shortDate(value: string | Date | null | undefined): string {
  const d = toDate(value)
  return d ? format(d, 'MMM d, yyyy') : '—'
}

/** Compact fixed-width date for dense grids. */
export function isoDate(value: string | Date | null | undefined): string {
  const d = toDate(value)
  return d ? format(d, 'yyyy-MM-dd') : '—'
}

export function dayMonth(value: string | Date | null | undefined): string {
  const d = toDate(value)
  return d ? format(d, 'MMM d') : '—'
}

/**
 * Plain-English recency. Persona #1 is low-data-literacy; "23 days ago" reads
 * faster than a date, and the date is available on the detail screen anyway.
 */
export function daysAgo(value: string | Date | null | undefined): string {
  const d = toDate(value)
  if (!d) return 'never'
  const days = differenceInCalendarDays(new Date(), d)
  if (days === 0) return 'today'
  if (days === 1) return 'yesterday'
  if (days < 30) return `${days} days ago`
  if (days < 60) return 'last month'
  if (days < 365) return `${Math.round(days / 30)} months ago`
  const years = Math.floor(days / 365)
  return years === 1 ? 'over a year ago' : `${years} years ago`
}

/** Negative when overdue. Null when there is no due date. */
export function daysUntilDue(
  value: string | Date | null | undefined,
): number | null {
  const d = toDate(value)
  return d ? differenceInCalendarDays(d, new Date()) : null
}

export function dueLabel(value: string | Date | null | undefined): string {
  const days = daysUntilDue(value)
  if (days == null) return 'No due date'
  if (days < -1) return `${Math.abs(days)} days overdue`
  if (days === -1) return 'Due yesterday'
  if (days === 0) return 'Due today'
  if (days === 1) return 'Due tomorrow'
  return `Due in ${days} days`
}

/** Title-cases an ERP value that arrives SHOUTING or snake_cased. */
export function humanize(value: string | null | undefined): string {
  if (!value) return '—'
  return value
    .replace(/_/g, ' ')
    .toLowerCase()
    .replace(/\b\w/g, (c) => c.toUpperCase())
}
