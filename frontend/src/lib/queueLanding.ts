/**
 * Whether this tab has already sent inside sales from the Overview to the
 * entry queue (the landing in the router's guard). sessionStorage is per tab
 * and survives a reload, which is the point. Where it is unavailable
 * (blocked storage, some private modes) every arrival lands on the queue,
 * as it did before the flag.
 *
 * One key, shared by the router (which sets and reads it) and the session
 * store (which clears it on an explicit sign-out, so the next sign-in in the
 * same tab or installed app window, the next morning's included, starts in
 * the queue again).
 */
export const QUEUE_LANDING_KEY = 'rep-portal:landed-on-queue'

export function landedOnQueueThisTab(): boolean {
  try {
    return window.sessionStorage.getItem(QUEUE_LANDING_KEY) === '1'
  } catch {
    return false
  }
}

export function rememberQueueLanding(): void {
  try {
    window.sessionStorage.setItem(QUEUE_LANDING_KEY, '1')
  } catch {
    /* no storage: the next arrival lands on the queue again */
  }
}

/** On sign-out: the next person (or the same one tomorrow) lands on the queue. */
export function forgetQueueLanding(): void {
  try {
    window.sessionStorage.removeItem(QUEUE_LANDING_KEY)
  } catch {
    /* no storage: there was no flag to clear */
  }
}
