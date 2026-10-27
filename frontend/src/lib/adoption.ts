/**
 * The "poke": reps who have an account but are not using it (Admin › Users,
 * "Not signed in yet"). Jayelynne chases them; this finds them and drafts
 * the nudge. Pure, for tests/unit/adoption.test.ts.
 *
 * Nothing here sends anything. The reminder is a mailto: draft the admin
 * sends from their own mail client, the same way the new-user login email
 * is — the portal has no mailer, and it must never fire a password reset on
 * someone else's behalf (Outlook's link scanner burns those one-shot links
 * before the rep ever sees them). The email points the rep at "Forgot your
 * password?" on the sign-in page instead, which they trigger themselves.
 */

/** "Not in 14 days" — about two working weeks without opening it. */
export const NOT_SIGNED_IN_DAYS = 14

export type NotSignedInMode = 'never' | 'stale'

export interface AdoptionProfile {
  user_id: string
  full_name: string | null
  email: string | null
  role: string | null
  active: boolean | null
}

export interface NotSignedInRow {
  user_id: string
  full_name: string | null
  email: string | null
  /** Newest sign-in (v_rep_activity.last_login_at); null = never. */
  last_login_at: string | null
}

/**
 * Active reps who never signed in ('never'), or who have not in the last
 * `days` ('stale', which includes never). Admins and order-entry users are
 * not chased: the list is for the field. Never-signed-in first, then the
 * longest-quiet, then by name.
 */
export function notSignedIn(
  profiles: readonly AdoptionProfile[],
  lastLoginByUser: Readonly<Record<string, string | null | undefined>>,
  mode: NotSignedInMode,
  now: Date = new Date(),
  days: number = NOT_SIGNED_IN_DAYS,
): NotSignedInRow[] {
  const cutoff = now.getTime() - days * 86_400_000
  return profiles
    .filter((p) => p.role === 'rep' && p.active === true)
    .map((p) => ({
      user_id: p.user_id,
      full_name: p.full_name,
      email: p.email,
      last_login_at: lastLoginByUser[p.user_id] ?? null,
    }))
    .filter((r) => {
      if (!r.last_login_at) return true
      if (mode === 'never') return false
      const at = Date.parse(r.last_login_at)
      return !Number.isFinite(at) || at < cutoff
    })
    .sort(
      (a, b) =>
        Number(!!a.last_login_at) - Number(!!b.last_login_at) ||
        (a.last_login_at ?? '').localeCompare(b.last_login_at ?? '') ||
        (a.full_name ?? a.email ?? '').localeCompare(b.full_name ?? b.email ?? ''),
    )
}

/** First word of a name, or the fallback — "Hi Jim," / the admin's sign-off. */
export function firstName(fullName: string | null | undefined, fallback = ''): string {
  return (fullName ?? '').trim().split(/\s+/)[0] || fallback
}

/**
 * A mailto: reminder for one rep, in the voice of the new-user login email
 * (AdminUsersView: "Draft the email"): first names both ends, the portal
 * link, what they can do there, and how to get a new password themselves.
 * No password is ever in it.
 */
export function reminderMailto(
  rep: Pick<NotSignedInRow, 'full_name' | 'email'>,
  senderFullName: string | null | undefined,
  portalUrl: string,
): string {
  const subject = 'Your Christensen Arms field rep portal is ready for you'
  const body =
    `Hi ${firstName(rep.full_name, 'there')},\n\n` +
    `Just a quick reminder that your Christensen Arms field rep portal is set up and ` +
    `waiting for you:\n${portalUrl}\n\n` +
    `Sign in with this email address${rep.email ? ` (${rep.email})` : ''}. Once you're in, ` +
    `you can see what's in stock right now, your accounts' open orders and shipments ` +
    `(with tracking), order history, and how each account is pacing against its goal — ` +
    `on your phone or your laptop.\n\n` +
    `If you don't have your password, or it doesn't work, use "Forgot your password?" on ` +
    `the sign-in page and you'll get an email to set a new one.\n\n` +
    `If anything gives you trouble, just reply to this email and I'll get you sorted out.\n\n` +
    `Thanks,\n${firstName(senderFullName)}\n`
  return `mailto:${encodeURIComponent(rep.email ?? '')}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`
}

/**
 * Every address on the list, once, "; "-separated — what Outlook's To/Bcc
 * box takes from a paste (other clients accept it too).
 */
export function emailList(rows: readonly Pick<NotSignedInRow, 'email'>[]): string {
  const seen = new Set<string>()
  const out: string[] = []
  for (const r of rows) {
    const e = (r.email ?? '').trim()
    if (!e || seen.has(e.toLowerCase())) continue
    seen.add(e.toLowerCase())
    out.push(e)
  }
  return out.join('; ')
}
