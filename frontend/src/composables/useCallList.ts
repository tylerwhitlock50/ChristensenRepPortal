import { computed, ref } from 'vue'
import { useMutation, useQuery, useQueryClient } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import { isMissingDbObject, supabase } from '@/lib/supabase'
import {
  observeAccount,
  useTerritoryAccounts,
  worthInvestigating,
  type TerritoryAccountRow,
} from '@/composables/useOverview'
import type { AccountSignalRow } from '@/composables/useAccountSignals'
import { useBestContacts } from '@/composables/useBestContacts'
import { useSessionStore } from '@/stores/session'
import { humanize } from '@/lib/format'
import { parseFactors, rowChips, topReasons, type ReasonChip, type ScoreFactors } from '@/lib/scoreReasons'

/**
 * "Worth a call today" — the Overview's morning list.
 *
 * Built on the score the app already computes every night: public.
 * account_signals (019), ordered by score, which 020's generator and the
 * admin's Settings tuning both drive. Until now no screen a rep sees read
 * that ranking; this is it, in observation voice. Each row says why it is
 * there (the score's own top two reasons, lib/scoreReasons.ts), with the
 * money and town from the territory rows the Overview already holds and the
 * buyer's number from useBestContacts.
 *
 * Nothing here is assigned. A rep can react ("On it", "Already handled",
 * "Not relevant ▸ why") and the account leaves THEIR list for a while; that
 * is the whole effect (public.call_list_feedback, 20261013130000).
 *
 * Degrades in two steps:
 *   - no signals (019 never applied, or the nightly score has not run for
 *     this book) → the classifier list the Overview has always shown
 *     (worthInvestigating), same row shape;
 *   - no call_list_feedback table (tonight's migration not applied) → no
 *     reaction menu and nothing hidden.
 */

/** account_signals / call_list_feedback postdate database.types.ts. */
const db = supabase as unknown as SupabaseClient

/* ------------------------------------------------------------ vocabulary */

export const CALL_LIST_REACTIONS = ['on_it', 'handled', 'not_relevant'] as const
export type CallListReaction = (typeof CALL_LIST_REACTIONS)[number]

/** Mirrors the CHECK on call_list_feedback.reason. */
export const CALL_LIST_REASONS = [
  'seasonal',
  'store_closed',
  'buys_elsewhere',
  'wrong_data',
  'other',
] as const
export type CallListReason = (typeof CALL_LIST_REASONS)[number]

/**
 * How long a reaction keeps the account off the rep's list. Client-side on
 * purpose (the migration header says why): tuning these is a deploy, not a
 * migration.
 */
export const REACTION_WINDOW_DAYS: Record<CallListReaction, number> = {
  on_it: 3,
  handled: 14,
  not_relevant: 45,
}

export const REACTION_LABELS: Record<CallListReaction, string> = {
  on_it: 'On it',
  handled: 'Already handled',
  not_relevant: 'Not relevant',
}

export const REASON_LABELS: Record<CallListReason, string> = {
  seasonal: 'Seasonal',
  store_closed: 'Store closed',
  buys_elsewhere: 'Buys elsewhere',
  wrong_data: 'Wrong data',
  other: 'Other',
}

/** Shown, then "Show more" up to MAX_ROWS. */
export const VISIBLE_ROWS = 10
export const MAX_ROWS = 25
/**
 * Signals fetched per load. More than MAX_ROWS so reactions and low-priority
 * rows can drop out and still leave a full list.
 */
const FETCH_ROWS = 40

const STALE_TIME = 10 * 60_000
const DAY_MS = 86_400_000

/**
 * Local keys, same shapes as lib/queryClient.ts. The ranking is the whole
 * book (RLS-scoped) like the other ['intel', …] reads; reactions are the
 * acting user's own rows, so their key carries that user.
 */
export const callListKeys = {
  signals: () => ['intel', 'call-list'] as const,
  feedbackRoot: () => ['call-list', 'feedback'] as const,
  feedback: (userId: string) => ['call-list', 'feedback', userId] as const,
  deactivations: () => ['call-list', 'deactivations'] as const,
}

/* ------------------------------------------------------------------- rows */

/** An account_signals row plus its factor blob — what the list ranks on. */
export interface CallListSignal extends AccountSignalRow {
  factors: ScoreFactors
}

export interface CallListFeedbackRow {
  id: number
  customer_key: string
  reaction: CallListReaction
  reason: CallListReason | null
  created_at: string
}

