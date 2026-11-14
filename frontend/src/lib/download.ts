/**
 * Hand a generated file to the browser — shared by the CSV and Excel
 * exports (lib/csv.ts, lib/xlsx.ts, components/ui/ExportMenu.vue).
 *
 * The object URL is revoked on the next tick: revoking synchronously after
 * `.click()` cancels the download in Safari.
 */
export function downloadBlob(filename: string, blob: Blob): void {
  const url = URL.createObjectURL(blob)
  try {
    const link = document.createElement('a')
    link.href = url
    link.download = filename
    link.rel = 'noopener'
    link.style.display = 'none'
    document.body.appendChild(link)
    link.click()
    link.remove()
  } finally {
    setTimeout(() => URL.revokeObjectURL(url), 0)
  }
}

const pad = (n: number) => String(n).padStart(2, '0')

/**
 * `in-stock`, `xlsx` → `in-stock-2026-11-13-1816.xlsx`, in the user's local
 * time. The time is there so two downloads on the same day (before and after
 * a stock load) do not land as `in-stock (1).xlsx` with nothing to tell them
 * apart. The prefix is reduced to characters every OS accepts in a name.
 */
export function exportFilename(prefix: string, extension: string, date: Date = new Date()): string {
  const safe =
    prefix
      .normalize('NFKD')
      .replace(/[^\w.-]+/g, '-')
      .replace(/-{2,}/g, '-')
      .replace(/^[-.]+|[-.]+$/g, '')
      .slice(0, 80) || 'export'
  const stamp =
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `-${pad(date.getHours())}${pad(date.getMinutes())}`
  return `${safe}-${stamp}.${extension.replace(/^\./, '')}`
}

/**
 * "Nov 13, 2026, 6:16 PM MST" — the timestamp printed at the top of an
 * export. Uses the browser's own time zone and says which one it is, because
 * the file outlives the screen: a manager reading it tomorrow in another
 * state needs to know when "now" was.
 */
export function exportTimestamp(date: Date = new Date()): string {
  try {
    return new Intl.DateTimeFormat('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
      timeZoneName: 'short',
    }).format(date)
  } catch {
    return date.toString()
  }
}
