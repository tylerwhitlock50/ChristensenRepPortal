import { computed, ref } from 'vue'
import { addDays, format } from 'date-fns'
import { useFeatureFlags } from '@/composables/useAppSettings'
import { useLogAccountAction } from '@/composables/useAccountData'
import { useCreateTask } from '@/composables/useTasks'
import { useSessionStore } from '@/stores/session'

/**
 * The quick call log (feature.quick_log, 20261013130000): tap Call on a
 * list, talk, come back to the app, and one tap says how it went.
 *
 * A tel: tap is not a conversation — the rep may cancel the dialler, get
 * voicemail, or never get through — so the tap itself writes nothing. It
 * only remembers a pending attempt. When the rep comes back (the tab was
 * hidden, or the window lost focus, for a few seconds) within half an hour,
 * CallOutcomeSheet asks "Reached them / Left a message / No answer", and only
 * that answer writes a public.actions row through useLogAccountAction, which
 * is what contact coverage counts. "Not now" drops it.
 *
 * State is module-level so any page can start an attempt and the one sheet
 * App.vue mounts can finish it: the call list today, the account header
 * tomorrow (noteCallTap is the whole integration). It is also kept in
 * localStorage, because a phone that is short on memory may discard the tab
 * during a long call and reload it on return.
 *
 * Off unless the flag is on AND the user can write — view-as is read-only.
 */

/** How long after the tap an outcome is still worth asking for. */
export const OUTCOME_WINDOW_MS = 30 * 60_000
/** Shorter than this away is a cancelled dialler prompt, not a call. */
export const MIN_AWAY_MS = 4_000

const STORAGE_KEY = 'rep-portal:quick-call'

export const CALL_OUTCOMES = ['reached', 'left_message', 'no_answer'] as const
export type CallOutcome = (typeof CALL_OUTCOMES)[number]

export const CALL_OUTCOME_LABELS: Record<CallOutcome, string> = {
  reached: 'Reached them',
  left_message: 'Left a message',
  no_answer: 'No answer',
}

export interface PendingCall {
  userId: string
  customerKey: string
  customerName: string
  /** Who was dialled, as the list showed it. Empty when unknown. */
  contactLabel: string
  /** Epoch ms of the tap. */
  at: number
}

/**
 * The note on the actions row — who and how it went, in the rep's words.
 * Pure, for the unit test and for anyone reading the account's history.
 */
export function outcomeNote(outcome: CallOutcome, contactLabel: string): string {
  const who = contactLabel.trim()
  switch (outcome) {
    case 'reached':
      return who ? `Reached ${who}` : 'Reached them'
    case 'left_message':
      return who ? `Left ${who} a message` : 'Left a message'
    case 'no_answer':
      return who ? `No answer from ${who}` : 'No answer'
  }
}

/** Pure: is a pending attempt from `at` still worth asking about? */
export function isOutcomeDue(at: number, now: number): boolean {
  return now >= at && now - at <= OUTCOME_WINDOW_MS
}

function load(): PendingCall | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return null
    const p = JSON.parse(raw) as PendingCall
    return p && typeof p.customerKey === 'string' && typeof p.at === 'number' ? p : null
  } catch {
    return null
  }
}

function save(p: PendingCall | null) {
  try {
    if (p) localStorage.setItem(STORAGE_KEY, JSON.stringify(p))
    else localStorage.removeItem(STORAGE_KEY)
  } catch {
    /* in memory only — fine unless the tab is discarded mid-call */
  }
}

/* ---- module state: one pending attempt, one sheet ------------------------ */

const pending = ref<PendingCall | null>(load())
const sheetOpen = ref(false)
/** When the rep left the app after the tap; null while they are here. */
let leftAt: number | null = null
let listening = false
/**
 * The mounted sheet's handlers. The document listeners are added once per
 * page load and call whichever sheet is mounted now — a sheet unmounted by
 * a sign-out must not keep answering with its stopped computeds.
 */
let active: { onLeave: () => void; onReturn: () => void } | null = null