export interface CallListRow {
  customer_key: string
  customer_name: string
  /** "Bozeman, MT", or '' when the ERP has no town. */
  place: string
  /** Null when the account is not in the territory rows (money unknown). */
  revenue_ytd: number | null
  revenue_prior_ytd: number | null
  /** 0..100, or null on a fallback row. */
  score: number | null
  chips: ReasonChip[]
}

function num(value: unknown): number | null {
  if (value == null) return null
  const n = Number(value)
  return Number.isFinite(n) ? n : null
}

function mapSignal(r: Record<string, unknown>): CallListSignal {
  return {
    customer_key: String(r.customer_key),
    cadence_days: num(r.cadence_days),
    cadence_confident: r.cadence_confident === true,
    days_since_order: num(r.days_since_order),
    last_order_date: (r.last_order_date as string | null) ?? null,
    order_days_24m: num(r.order_days_24m),
    families_12m: num(r.families_12m),
    families_prior_12m: num(r.families_prior_12m),
    families_dropped: num(r.families_dropped),
    yoy_change: num(r.yoy_change),
    revenue_12m: num(r.revenue_12m),
    revenue_percentile: num(r.revenue_percentile),
    score: num(r.score),
    priority: (r.priority as AccountSignalRow['priority']) ?? null,
    factors: parseFactors(r.factors),
  }
}

function placeOf(r: Pick<TerritoryAccountRow, 'sold_to_city' | 'sold_to_state'> | undefined): string {
  if (!r) return ''
  return [r.sold_to_city ? humanize(r.sold_to_city) : null, r.sold_to_state]
    .filter((v) => v && v !== '—')
    .join(', ')
}

/* ---------------------------------------------------- derivations (pure) */

/**
 * Accounts the rep has reacted to recently enough that they stay off the
 * list. Any reaction still inside its own window hides the account; Undo
 * deletes the row, so there is never a stale one to argue with.
 */
export function hiddenByReaction(
  rows: readonly CallListFeedbackRow[],
  now: number = Date.now(),
): Set<string> {
  const hidden = new Set<string>()
  for (const r of rows) {
    const at = Date.parse(r.created_at)
    if (!Number.isFinite(at)) continue
    const windowDays = REACTION_WINDOW_DAYS[r.reaction]
    if (windowDays == null) continue
    if (now - at < windowDays * DAY_MS) hidden.add(r.customer_key)
  }
  return hidden
}

/**
 * The ranked list. Signals arrive score-descending; this drops what should
 * not be called about today and dresses the rest for display:
 *   - priority 'low' (below the admin's low band) or no score — the long
 *     tail is not "worth a call", it is the rest of the book;
 *   - accounts the rep reacted to (hiddenByReaction);
 *   - accounts missing from the territory rows once those have loaded —
 *     the ERP has marked them inactive since last night's score, or they
 *     have left this rep's book.
 * Deactivated accounts never get here: deactivating deletes the signals
 * row on the spot (023).
 */
export function buildCallList(
  signals: readonly CallListSignal[],
  territory: ReadonlyMap<string, TerritoryAccountRow> | null,
  hidden: ReadonlySet<string>,
  today: Date = new Date(),
  limit = MAX_ROWS,
): CallListRow[] {
  const out: CallListRow[] = []
  for (const s of signals) {
    if (out.length >= limit) break
    if (s.score == null || s.priority == null || s.priority === 'low') continue
    if (hidden.has(s.customer_key)) continue
    const t = territory?.get(s.customer_key)
    if (territory && !t) continue
    const observation = t ? observeAccount(t, s, today) : null
    out.push({
      customer_key: s.customer_key,
      customer_name: t?.customer_name || s.customer_key,
      place: placeOf(t),
      revenue_ytd: t ? t.revenue_ytd : null,
      revenue_prior_ytd: t ? t.revenue_prior_ytd : null,
      score: s.score,
      chips: rowChips(topReasons(s.factors, 2), observation),
    })
  }
  return out
}

/**
 * No ranking to read: the classifier the Overview has always used, as call
 * list rows. One chip each — the observation is the reason.
 */
