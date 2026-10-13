<script setup lang="ts">
import { computed, defineAsyncComponent, nextTick, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { useOnline } from '@vueuse/core'
import { useQueryClient } from '@tanstack/vue-query'
import { useSessionStore } from '@/stores/session'
import { useAccount } from '@/composables/useAccounts'
import { useAccountRecommendations } from '@/composables/useRecommendations'
import {
  useAccountActions,
  useAddNote,
  useContacts,
  useLogAccountAction,
  useNotes,
} from '@/composables/useAccountData'
import { useAccountRevenueMonthly } from '@/composables/useAccountMetrics'
import { buildAccountReach } from '@/composables/useBestContacts'
import { useFeatureFlags } from '@/composables/useAppSettings'
import { useAccountGoal } from '@/composables/useAccountGoals'
import { useQuickCallLog } from '@/composables/useQuickCallLog'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import RecommendationCard from '@/components/RecommendationCard.vue'
import AccountSummaryCard from '@/components/AccountSummaryCard.vue'
import AccountShipReadiness from '@/components/AccountShipReadiness.vue'
import AccountAiSummaryCard from '@/components/AccountAiSummaryCard.vue'
import AiFeedbackThumbs from '@/components/AiFeedbackThumbs.vue'
import BeforeYouCallCard from '@/components/BeforeYouCallCard.vue'
/**
 * chart.js is roughly two thirds of this route's bundle, and this is the page
 * a rep opens standing in a store on LTE. Async-loaded so the numbers, orders
 * and the visit survey paint without waiting on the charting library.
 */
const AccountRevenueChart = defineAsyncComponent(
  () => import('@/components/AccountRevenueChart.vue'),
)
/* The survey (vee-validate + zod) and the photo picker (image compression)
   render only while feature.visits is on and the rep taps into them, so
   they load with the panel rather than with every account open. Template
   refs still reach the inner component once it has loaded. */
const VisitSurvey = defineAsyncComponent(() => import('@/components/VisitSurvey.vue'))
const PhotoPicker = defineAsyncComponent(() => import('@/components/PhotoPicker.vue'))
import type VisitSurveyComponent from '@/components/VisitSurvey.vue'
import type PhotoPickerComponent from '@/components/PhotoPicker.vue'
import AccountOrdersCard from '@/components/AccountOrdersCard.vue'
import AccountSkuSalesCard from '@/components/AccountSkuSalesCard.vue'
import AccountBacklogCard from '@/components/AccountBacklogCard.vue'
import AccountOpportunityCard from '@/components/AccountOpportunityCard.vue'
import AccountQuickActions, { type QuickLink } from '@/components/AccountQuickActions.vue'
import AccountTasksCard from '@/components/AccountTasksCard.vue'
import ContactsCard from '@/components/ContactsCard.vue'
import VisitHistoryCard from '@/components/VisitHistoryCard.vue'
import { useDraft, visitDraftKey } from '@/lib/drafts'
import { enqueue, type QueuedPhoto } from '@/lib/submitQueue'
import {
  isVisitFormEmpty,
  makeVisitFormValues,
  type VisitFormValues,
} from '@/lib/visitSchema'
import { qk } from '@/lib/queryClient'
import {
  ACTION_LABELS,
  ACTION_TYPES,
  DEACTIVATION_REASONS,
  DEACTIVATION_REASON_LABELS,
  type ActionType,
  type DeactivationReason,
  type QuickAction,
} from '@/types/domain'
import {
  useAccountDeactivation,
  useDeactivateAccount,
  useReactivateAccount,
} from '@/composables/useAccountStatus'
import { isCreditBlocked } from '@/lib/ffl'
import { daysAgo, humanize, money, shortDate, telHref } from '@/lib/format'

const props = defineProps<{ customerKey: string }>()
const key = computed(() => props.customerKey)

const qc = useQueryClient()
const online = useOnline()
const session = useSessionStore()

/* Data-first restructure: the capture surfaces on this page (recommendations,
   survey + photos, log-a-contact + notes + activity) render only while their
   admin flags are on. Data underneath is untouched — flipping a flag back on
   restores everything. */
const flags = useFeatureFlags()

/* The quick-action strip only offers chips whose target panels exist under
   the current flags. Summary is data-side and always available.

   The other five each end in a write, so an admin viewing as a rep gets
   none of them. The database would refuse anyway (20260816140000), but
   refusing after someone has filled in a visit survey is not the same as
   not offering it. Summary stays: it only scrolls, and while viewing as a
   rep the card it lands on shows the cached brief without its Summarize
   button. The link chips below write nothing either, and stay too. */
const quickActions = computed<QuickAction[]>(() => {
  const list: QuickAction[] = ['summary']
  if (!session.canWrite) return list
  if (flags.visits.value) list.push('visit', 'photo')
  if (flags.actionLogging.value) list.push('contact', 'note')
  if (flags.tasks.value) list.push('task')
  return list
})

const account = useAccount(key)
/* Started here rather than inside the chart: the chart is an async chunk,
   and a query that lives in it would wait for chart.js to download before
   even asking. Same key, so the chart's own call is a cache hit. */
useAccountRevenueMonthly(key)
/* Each of these feeds a section that renders only under its flag; with the
   flag off they used to run on every account open regardless. */
const recs = useAccountRecommendations(key, { enabled: flags.recommendations })
const notes = useNotes(key, { enabled: flags.actionLogging })
const actions = useAccountActions(key, { enabled: flags.actionLogging })

/**
 * Who to call, and where they are. The ERP's is_primary contact is, for
 * about half of dealers, an INVOICE / accounts-payable mailbox with no
 * phone, and the real buyer sits further down; lib/contacts.ts ranks the
 * rows (a rep's go-to contact first, billing and our own staff never) and
 * this takes the top one. Built from the two queries the page already runs
 * — the contacts list (ContactsCard reads the same one, so the header and
 * the card's first row always agree) and dim_customer, which carries the
 * invoice/statement emails ranking uses and the sold-to street address.
 */
const contacts = useContacts(key)
const reach = computed(() =>
  buildAccountReach(props.customerKey, contacts.data.value ?? [], account.data.value),
)
const buyer = computed(() => reach.value.best.contact)

/* The header Call button feeds the quick call log (feature.quick_log) like
   the Overview's call list does: the global sheet asks "how did it go?" when
   the rep comes back from the dialler. No preventDefault — the tel: link
   dials as before; with the flag off this records nothing. */
const quickLog = useQuickCallLog()
function noteCallTap() {
  quickLog.noteCallTap({
    customerKey: props.customerKey,
    customerName: title.value,
    contactLabel: buyer.value?.label ?? '',
  })
}

/** Directions, Email, New order: chips that leave the page. */
const headerLinks = computed<QuickLink[]>(() => {
  const links: QuickLink[] = []
  if (reach.value.directionsUrl) {
    links.push({
      id: 'directions',
      label: 'Directions',
      icon: 'directions',
      href: reach.value.directionsUrl,
      external: true,
    })
  }
  const b = buyer.value
  if (b?.email && !b.do_not_email) {
    links.push({ id: 'email', label: 'Email', icon: 'email', href: `mailto:${b.email}` })
  }
  if (flags.orders.value && session.canWrite) {
    links.push({
      id: 'order',
      label: 'New order',
      icon: 'order',
      to: { name: 'orders-new', query: { customer: props.customerKey } },
    })
  }
  return links
})

/**
 * The header's Goal tile. Same query AccountGoalPanel runs in the Performance
 * card below — vue-query dedupes it — so the two can never show different
 * numbers. The rep's goal wins when it exists; the ERP field is the fallback
 * and stays named either way.
 */
const goal = useAccountGoal(key)
const displayGoal = computed(
  () => goal.data.value?.target_amount ?? account.data.value?.yearly_sales_goal ?? null,
)
const goalSource = computed(() => {
  const erp = goal.data.value?.erp_yearly_sales_goal ?? account.data.value?.yearly_sales_goal
  if (goal.data.value) {
    return erp != null ? `your goal · ERP ${money(erp)}` : 'your goal'
  }
  return erp != null ? 'from ERP' : 'not set'
})

/** Colours the header's Credit tile; the full story is in AccountShipReadiness. */
const creditBlocked = computed(() =>
  isCreditBlocked(account.data.value?.credit_status),
)

const openRecs = computed(
  () => (recs.data.value ?? []).filter((r) => r.status === 'open' || r.status === 'acted'),
)

const title = computed(
  () => account.data.value?.customer_name || props.customerKey,
)

const place = computed(() => {
  const a = account.data.value
  if (!a) return ''
  return [humanize(a.sold_to_city), a.sold_to_state]
    .filter((v) => v && v !== '—')
    .join(', ')
})

/* ---- log a contact ------------------------------------------------------ */
const logging = ref(false)
const actionType = ref<ActionType>('call')
const actionNote = ref('')
const logMutation = useLogAccountAction()
const logError = ref('')

async function submitLog() {
  logError.value = ''
  try {
    await logMutation.mutateAsync({
      customerKey: props.customerKey,
      actionType: actionType.value,
      note: actionNote.value,
    })
    actionNote.value = ''
    logging.value = false
  } catch (e) {
    logError.value = (e as Error).message || 'Could not save that.'
  }
}

/* ---- visit survey -------------------------------------------------------
   The survey owns its own form and its own submit; this page owns the panel,
   the draft on disk, and the offline escape hatch.

   Draft: every edit comes back out through `change`, goes into `useDraft`
   (debounced, IndexedDB) and goes back in through `initialValues` after a
   restore. It is deleted in exactly two places — a successful save and a
   successful enqueue.
------------------------------------------------------------------------- */
const surveyOpen = ref(false)
const savedVisitId = ref<number | null>(null)
const queuedNotice = ref(false)

/**
 * Set when the survey was reached from a mission's "Do the visit survey"
 * button (?survey=<recommendation id>). It rides the action insert, which
 * fires trg_action_marks_acted and advances the mission — online and via
 * the offline queue alike.
 */
const surveyRecommendationId = ref<number | null>(null)
const surveySection = ref<HTMLElement | null>(null)
const route = useRoute()

// Keyed by user as well as account: IndexedDB is per-device, so an unscoped
// key hands the next rep on a shared phone the previous rep's draft.
const survey = ref<InstanceType<typeof VisitSurveyComponent> | null>(null)
const draftKey = computed(() => visitDraftKey(key.value, session.user?.id))
const {
  state: draftValues,
  restored: draftRestored,
  restoring: draftRestoring,
  discard: discardDraft,
} = useDraft<VisitFormValues>(draftKey, {
  initial: () => makeVisitFormValues(),
})

/** An unfinished survey only counts if the rep actually answered something. */
const hasDraft = computed(
  () =>
    draftRestored.value &&
    !draftRestoring.value &&
    !isVisitFormEmpty(makeVisitFormValues(draftValues.value)),
)

function onSurveyChange(values: VisitFormValues) {
  draftValues.value = values
}

function openSurvey() {
  savedVisitId.value = null
  queuedNotice.value = false
  offlineError.value = ''
  // A fresh picker mounts with the panel, so anything still held here is
  // from a previous survey and must not ride along with this one.
  pendingSurveyPhotos.value = []
  surveyOpen.value = true
}

async function onVisitSubmitted(visitId: number) {
  savedVisitId.value = visitId
  // The survey stays open on its own "Visit saved" panel so photos can be
  // attached to the real visit id; only the draft goes away here.
  await discardDraft()
  pendingSurveyPhotos.value = []
}

function closeSurvey() {
  surveyOpen.value = false
  savedVisitId.value = null
  surveyRecommendationId.value = null
  pendingSurveyPhotos.value = []
}

/* Photos taken inside the survey. Online they upload themselves; offline the
   picker holds them and they travel with the queued survey. */
const picker = ref<InstanceType<typeof PhotoPickerComponent> | null>(null)
const pendingSurveyPhotos = ref<QueuedPhoto[]>([])

function onSurveyPhotosPending(photos: QueuedPhoto[]) {
  pendingSurveyPhotos.value = photos
}

function invalidateAccount() {
  void qc.invalidateQueries({ queryKey: qk.account.root(props.customerKey) })
}

/* Offline escape hatch (TECH_STACK §2.5). The survey's own Save posts straight
   to Postgres and will fail on a dead cell; this parks the whole thing —
   answers and photo blobs — in IndexedDB and lets the queue send it later.
   Nothing is ever dropped, so the rep can walk out of the store. */
const offlineSaving = ref(false)
const offlineError = ref('')

async function saveVisitForLater() {
  offlineSaving.value = true
  offlineError.value = ''
  try {
    const values = makeVisitFormValues(draftValues.value)
    const userId = session.user?.id
    if (!userId) throw new Error('You are signed out. Sign in and try again.')
    await enqueue({
      // Stamped so this never flushes under a different rep's JWT.
      userId,
      customerKey: props.customerKey,
      visit: {
        customer_key: props.customerKey,
        visit_type: values.visit_type,
        visit_date: values.visit_date,
        inventory_level: values.inventory_level,
        store_condition: values.store_condition,
        display_quality: values.display_quality,
        staff_knowledge: values.staff_knowledge,
        store_traffic: values.store_traffic,
        competitor_promos: values.competitor_promos,
        competition_seen: [...values.competition_seen],
        comments: values.comments?.trim() || null,
      },
      // Coverage counts actions, not visits — queue both or the stop never
      // happened as far as the execution report is concerned.
      action: {
        actionType: 'visit',
        note: values.comments,
        // Carries the mission this survey clears, if it came from one.
        recommendationId: surveyRecommendationId.value,
        // The day the rep was in the store, not the day the phone reconnected.
        actionDate: values.visit_date,
        // If an online submit already created an action before it failed,
        // adopt it. A second one double-counts coverage and reps cannot
        // delete actions.
        existingActionId: survey.value?.pendingActionId ?? null,
      },
      photos: pendingSurveyPhotos.value,
    })
    // Reset the picker before the panel closes: those blobs are the queue's
    // now, and letting the picker upload them too would double-post them.
    picker.value?.reset()
    pendingSurveyPhotos.value = []
    await discardDraft()
    surveyOpen.value = false
    queuedNotice.value = true
  } catch (e) {
    offlineError.value =
      (e as Error).message || 'Could not save that on this phone.'
  } finally {
    offlineSaving.value = false
  }
}

/* ---- add a note --------------------------------------------------------- */
const noteBody = ref('')
const addNote = useAddNote()
const noteError = ref('')

async function submitNote() {
  if (!noteBody.value.trim()) return
  noteError.value = ''
  try {
    await addNote.mutateAsync({
      customerKey: props.customerKey,
      body: noteBody.value,
    })
    noteBody.value = ''
  } catch (e) {
    noteError.value = (e as Error).message || 'Could not save that note.'
  }
}

/* ---- quick actions ------------------------------------------------------
   The strip in the header only routes: it sets whichever panel ref the action
   belongs to and scrolls that section into view. Same nextTick-then-scroll
   shape as the ?survey= deep link below, and every target carries
   `scroll-mt-16` so the sticky 56px app header doesn't cover the heading it
   just scrolled to.
------------------------------------------------------------------------- */
const logSection = ref<HTMLElement | null>(null)
const taskSection = ref<HTMLElement | null>(null)
const noteSection = ref<HTMLElement | null>(null)
const photoSection = ref<HTMLElement | null>(null)
const summarySection = ref<HTMLElement | null>(null)

/* ---- doors to the orders card -------------------------------------------
   "Last order" and "Still owed" in the Before you call card, the
   Performance card's "Last invoice", and ?order=<id> all resolve to the
   orders/shipments cards further down: expand the right card, then the
   same nextTick-then-scroll move as onQuickAction. An order id also pops
   that order's line modal — any order, not only one already loaded.
------------------------------------------------------------------------- */
const ordersSection = ref<HTMLElement | null>(null)
const ordersCard = ref<InstanceType<typeof AccountOrdersCard> | null>(null)

async function scrollToOrders(behavior: ScrollBehavior = 'smooth') {
  await nextTick()
  ordersSection.value?.scrollIntoView({ behavior, block: 'start' })
}

/** '' = no particular order: just land on the list. */
async function showOrder(orderId: string) {
  ordersCard.value?.expandOrders()
  if (!orderId) {
    void scrollToOrders()
    return
  }
  // Instant, not smooth: the modal about to open locks body scroll
  // (AppModal), which would freeze a smooth scroll mid-flight. Jump first,
  // so closing the modal lands the rep on the orders card.
  await scrollToOrders('auto')
  ordersCard.value?.openOrder(orderId)
}
function showOpenOrders() {
  ordersCard.value?.expandOrders()
  void scrollToOrders()
}
async function showLastInvoice() {
  ordersCard.value?.expandShipments()
  await nextTick()
  ordersCard.value?.scrollToShipments()
}

/* ---- "No buyer number on file" → Add contact ----------------------------
   The form lives in ContactsCard, in place, like every other write here. */
const contactsSection = ref<HTMLElement | null>(null)
const contactsCard = ref<InstanceType<typeof ContactsCard> | null>(null)

async function addContact() {
  contactsCard.value?.startAdd()
  await nextTick()
  contactsSection.value?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

async function onQuickAction(action: QuickAction) {
  const targets: Record<QuickAction, typeof logSection> = {
    visit: surveySection,
    contact: logSection,
    note: noteSection,
    photo: photoSection,
    task: taskSection,
    summary: summarySection,
  }

  if (action === 'visit') openSurvey()
  if (action === 'contact') logging.value = true
  // Summarize is a paid call — jump to the card and let the rep press the
  // button, rather than spending a token because they tapped a nav chip.

  await nextTick()
  targets[action].value?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

/* ---- mission deep link --------------------------------------------------
   "Do the visit survey" on a mission card lands here as ?survey=<rec id>.
   Declared last: the immediate run calls openSurvey(), which touches refs
   declared through the whole of this setup block.
------------------------------------------------------------------------- */
watch(
  () => route.query.survey,
  async (raw) => {
    const id = Number(Array.isArray(raw) ? raw[0] : raw)
    if (!Number.isFinite(id) || id <= 0) return
    surveyRecommendationId.value = id
    if (!surveyOpen.value) openSurvey()
    await nextTick()
    surveySection.value?.scrollIntoView({ behavior: 'smooth', block: 'start' })
  },
  { immediate: true },
)

/* ---- order deep link ----------------------------------------------------
   Lookup and the activity feed link here as ?order=<order id>: open that
   order's lines (and expand the orders card behind them). No scroll, unlike
   the in-page doors above: on a cold load everything above the card is
   still arriving, so a jump lands somewhere arbitrary — and closing the
   sheet should leave the rep at the top of the account they just opened.
   The nextTick lets the orders card mount first. The param stays in the
   URL while the sheet is open (a reload reopens the same order) and goes
   when it closes: otherwise the same link tapped again — from the search
   box in the app header, say — would be a navigation to the URL already
   showing, and nothing would open.
------------------------------------------------------------------------- */
const router = useRouter()

watch(
  () => route.query.order,
  async (raw) => {
    const id = (Array.isArray(raw) ? raw[0] : raw)?.trim()
    if (!id) return
    await nextTick()
    ordersCard.value?.openOrder(id)
  },
  { immediate: true },
)

function onOrderClosed(orderId: string) {
  const raw = route.query.order
  if ((Array.isArray(raw) ? raw[0] : raw)?.trim() !== orderId) return
  const query = { ...route.query }
  delete query.order
  void router.replace({ query })
}

/* ---- deactivation --------------------------------------------------------
   The rep's override of the ERP's active_flag (migration 023). The panel
   lives at the very bottom of the page — this is the "I'm done with this
   account" action, not a daily one — and it confirms inline with a required
   reason, never in a modal (TECH_STACK §2.4). Deactivating dismisses the
   account's open recommendations and drops it from scoring DB-side, so the
   copy below promises exactly what the trigger does.
------------------------------------------------------------------------- */
const deactivationQuery = useAccountDeactivation(key)
const deactivation = computed(() => deactivationQuery.data.value ?? null)
const deactivate = useDeactivateAccount()
const reactivate = useReactivateAccount()

const deactivating = ref(false)
const deactivationReason = ref<DeactivationReason | null>(null)
const deactivationNote = ref('')
const deactivationError = ref('')

async function submitDeactivation() {
  if (!deactivationReason.value) return
  deactivationError.value = ''
  try {
    await deactivate.mutateAsync({
      customerKey: props.customerKey,
      reason: deactivationReason.value,
      note: deactivationNote.value,
    })
    deactivating.value = false
    deactivationReason.value = null
    deactivationNote.value = ''
  } catch (e) {
    deactivationError.value =
      (e as Error).message || 'Could not deactivate this account right now.'
  }
}

async function submitReactivation() {
  const row = deactivation.value
  if (!row) return
  deactivationError.value = ''
  try {
    await reactivate.mutateAsync({ id: row.id, customerKey: props.customerKey })
  } catch (e) {
    deactivationError.value =
      (e as Error).message || 'Could not reactivate this account right now.'
  }
}

// The router reuses this component across /accounts/:customerKey changes, so
// without this a survey opened for account A (and its mission id) would still
// be open on account B and stamp the wrong recommendation. The same goes for
// every other typed-but-unsaved thing on the page: a half-written note or
// contact log for A must not be one tap from saving against B, and A's
// "saved on this phone" line must not read as B's. (The summary card and
// ContactsCard reset their own.)
watch(key, () => {
  closeSurvey()
  queuedNotice.value = false
  offlineError.value = ''
  logging.value = false
  actionNote.value = ''
  logError.value = ''
  noteBody.value = ''
  noteError.value = ''
  deactivating.value = false
  deactivationReason.value = null
  deactivationNote.value = ''
  deactivationError.value = ''
})
</script>

<template>
  <div class="space-y-5">
    <AsyncState
      :loading="account.isPending.value"
      :error="account.error.value"
      :has-data="account.data.value !== undefined"
      :updated-at="account.dataUpdatedAt.value"
      :empty="!account.isPending.value && !account.data.value"
      empty-title="Account not found"
      empty-body="It may not be in your book, or the ERP load hasn't run yet."
      :rows="2"
      @retry="account.refetch()"
    >
      <!-- Facts up top: ink header, full-bleed past the page gutter. -->
      <header class="bg-ink text-canvas -mx-4 -mt-5 px-4 pt-4 pb-5">
        <RouterLink
          :to="{ name: 'accounts' }"
          class="font-label text-xs font-semibold tracking-[0.14em] text-[#8E8A80] uppercase hover:text-canvas"
        >
          ← All accounts
        </RouterLink>
        <div class="sm:flex sm:items-start sm:justify-between sm:gap-6">
          <div class="min-w-0">
            <h1 class="u-display mt-3 text-[32px]">{{ title }}</h1>
            <p class="mt-1 text-sm text-[#8E8A80]">
              {{ customerKey }}<template v-if="place"> · {{ place }}</template>
              <template v-if="account.data.value?.territory">
                · {{ account.data.value.territory }}
              </template>
            </p>
            <!-- The street, so "where is this place" has an answer. Directions
                 is a chip below. For chains the ERP sold-to is head office,
                 not the store — lib/maps.ts. -->
            <p v-if="reach.addressLine" class="text-canvas/80 mt-0.5 text-sm">
              {{ reach.addressLine }}
            </p>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <!-- The rep's write-off outranks the ERP flag: the ERP will keep
                   saying Active forever, and that's the whole reason 023 exists. -->
              <AppBadge v-if="deactivation" tone="high">Deactivated</AppBadge>
              <AppBadge
                v-else-if="account.data.value?.active_flag === 'Y'"
                tone="good"
              >
                Active
              </AppBadge>
              <AppBadge v-else tone="neutral">Inactive</AppBadge>
              <span
                v-if="account.data.value?.assigned_sales_rep_name"
                class="text-sm text-[#8E8A80]"
              >
                Rep: {{ account.data.value.assigned_sales_rep_name }}
              </span>
            </div>
          </div>

          <!-- Who to call — the ranked best contact, not the ERP's primary
               flag (see `reach` above), with one big way to dial them. The
               compliance flags (034) decide whether the number is a button
               at all. Waits for the contacts list so it never flashes "no
               number" at a dealer that has one. -->
          <div
            v-if="contacts.data.value !== undefined"
            class="mt-4 shrink-0 sm:mt-3 sm:w-[18rem]"
          >
            <p class="font-label text-[11px] font-semibold tracking-[0.14em] text-[#8E8A80] uppercase">
              Who to call
            </p>
            <template v-if="buyer">
              <p class="text-canvas mt-0.5 text-[15px] font-semibold break-words">
                {{ buyer.label }}
              </p>
              <p v-if="buyer.title" class="text-xs text-[#8E8A80]">{{ buyer.title }}</p>
            </template>

            <a
              v-if="buyer?.callable && buyer.phone"
              :href="telHref(buyer.phone)"
              @click="noteCallTap"
              class="tap-target font-label bg-canvas text-ink mt-3 flex w-full items-center justify-center gap-2 rounded-[2px] px-4 text-[15px] font-semibold tracking-[0.1em] uppercase hover:bg-[#E6E3DC]"
            >
              <svg
                class="size-5 shrink-0"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="1.8"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a2 2 0 0 1-2 2A16 16 0 0 1 3 6a2 2 0 0 1 2-2Z" />
              </svg>
              Call {{ buyer.phone }}
            </a>
            <template v-else>
              <!-- A flagged number keeps its digits visible but loses the
                   one-tap action, so dialling can never be an accident. -->
              <p v-if="buyer?.phone && buyer.do_not_call" class="mt-1 text-sm text-[#8E8A80]">
                {{ buyer.phone }} · do not call
              </p>
              <!-- A named contact with no number (a go-to the rep chose, an
                   email-only buyer) is not "no buyer": say whose number is
                   missing. -->
              <p v-else-if="buyer" class="text-canvas mt-1 text-sm">
                No number on file for {{ buyer.label }}
              </p>
              <p v-else class="text-canvas mt-1 text-sm">No buyer number on file</p>
              <button
                v-if="session.canWrite"
                type="button"
                class="tap-target font-label text-canvas mt-2 inline-flex items-center rounded-[2px] border border-[#4A4D44] px-3 text-[13px] font-semibold tracking-[0.1em] uppercase hover:border-canvas"
                @click="addContact"
              >
                Add contact
              </button>
            </template>
          </div>
        </div>

        <!-- What the rep can do, before the numbers rather than after them. -->
        <div class="mt-4">
          <AccountQuickActions
            :include="quickActions"
            :links="headerLinks"
            @select="onQuickAction"
          />
        </div>
      </header>

      <!--
        ERP facts straight off dim_customer. "Last order" and the open-order
        line used to sit here too, repeating what the Performance card said;
        both now live once, in the Before you call card just below. Three
        across at 390px, so the labels track tighter and the values step
        down a size on a phone.
      -->
      <dl class="bg-line border-line -mx-4 grid grid-cols-3 gap-px border-b">
        <div class="bg-surface min-w-0 px-3 py-2.5">
          <dt class="font-label text-muted text-[10px] font-semibold tracking-[0.06em] uppercase sm:tracking-[0.12em]">
            Customer since
          </dt>
          <dd class="u-display mt-0.5 text-base sm:text-xl">
            {{ shortDate(account.data.value?.account_open_date) }}
          </dd>
        </div>
        <!--
          Goal: the rep's own number when they have set one, the ERP's field
          otherwise. The sub-line always says which, and shows the ERP figure
          alongside a rep goal — the drift between the two is the interesting
          part, and hiding it would make the two screens disagree silently.
          Setting and editing happen in the Performance card below.
        -->
        <div class="bg-surface min-w-0 px-3 py-2.5">
          <dt class="font-label text-muted text-[10px] font-semibold tracking-[0.06em] uppercase sm:tracking-[0.12em]">
            Goal
          </dt>
          <dd class="u-display mt-0.5 text-base sm:text-xl">
            {{ money(displayGoal) }}
          </dd>
          <p class="text-muted mt-0.5 text-[11px]">{{ goalSource }}</p>
        </div>
        <div class="bg-surface min-w-0 px-3 py-2.5">
          <dt class="font-label text-muted text-[10px] font-semibold tracking-[0.06em] uppercase sm:tracking-[0.12em]">
            Credit
          </dt>
          <!-- Was one bare word. credit_limit_amount sat unused next to it in
               dim_customer the whole time, and the limit is what makes the
               status mean something. -->
          <dd
            class="u-display mt-0.5 text-base sm:text-xl"
            :class="creditBlocked ? 'text-danger' : ''"
          >
            {{ humanize(account.data.value?.credit_status) }}
          </dd>
          <p
            v-if="account.data.value?.credit_limit_amount != null"
            class="text-muted mt-0.5 text-[11px]"
          >
            Limit {{ money(account.data.value.credit_limit_amount) }}
          </p>
        </div>
      </dl>
    </AsyncState>

    <!-- Deactivated: say so up top, with the way back. The full story and
         the deactivate flow itself live at the bottom of the page. -->
    <AppCard v-if="deactivation">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="text-ink text-[15px] font-semibold">
            This account is deactivated —
            {{ DEACTIVATION_REASON_LABELS[deactivation.reason] ?? deactivation.reason }}
          </p>
          <p class="text-muted mt-1 text-sm">
            Taken out of play {{ daysAgo(deactivation.deactivated_at) }}. It's
            hidden from your active list and gets no new recommendations until
            you bring it back.
          </p>
          <p
            v-if="deactivation.note"
            class="text-ink-2 mt-2 text-sm whitespace-pre-wrap"
          >
            “{{ deactivation.note }}”
          </p>
        </div>
        <AppButton
          variant="secondary"
          :loading="reactivate.isPending.value"
          @click="submitReactivation"
        >
          Reactivate
        </AppButton>
      </div>
      <p
        v-if="deactivationError"
        role="alert"
        class="text-danger mt-2 text-sm font-medium"
      >
        {{ deactivationError }}
      </p>
    </AppCard>

    <!-- The pre-call brief: rhythm, last order, what's owed, their repeat
         buys in stock, pricing. Each fact once, on the whole page. -->
    <BeforeYouCallCard
      :customer-key="customerKey"
      :customer-type="account.data.value?.customer_type ?? null"
      :can-write="session.canWrite"
      :orders-enabled="flags.orders.value"
      @show-order="showOrder"
      @show-open-orders="showOpenOrders"
    />

    <!--
      "Can we ship?" — FFL expiry and credit holds, the two things that stop
      an order dead. Renders nothing when both are fine, so its presence is
      itself the signal. Above the performance numbers on purpose: no amount
      of revenue history matters if the shipment cannot leave.
    -->
    <AccountShipReadiness
      v-if="account.data.value"
      :ffl-license-number="account.data.value.ffl_license_number"
      :ffl-expiration-raw="account.data.value.ffl_expiration_raw"
      :credit-status="account.data.value.credit_status"
      :credit-limit-amount="account.data.value.credit_limit_amount"
      :ar-terms-rule-id="account.data.value.ar_terms_rule_id"
    />

    <!-- Mini-dashboard: every number below is aggregated in Postgres. -->
    <AccountSummaryCard
      :customer-key="customerKey"
      @show-last-invoice="showLastInvoice"
    />
    <AccountRevenueChart :customer-key="customerKey" />

    <!-- The account Sales Brief. The Summary chip scrolls here and never
         generates — that is the card's own button, a paid call. -->
    <section ref="summarySection" class="scroll-mt-16">
      <AccountAiSummaryCard :customer-key="customerKey" :can-write="session.canWrite">
        <template #footer="{ summary }">
          <AiFeedbackThumbs
            surface="account_summary"
            :subject-key="customerKey"
            :generated-at="summary.generated_at"
            :prompt-version="summary.prompt_version"
            :read-only="!session.canWrite"
          />
        </template>
      </AccountAiSummaryCard>
    </section>

    <!-- Open recommendations -->
    <section v-if="flags.recommendations.value" class="space-y-3">
      <h2 class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Needs attention
      </h2>
      <AsyncState
        :loading="recs.isPending.value"
        :error="recs.error.value"
        :has-data="recs.data.value !== undefined"
        :updated-at="recs.dataUpdatedAt.value"
        :empty="openRecs.length === 0"
        empty-title="Nothing open here"
        :rows="1"
        @retry="recs.refetch()"
      >
        <div class="-space-y-px">
          <RecommendationCard
            v-for="rec in openRecs"
            :key="rec.id"
            :rec="rec"
            hide-account-link
          />
        </div>
      </AsyncState>
    </section>

    <!-- Log a contact — the 10-second path. The full survey is below it. -->
    <section
      v-if="flags.actionLogging.value && session.canWrite"
      ref="logSection"
      class="scroll-mt-16"
    >
    <div v-if="!logging">
      <AppButton variant="secondary" block @click="logging = true">
        Log a contact
      </AppButton>
    </div>
    <AppCard v-else title="Log a contact">
      <fieldset>
        <legend class="u-label mb-2">What did you do?</legend>
        <div class="flex flex-wrap gap-2">
          <button
            v-for="t in ACTION_TYPES"
            :key="t"
            type="button"
            class="inline-flex min-h-11 items-center rounded-[2px] px-4 text-[15px] font-semibold"
            :class="
              actionType === t
                ? 'bg-ink text-canvas'
                : 'border-line-2 text-ink-2 border bg-transparent'
            "
            :aria-pressed="actionType === t"
            @click="actionType = t"
          >
            {{ ACTION_LABELS[t] }}
          </button>
        </div>
      </fieldset>
      <textarea
        v-model="actionNote"
        rows="3"
        placeholder="What came out of it? (optional)"
        class="field mt-3 h-auto p-3.5"
      />
      <p v-if="logError" role="alert" class="text-danger mt-2 text-sm font-medium">
        {{ logError }}
      </p>
      <div class="mt-3 flex gap-2">
        <AppButton variant="primary" :loading="logMutation.isPending.value" @click="submitLog">
          Save
        </AppButton>
        <AppButton variant="ghost" @click="logging = false">Cancel</AppButton>
      </div>
    </AppCard>
    </section>

    <!-- Visit survey — the one green button on this view. Opens inline.
         Hidden while viewing as a rep: the survey is the longest form in the
         app, and the database refuses the insert at the end of it. -->
    <section
      v-if="flags.visits.value && session.canWrite"
      ref="surveySection"
      class="scroll-mt-16 space-y-3"
    >
      <template v-if="!surveyOpen">
        <AppButton variant="primary" size="lg" block @click="openSurvey">
          Log a visit
        </AppButton>
        <p v-if="hasDraft" class="text-muted text-sm">
          You have an unfinished survey saved on this phone — opening it picks
          up where you left off.
        </p>
        <p v-if="queuedNotice" role="status" class="text-ink text-sm font-medium">
          Saved on this phone. It'll sync by itself when you're back online.
        </p>
      </template>

      <AppCard v-else title="Visit survey">
        <p v-if="!online" class="text-accent mb-3 text-sm font-medium">
          You're offline. Fill it in anyway — use "Save on this phone" at the
          bottom and it sends itself when the signal comes back.
        </p>

        <VisitSurvey
          ref="survey"
          :customer-key="customerKey"
          :recommendation-id="surveyRecommendationId"
          :initial-values="draftValues"
          @change="onSurveyChange"
          @submitted="onVisitSubmitted"
          @cancel="closeSurvey"
          @restart="picker?.reset()"
        >
          <template #photos="{ customerKey: photoKey, visitId }">
            <PhotoPicker
              ref="picker"
              :customer-key="photoKey"
              :visit-id="visitId"
              :auto-upload="online"
              @pending="onSurveyPhotosPending"
              @uploaded="invalidateAccount"
            />
          </template>
        </VisitSurvey>

        <!-- Offline: park the whole survey, photos included. -->
        <div v-if="!online && savedVisitId === null" class="mt-4">
          <AppButton
            variant="secondary"
            block
            :loading="offlineSaving"
            @click="saveVisitForLater"
          >
            Save on this phone
          </AppButton>
          <p
            v-if="offlineError"
            role="alert"
            class="text-danger mt-2 text-sm font-medium"
          >
            {{ offlineError }}
          </p>
        </div>

        <!-- The survey's success panel has no way out of its own; this is it. -->
        <div v-if="savedVisitId !== null" class="mt-4">
          <AppButton variant="ghost" block @click="closeSurvey">
            Done
          </AppButton>
        </div>
      </AppCard>
    </section>

    <!-- Orders and shipments, straight off the rollup views. -->
    <section ref="ordersSection" class="scroll-mt-16">
      <AccountOrdersCard
        ref="ordersCard"
        :customer-key="customerKey"
        @order-closed="onOrderClosed"
      />
    </section>

    <!-- What they buy and what they're owed, by SKU (data-first additions). -->
    <AccountSkuSalesCard :customer-key="customerKey" />
    <AccountBacklogCard :customer-key="customerKey" />

    <!-- …and what they DON'T buy that we could ship today. Sits directly
         under "Sales by SKU" because it is the same question asked the other
         way round, and reads best against what they already carry. -->
    <AccountOpportunityCard :customer-key="customerKey" />

    <section ref="contactsSection" class="scroll-mt-16">
      <ContactsCard ref="contactsCard" :customer-key="customerKey" />
    </section>

    <!-- Personal follow-ups on this account. -->
    <section v-if="flags.tasks.value" ref="taskSection" class="scroll-mt-16">
      <AccountTasksCard :customer-key="customerKey" />
    </section>

    <!-- Notes -->
    <section
      v-if="flags.actionLogging.value"
      ref="noteSection"
      class="scroll-mt-16"
    >
    <AppCard title="Notes">
      <!-- The notes themselves stay: reading what the rep has written on this
           account is most of the point of looking at it as them. -->
      <form v-if="session.canWrite" class="mb-4" @submit.prevent="submitNote">
        <label class="sr-only" for="note">Add a note</label>
        <textarea
          id="note"
          v-model="noteBody"
          rows="3"
          placeholder="Add a note…"
          class="field h-auto p-3.5"
        />
        <p v-if="noteError" role="alert" class="text-danger mt-2 text-sm font-medium">
          {{ noteError }}
        </p>
        <AppButton
          type="submit"
          variant="secondary"
          class="mt-2"
          :disabled="!noteBody.trim()"
          :loading="addNote.isPending.value"
        >
          Add note
        </AppButton>
      </form>

      <AsyncState
        :loading="notes.isPending.value"
        :error="notes.error.value"
        :has-data="notes.data.value !== undefined"
        :updated-at="notes.dataUpdatedAt.value"
        :empty="(notes.data.value?.length ?? 0) === 0"
        empty-title="No notes yet"
        :rows="2"
        @retry="notes.refetch()"
      >
        <ul class="space-y-3">
          <li v-for="n in notes.data.value" :key="n.id" class="bg-canvas p-3">
            <p class="text-ink-2 text-[15px] whitespace-pre-wrap">{{ n.body }}</p>
            <p class="text-muted mt-1 text-xs">{{ daysAgo(n.created_at) }}</p>
          </li>
        </ul>
      </AsyncState>
    </AppCard>
    </section>

    <!-- Photos that aren't tied to a survey — an endcap on the way past.
         Upload-only, so it has nothing to show a read-only viewer. -->
    <section
      v-if="flags.visits.value && session.canWrite"
      ref="photoSection"
      class="scroll-mt-16"
    >
      <AppCard title="Photos">
        <PhotoPicker :customer-key="customerKey" @uploaded="invalidateAccount" />
      </AppCard>
    </section>

    <VisitHistoryCard v-if="flags.visits.value" :customer-key="customerKey" />

    <!-- Activity -->
    <AppCard v-if="flags.actionLogging.value" title="Activity">
      <AsyncState
        :loading="actions.isPending.value"
        :error="actions.error.value"
        :has-data="actions.data.value !== undefined"
        :updated-at="actions.dataUpdatedAt.value"
        :empty="(actions.data.value?.length ?? 0) === 0"
        empty-title="Nothing logged yet"
        empty-body="Calls, visits, and emails you log show up here."
        :rows="2"
        @retry="actions.refetch()"
      >
        <ul class="space-y-4">
          <li v-for="a in actions.data.value" :key="a.id" class="flex gap-3">
            <span class="bg-line-2 w-0.5 shrink-0 self-stretch" aria-hidden="true" />
            <div class="min-w-0">
              <p class="text-ink text-[15px] font-semibold">
                {{ ACTION_LABELS[a.action_type as ActionType] ?? a.action_type }}
                <span class="text-muted font-normal">
                  · {{ shortDate(a.action_date) }}
                </span>
              </p>
              <p v-if="a.note" class="text-ink-2 text-[15px] whitespace-pre-wrap">
                {{ a.note }}
              </p>
            </div>
          </li>
        </ul>
      </AsyncState>
    </AppCard>

    <!-- Deactivate — last on purpose: this is "I'm done with this account",
         not a daily action. Inline confirm with a required reason, never a
         modal (TECH_STACK §2.4). Hidden while already deactivated; the
         banner at the top owns that state. -->
    <section
      v-if="account.data.value && !deactivation && !deactivationQuery.isPending.value"
    >
      <div v-if="!deactivating">
        <AppButton variant="ghost" block @click="deactivating = true">
          Deactivate this account…
        </AppButton>
        <p class="text-muted mt-2 text-center text-xs">
          Not worth working anymore? Take it off your list — you can always
          bring it back.
        </p>
      </div>

      <AppCard v-else title="Deactivate this account">
        <p class="text-muted text-sm">
          The ERP will still show it as active, but it drops off your active
          list, stops being scored, and its open recommendations are dismissed.
          Reactivating undoes all of that.
        </p>

        <fieldset class="mt-4">
          <legend class="u-label mb-2">Why?</legend>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="r in DEACTIVATION_REASONS"
              :key="r"
              type="button"
              class="inline-flex min-h-11 items-center rounded-[2px] px-4 text-[15px] font-semibold"
              :class="
                deactivationReason === r
                  ? 'bg-ink text-canvas'
                  : 'border-line-2 text-ink-2 border bg-transparent'
              "
              :aria-pressed="deactivationReason === r"
              @click="deactivationReason = r"
            >
              {{ DEACTIVATION_REASON_LABELS[r] }}
            </button>
          </div>
        </fieldset>

        <textarea
          v-model="deactivationNote"
          rows="3"
          placeholder="Anything worth remembering about why? (optional)"
          class="field mt-3 h-auto p-3.5"
        />

        <p
          v-if="deactivationError"
          role="alert"
          class="text-danger mt-2 text-sm font-medium"
        >
          {{ deactivationError }}
        </p>

        <div class="mt-3 flex gap-2">
          <AppButton
            variant="danger"
            :disabled="!deactivationReason"
            :loading="deactivate.isPending.value"
            @click="submitDeactivation"
          >
            Deactivate
          </AppButton>
          <AppButton variant="ghost" @click="deactivating = false">
            Cancel
          </AppButton>
        </div>
      </AppCard>
    </section>
  </div>
</template>