function clearPending() {
  pending.value = null
  sheetOpen.value = false
  leftAt = null
  save(null)
}

function offerIfDue(userId: string | undefined) {
  const p = pending.value
  if (!p) return
  if (!userId || p.userId !== userId || !isOutcomeDue(p.at, Date.now())) {
    clearPending()
    return
  }
  sheetOpen.value = true
}

export function useQuickCallLog() {
  const flags = useFeatureFlags()
  const session = useSessionStore()
  const logAction = useLogAccountAction()
  const createTask = useCreateTask()

  const enabled = computed(() => flags.quickLog.value && session.canWrite)
  /** "Remind me next week" needs somewhere to put the reminder. */
  const remindAvailable = computed(() => flags.tasks.value)

  const saving = computed(() => logAction.isPending.value || createTask.isPending.value)
  const error = ref('')

  /** Call from the Call link's click. Never blocks or alters the tel: link. */
  function noteCallTap(input: {
    customerKey: string
    customerName: string
    contactLabel?: string | null
  }) {
    if (!enabled.value) return
    const userId = session.user?.id
    if (!userId) return
    pending.value = {
      userId,
      customerKey: input.customerKey,
      customerName: input.customerName,
      contactLabel: input.contactLabel?.trim() ?? '',
      at: Date.now(),
    }
    leftAt = null
    error.value = ''
    save(pending.value)
  }

  /** Back from the dialler: ask, if it looks like a call happened. */
  function onReturn() {
    if (!pending.value || !enabled.value || leftAt == null) return
    const away = Date.now() - leftAt
    leftAt = null
    if (away < MIN_AWAY_MS) return
    offerIfDue(session.user?.id)
  }

  function onLeave() {
    if (pending.value && leftAt == null) leftAt = Date.now()
  }

  const handlers = { onLeave, onReturn }

  /**
   * Makes this the sheet that answers, adding the return listeners on the
   * first call of the page load. Called by the sheet (mounted once, in
   * App.vue). A pending attempt that survived a reload is asked about
   * straight away: the reload itself means the rep left.
   */
  function install() {
    active = handlers
    if (!listening) {
      listening = true
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'hidden') active?.onLeave()
        else active?.onReturn()
      })
      // A desktop dialler (FaceTime, a softphone) takes focus without
      // hiding the tab.
      window.addEventListener('blur', () => active?.onLeave())
      window.addEventListener('focus', () => active?.onReturn())
    }
    if (pending.value && enabled.value) offerIfDue(session.user?.id)
  }

  function uninstall() {
    if (active === handlers) active = null
  }

  /** The flags load after boot; a restored attempt waits for them. */
  function recheckRestored() {
    if (pending.value && enabled.value && !sheetOpen.value && leftAt == null) {
      offerIfDue(session.user?.id)
    }
  }

  async function logOutcome(outcome: CallOutcome, remind: boolean) {
    const p = pending.value
    if (!p) return
    error.value = ''
    try {
      await logAction.mutateAsync({
        customerKey: p.customerKey,
        actionType: 'call',
        note: outcomeNote(outcome, p.contactLabel),
      })
    } catch (e) {
      error.value = (e as Error).message || "Couldn't save that. Try again."
      return
    }
    if (remind && remindAvailable.value) {
      try {
        await createTask.mutateAsync({
          title: `Follow up with ${p.customerName}`,
          dueDate: format(addDays(new Date(), 7), 'yyyy-MM-dd'),
          customerKey: p.customerKey,
        })
      } catch (e) {
        // The call is logged; say what did not happen rather than undo it.
        // The sheet stays up (with no attempt left to log) to show this.
        pending.value = null
        leftAt = null
        save(null)
        error.value = `The call is logged, but the reminder didn't save: ${(e as Error).message}`
        return
      }
    }
    clearPending()
  }

  return {
    enabled,
    remindAvailable,
    pending,
    sheetOpen,
    saving,
    error,
    noteCallTap,
    logOutcome,
    dismiss: clearPending,
    install,
    uninstall,
    recheckRestored,
  }
}