export function fallbackCallList(
  territoryRows: readonly TerritoryAccountRow[],
  hidden: ReadonlySet<string>,
  deactivated: ReadonlySet<string>,
  today: Date = new Date(),
  limit = MAX_ROWS,
): CallListRow[] {
  const eligible = territoryRows.filter(
    (r) => !hidden.has(r.customer_key) && !deactivated.has(r.customer_key),
  )
  const byKey = new Map(eligible.map((r) => [r.customer_key, r]))
  return worthInvestigating(eligible, limit, today).map((o) => {
    const t = byKey.get(o.customer_key)
    return {
      customer_key: o.customer_key,
      customer_name: o.customer_name,
      place: placeOf(t),
      revenue_ytd: t ? t.revenue_ytd : null,
      revenue_prior_ytd: t ? t.revenue_prior_ytd : null,
      score: null,
      chips: rowChips([], { kind: o.kind, chip: o.chip }),
    }
  })
}

/* -------------------------------------------------------------- queries */

const SIGNAL_COLUMNS =
  'customer_key, cadence_days, cadence_confident, days_since_order, ' +
  'last_order_date, order_days_24m, families_12m, families_prior_12m, ' +
  'families_dropped, yoy_change, revenue_12m, revenue_percentile, score, ' +
  'priority, factors'

function retryUnlessMissing(failureCount: number, error: unknown): boolean {
  return !isMissingDbObject(error) && failureCount < 1
}

/**
 * The top of the ranking with the factor blob. Deliberately its own small
 * query: useTerritorySignals() leaves `factors` out to keep an admin's
 * whole-book download small, and the list only needs the top few dozen.
 * Unfiltered — RLS on account_signals is the territory filter.
 *
 * Null means "no signals table here" (fall back); [] means "nothing scored".
 */
function useCallListSignals() {
  return useQuery({
    queryKey: callListKeys.signals(),
    staleTime: STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<CallListSignal[] | null> => {
      const { data, error } = await db
        .from('account_signals')
        .select(SIGNAL_COLUMNS)
        .not('score', 'is', null)
        .order('score', { ascending: false })
        .order('customer_key') // stable ties
        .limit(FETCH_ROWS)
      if (error) {
        if (isMissingDbObject(error)) return null
        throw error
      }
      return ((data ?? []) as unknown as Record<string, unknown>[]).map(mapSignal)
    },
  })
}

/**
 * The acting user's reactions inside the longest window. Filtered to that
 * user even though RLS would allow more: an admin's policy reads everyone's
 * rows, and another rep's "not relevant" must not empty the admin's list.
 *
 * Null means the table is not there (migration not applied): hide the menu.
 */
function useCallListFeedback() {
  const session = useSessionStore()
  /** Whose list this is: the rep being viewed as, otherwise me. */
  const userId = computed(
    () => (session.isViewingAs ? session.acting?.target_user_id : null) ?? session.user?.id ?? '',
  )
  const longest = Math.max(...Object.values(REACTION_WINDOW_DAYS))
  const query = useQuery({
    queryKey: computed(() => callListKeys.feedback(userId.value)),
    enabled: computed(() => !!userId.value),
    staleTime: STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<CallListFeedbackRow[] | null> => {
      const since = new Date(Date.now() - longest * DAY_MS).toISOString()
      const { data, error } = await db
        .from('call_list_feedback')
        .select('id, customer_key, reaction, reason, created_at')
        .eq('user_id', userId.value)
        .gte('created_at', since)
        .order('created_at', { ascending: false })
        .limit(500)
      if (error) {
        if (isMissingDbObject(error)) return null
        throw error
      }
      return (data ?? []) as unknown as CallListFeedbackRow[]
    },
  })
  return { ...query, userId }
}

/**
 * Open deactivations, for the fallback list only — the ranked list never
 * sees a deactivated account (023 deletes its signals row). A handful of
 * rows. Missing table (023 not applied) = nothing deactivated.
 */
function useOpenDeactivations(enabled: () => boolean) {
  return useQuery({
    queryKey: callListKeys.deactivations(),
    enabled: computed(enabled),
    staleTime: STALE_TIME,
    retry: retryUnlessMissing,
    queryFn: async (): Promise<string[]> => {
      const { data, error } = await db
        .from('account_deactivations')
        .select('customer_key')
        .is('reactivated_at', null)
      if (error) {
        if (isMissingDbObject(error)) return []
        throw error
      }
      return ((data ?? []) as { customer_key: string }[]).map((r) => r.customer_key)
    },
  })
}

/**
 * The Overview's call list: rows, the reach (Call / Directions) for every
 * row, and whether reactions can be offered.
 */
