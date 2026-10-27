/**
 * "Email a group" (Admin › Users): pick who — everyone, every principal, one
 * rep group, or one rep — and open a blank draft in the admin's own mail
 * client with them all on Bcc. Pure, for tests/unit/broadcast.test.ts.
 *
 * Like the rest of lib/adoption.ts, nothing here sends anything: it is a
 * mailto: link. The admin's own address goes on To so the draft is never
 * To-less (some clients refuse, some spam filters frown), and everyone else
 * is on Bcc so nobody sees the list.
 */
import { emailList } from './adoption'

export type BroadcastAudience = 'everyone' | 'principals' | 'group' | 'rep'

export interface BroadcastProfile {
  user_id: string
  full_name: string | null
  email: string | null
  role: string | null
  active: boolean | null
  sales_rep_key: string | null
  rep_group_vendor_id: string | null
}

/**
 * Past about 2,000 characters some mail clients (classic Outlook through the
 * Windows shell, notably) cut a mailto: off mid-address. Above it the card
 * says so and offers "Copy emails" as the sure path.
 */
export const MAILTO_SAFE_LENGTH = 2000

const hasEmail = (p: BroadcastProfile) => !!(p.email ?? '').trim()

/** Same rule as session.isPrincipal: a rep carrying a rep-group vendor id. */
export function isPrincipal(p: Pick<BroadcastProfile, 'role' | 'rep_group_vendor_id'>): boolean {
  return p.role === 'rep' && !!(p.rep_group_vendor_id ?? '').trim()
}

/**
 * The rep group a user belongs to: the group they run (principals), else the
 * vendor their rep code sits under in dim_sales_rep. Null for neither.
 */
export function groupOf(
  p: Pick<BroadcastProfile, 'sales_rep_key' | 'rep_group_vendor_id'>,
  vendorByRepKey: Readonly<Record<string, string | null | undefined>>,
): string | null {
  const own = (p.rep_group_vendor_id ?? '').trim()
  if (own) return own
  const key = (p.sales_rep_key ?? '').trim()
  return (key && vendorByRepKey[key]?.trim()) || null
}

/** Every rep group with at least one active user who has an email, A→Z. */
export function repGroups(
  profiles: readonly BroadcastProfile[],
  vendorByRepKey: Readonly<Record<string, string | null | undefined>>,
): { vendor_id: string; count: number }[] {
  const counts = new Map<string, number>()
  for (const p of profiles) {
    if (p.active !== true || !hasEmail(p)) continue
    const g = groupOf(p, vendorByRepKey)
    if (g) counts.set(g, (counts.get(g) ?? 0) + 1)
  }
  return [...counts]
    .map(([vendor_id, count]) => ({ vendor_id, count }))
    .sort((a, b) => a.vendor_id.localeCompare(b.vendor_id))
}

/**
 * Who the draft goes to. Active users with an email only; `value` is the
 * vendor id for 'group' and the user_id for 'rep'. Sorted by name so the
 * preview list reads like a roster.
 */
export function recipients(
  profiles: readonly BroadcastProfile[],
  audience: BroadcastAudience,
  value: string,
  vendorByRepKey: Readonly<Record<string, string | null | undefined>>,
): BroadcastProfile[] {
  const active = profiles.filter((p) => p.active === true && hasEmail(p))
  let rows: BroadcastProfile[]
  switch (audience) {
    case 'everyone':
      rows = active
      break
    case 'principals':
      rows = active.filter(isPrincipal)
      break
    case 'group':
      rows = value ? active.filter((p) => groupOf(p, vendorByRepKey) === value) : []
      break
    case 'rep':
      rows = active.filter((p) => p.user_id === value)
      break
  }
  return [...rows].sort((a, b) =>
    (a.full_name || a.email || '').localeCompare(b.full_name || b.email || ''),
  )
}

/**
 * mailto: with the sender on To and everyone else on Bcc (the sender is
 * dropped from Bcc so they don't get it twice). Comma-separated, the RFC 6068
 * form every client reads in a URL; the "; " form is for pasting.
 */
export function bccMailto(
  rows: readonly Pick<BroadcastProfile, 'email'>[],
  senderEmail: string | null | undefined,
): string {
  const me = (senderEmail ?? '').trim()
  const bcc = emailList(rows.filter((r) => (r.email ?? '').trim().toLowerCase() !== me.toLowerCase()))
    .split('; ')
    .filter(Boolean)
    .map(encodeURIComponent)
    .join(',')
  return `mailto:${encodeURIComponent(me)}${bcc ? `?bcc=${bcc}` : ''}`
}
