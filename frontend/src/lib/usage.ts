/**
 * What the team looks at, for Admin › Usage (public.usage_events,
 * 20261116130000).
 *
 * login_events says a rep opened the portal; this says where they went: one
 * `page_view` per screen (the route name, and the account when the screen is
 * one account's), plus the few actions worth counting on their own (a
 * download, "Who should I call?").
 *
 * Rules, the same as useUsagePing.ts:
 *   - Fire-and-forget. A failed log never costs the rep a frame, and nothing
 *     is retried: a dropped page view is a rounding error, a queue that
 *     replays yesterday's taps is a wrong number.
 *   - Never while an admin is viewing as a rep (the gate below; log_usage()
 *     refuses it too).
 *   - The server stamps who and when. The client only says what.
 *
 * Events are batched for a moment so a burst (land on a page, redirect, open
 * a sheet) is one request, and flushed when the tab is hidden so the last
 * page of a visit is not lost.
 */
import { supabase } from '@/lib/supabase'

export type UsageDevice = 'phone' | 'tablet' | 'desktop'

export interface UsageEvent {
  event: string
  page?: string | null
  customer_key?: string | null
  device?: UsageDevice | null
  detail?: Record<string, string | number | boolean | null> | null
}

/** Tailwind's sm / lg breakpoints: the same lines the layouts change at. */
export function deviceFor(width: number): UsageDevice {
  if (width < 640) return 'phone'
  if (width < 1024) return 'tablet'
  return 'desktop'
}

interface RouteLike {
  name?: unknown
  params?: Record<string, unknown>
  meta?: { public?: unknown; untracked?: unknown }
}

const param = (v: unknown): string => (Array.isArray(v) ? String(v[0] ?? '') : String(v ?? ''))

/**
 * The page view a navigation stands for, or null when it is not one: the
 * sign-in screens, the Terms / Privacy agreement screen (meta.untracked)
 * and unnamed routes are not use of the portal.
 */
export function pageViewFor(route: RouteLike): UsageEvent | null {
  if (typeof route.name !== 'string' || !route.name || route.meta?.public || route.meta?.untracked) {
    return null
  }
  const customerKey = param(route.params?.customerKey)
  const orderId = /^order-/.test(route.name) ? param(route.params?.id) : ''
  return {
    event: 'page_view',
    page: route.name,
    customer_key: customerKey || null,
    detail: orderId ? { order_id: orderId } : null,
  }
}

/**
 * Identity of a screen: the route and its params, not its query. Typing in a
 * search box or opening a help article in place rewrites the query on the
 * same screen, and must not count as another view.
 */
export function viewKey(route: RouteLike): string {
  const params = route.params ?? {}
  return `${String(route.name ?? '')}|${Object.keys(params)
    .sort()
    .map((k) => `${k}=${param(params[k])}`)
    .join('&')}`
}

/** A screen left open and come back to after this long is looked at again. */
export const REVIEW_AFTER_MS = 30 * 60_000

/** Section prefixes, so "Price Lists" under Intel and under Admin read apart. */
const SECTIONS: readonly [RegExp, string][] = [
  [/^intel-/, 'Intel'],
  [/^admin-/, 'Admin'],
  [/^orders?(-|$)/, 'Orders'],
]

/**
 * A route name in the words the nav uses: "Intel › In stock". `titles` is
 * route name → meta.title (from the router); a page that no longer exists
 * falls back to its stored name.
 */
export function pageLabel(page: string | null | undefined, titles: Readonly<Record<string, string>>): string {
  if (!page) return 'Unknown'
  const title = titles[page] ?? page
  const section = SECTIONS.find(([re]) => re.test(page))?.[1]
  return section && title !== section ? `${section} › ${title}` : title
}

/* ---- the tracker ------------------------------------------------------- */

const MAX_BATCH = 20
const FLUSH_MS = 500

let gate: () => boolean = () => false
let queue: UsageEvent[] = []
let timer: ReturnType<typeof setTimeout> | null = null

/** Set once, from useUsageTracking(): signed in, and not viewing as a rep. */
export function configureUsage(canTrack: () => boolean) {
  gate = canTrack
}

function currentDevice(): UsageDevice | null {
  return typeof window === 'undefined' ? null : deviceFor(window.innerWidth)
}

export function flushUsage() {
  if (timer) {
    clearTimeout(timer)
    timer = null
  }
  if (!queue.length) return
  const batch = queue
  queue = []
  // Signed out (or view-as started) between the tap and the flush: drop it.
  if (!gate()) return
  try {
    void supabase.rpc('log_usage' as never, { p_events: batch } as never).then(
      () => undefined,
      () => undefined,
    )
  } catch {
    /* never the rep's problem */
  }
}

export function trackUsage(event: UsageEvent) {
  if (!gate()) return
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return
  queue.push({ device: currentDevice(), ...event })
  if (queue.length >= MAX_BATCH) return flushUsage()
  timer ??= setTimeout(flushUsage, FLUSH_MS)
}

/**
 * An action on the current screen ("export", "who_to_call"). The page is
 * read off the URL-independent tracker state so callers (a shared download
 * button, a sheet) need not know which screen they sit on.
 */
let currentPage: { page: string | null; customer_key: string | null } = {
  page: null,
  customer_key: null,
}

export function setCurrentPage(view: UsageEvent | null) {
  currentPage = { page: view?.page ?? null, customer_key: view?.customer_key ?? null }
}

export function trackAction(event: string, detail?: UsageEvent['detail']) {
  trackUsage({ event, ...currentPage, detail: detail ?? null })
}