export function useCallList() {
  const territory = useTerritoryAccounts() // same key as the Overview: a cache hit
  const signals = useCallListSignals()
  const feedback = useCallListFeedback()

  /** Bumped after a reaction so the hide windows are measured from now. */
  const now = ref(Date.now())

  const usingFallback = computed(() => {
    const s = signals.data.value
    return s === null || (Array.isArray(s) && s.length === 0)
  })
  const deactivations = useOpenDeactivations(
    () => usingFallback.value && signals.isSuccess.value,
  )

  const territoryMap = computed(() => {
    const rows = territory.data.value
    return rows ? new Map(rows.map((r) => [r.customer_key, r])) : null
  })
  const hidden = computed(() => hiddenByReaction(feedback.data.value ?? [], now.value))

  const rows = computed<CallListRow[]>(() => {
    if (usingFallback.value) {
      return fallbackCallList(
        territory.data.value ?? [],
        hidden.value,
        new Set(deactivations.data.value ?? []),
      )
    }
    return buildCallList(signals.data.value ?? [], territoryMap.value, hidden.value)
  })

  // One request for every row's contacts and address, not one per row —
  // and the same key whether ten or twenty-five rows are showing.
  const keys = computed(() => rows.value.map((r) => r.customer_key))
  const reach = useBestContacts(keys)

  /** False on a database without call_list_feedback: no menu at all. */
  const reactionsAvailable = computed(
    () => feedback.isSuccess.value && feedback.data.value !== null,
  )

  /** The list is ready once its source is: signals, or the fallback's inputs. */
  const isPending = computed(
    () =>
      signals.isPending.value ||
      territory.isPending.value ||
      // Wait for the reactions too, or hidden rows flash in and drop out.
      (!!feedback.userId.value && feedback.isPending.value) ||
      (usingFallback.value && deactivations.isPending.value),
  )

  return {
    rows,
    reach,
    signals,
    feedback,
    territory,
    usingFallback,
    reactionsAvailable,
    isPending,
    refreshWindows: () => (now.value = Date.now()),
  }
}

/* -------------------------------------------------------------- writes */

/**
 * React to a row. Optimistic: the account leaves the list on tap, and comes
 * back if the write fails. The returned row's id is what Undo deletes.
 */
export function useReactToCallList() {
  const qc = useQueryClient()
  const session = useSessionStore()

  return useMutation({
    mutationFn: async (input: {
      customerKey: string
      reaction: CallListReaction
      reason?: CallListReason | null
    }): Promise<CallListFeedbackRow> => {
      const { data, error } = await db
        .from('call_list_feedback')
        .insert({
          customer_key: input.customerKey,
          reaction: input.reaction,
          reason: input.reaction === 'not_relevant' ? (input.reason ?? null) : null,
        })
        .select('id, customer_key, reaction, reason, created_at')
        .single()
      if (error) throw error
      return data as unknown as CallListFeedbackRow
    },
    onMutate: async (input) => {
      const key = callListKeys.feedback(session.user?.id ?? '')
      await qc.cancelQueries({ queryKey: key })
      const previous = qc.getQueryData<CallListFeedbackRow[] | null>(key)
      const optimistic: CallListFeedbackRow = {
        id: -Date.now(),
        customer_key: input.customerKey,
        reaction: input.reaction,
        reason: input.reaction === 'not_relevant' ? (input.reason ?? null) : null,
        created_at: new Date().toISOString(),
      }
      qc.setQueryData<CallListFeedbackRow[] | null>(key, [optimistic, ...(previous ?? [])])
      return { key, previous, optimisticId: optimistic.id }
    },
    onError: (_e, _input, ctx) => {
      if (ctx) qc.setQueryData(ctx.key, ctx.previous)
    },
    onSuccess: (row, _input, ctx) => {
      if (!ctx) return
      qc.setQueryData<CallListFeedbackRow[] | null>(ctx.key, (prev) =>
        (prev ?? []).map((r) => (r.id === ctx.optimisticId ? row : r)),
      )
    },
  })
}

/** Undo a reaction just made: delete the row, the account returns. */
export function useUndoCallListReaction() {
  const qc = useQueryClient()
  const session = useSessionStore()

  return useMutation({
    mutationFn: async (input: { id: number }) => {
      const { error } = await db.from('call_list_feedback').delete().eq('id', input.id)
      if (error) throw error
    },
    onSuccess: (_d, input) => {
      qc.setQueryData<CallListFeedbackRow[] | null>(
        callListKeys.feedback(session.user?.id ?? ''),
        (prev) => (prev ?? []).filter((r) => r.id !== input.id),
      )
    },
  })
}
