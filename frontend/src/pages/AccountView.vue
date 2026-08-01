<script setup lang="ts">
import { computed, defineAsyncComponent, nextTick, ref, watch } from 'vue'
import { useRoute } from 'vue-router'
import { useOnline } from '@vueuse/core'
import { useQueryClient } from '@tanstack/vue-query'
import { useSessionStore } from '@/stores/session'
import { useAccount } from '@/composables/useAccounts'
import { useAccountRecommendations } from '@/composables/useRecommendations'
import {
  useAccountActions,
  useAddNote,
  useLogAccountAction,
  useNotes,
} from '@/composables/useAccountData'
import { useAiSummary, useGenerateAiSummary } from '@/composables/useAiSummary'
import { useAccountSummary } from '@/composables/useAccountMetrics'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import RecommendationCard from '@/components/RecommendationCard.vue'
import AccountSummaryCard from '@/components/AccountSummaryCard.vue'
/**
 * chart.js is roughly two thirds of this route's bundle, and this is the page
 * a rep opens standing in a store on LTE. Async-loaded so the numbers, orders
 * and the visit survey paint without waiting on the charting library.
 */
const AccountRevenueChart = defineAsyncComponent(
  () => import('@/components/AccountRevenueChart.vue'),
)
import AccountOrdersCard from '@/components/AccountOrdersCard.vue'
import ContactsCard from '@/components/ContactsCard.vue'
import VisitSurvey from '@/components/VisitSurvey.vue'
import VisitHistoryCard from '@/components/VisitHistoryCard.vue'
import PhotoPicker from '@/components/PhotoPicker.vue'
import { useDraft, visitDraftKey } from '@/lib/drafts'
import { enqueue, type QueuedPhoto } from '@/lib/submitQueue'
import {
  isVisitFormEmpty,
  makeVisitFormValues,
  type VisitFormValues,
} from '@/lib/visitSchema'
import { qk } from '@/lib/queryClient'
import { ACTION_LABELS, ACTION_TYPES, type ActionType } from '@/types/domain'
import { daysAgo, humanize, money, shortDate } from '@/lib/format'

const props = defineProps<{ customerKey: string }>()
const key = computed(() => props.customerKey)

const qc = useQueryClient()
const online = useOnline()
const session = useSessionStore()

const account = useAccount(key)
// Same query AccountSummaryCard runs — vue-query dedupes it, so this costs
// nothing extra. Here it feeds the "Last order" tile below.
const summary = useAccountSummary(key)
const recs = useAccountRecommendations(key)

/**
 * dim_customer.last_order_date is the ERP's unmaintained field — NULL for
 * most accounts, which made this tile say "never" right above a Performance
 * card showing a real last-order date. Prefer the order-history-derived date
 * from v_account_summary so the two always agree; the raw field is only the
 * fallback while the summary is loading or migration 011/015 isn't applied.
 */
const lastOrderDate = computed(
  () =>
    summary.data.value?.last_order_date ??
    account.data.value?.last_order_date ??
    null,
)
const notes = useNotes(key)
const actions = useAccountActions(key)

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

/* ---- AI summary ---------------------------------------------------------
   Cached row first, always. The button is an explicit choice — nothing fires
   a generation on mount, and an account with too little history says so
   instead of inventing a paragraph.
------------------------------------------------------------------------- */
const ai = useAiSummary(key)
const generate = useGenerateAiSummary()
const aiNotice = ref('')
const aiError = ref('')

async function runSummary() {
  aiNotice.value = ''
  aiError.value = ''
  try {
    const result = await generate.mutateAsync(props.customerKey)
    if (result.status === 'insufficient_data') {
      aiNotice.value =
        result.message ??
        "There isn't enough activity on this account to summarize yet. Log a visit or a call and try again."
    } else if (result.status === 'cooldown') {
      const mins = Math.max(1, Math.ceil((result.retry_after_seconds ?? 60) / 60))
      aiNotice.value = `Just refreshed. You can regenerate in about ${mins} minute${mins === 1 ? '' : 's'}.`
    } else if (result.status === 'cached') {
      aiNotice.value = 'Nothing has changed since the last summary.'
    }
  } catch (e) {
    aiError.value =
      (e as Error).message || 'Could not build the summary right now.'
  }
}

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
const survey = ref<InstanceType<typeof VisitSurvey> | null>(null)
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
}

/* Photos taken inside the survey. Online they upload themselves; offline the
   picker holds them and they travel with the queued survey. */
const picker = ref<InstanceType<typeof PhotoPicker> | null>(null)
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

// The router reuses this component across /accounts/:customerKey changes, so
// without this a survey opened for account A (and its mission id) would still
// be open on account B and stamp the wrong recommendation.
watch(key, () => closeSurvey())
</script>

<template>
  <div class="space-y-5">
    <AsyncState
      :loading="account.isPending.value"
      :error="account.error.value"
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
        <h1 class="u-display mt-3 text-[32px]">{{ title }}</h1>
        <p class="mt-1 text-sm text-[#8E8A80]">
          {{ customerKey }}<template v-if="place"> · {{ place }}</template>
          <template v-if="account.data.value?.territory">
            · {{ account.data.value.territory }}
          </template>
        </p>
        <div class="mt-3 flex flex-wrap items-center gap-2">
          <AppBadge v-if="account.data.value?.active_flag === 'Y'" tone="good">
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
      </header>

      <!--
        ERP facts straight off dim_customer — except "Last order", which
        prefers the order-history-derived date (see lastOrderDate above).
        This strip stays even though AccountSummaryCard repeats "Last order":
        the card needs the v_account_* rollup views (migration 011), and until
        those are applied this is the only account history on the page.
      -->
      <dl class="bg-line border-line -mx-4 grid grid-cols-2 gap-px border-b sm:grid-cols-4">
        <div class="bg-surface px-3 py-2.5">
          <dt class="font-label text-muted text-[10px] font-semibold tracking-[0.12em] uppercase">
            Last order
          </dt>
          <dd class="u-display mt-0.5 text-xl">
            {{ daysAgo(lastOrderDate) }}
          </dd>
        </div>
        <div class="bg-surface px-3 py-2.5">
          <dt class="font-label text-muted text-[10px] font-semibold tracking-[0.12em] uppercase">
            Customer since
          </dt>
          <dd class="u-display mt-0.5 text-xl">
            {{ shortDate(account.data.value?.account_open_date) }}
          </dd>
        </div>
        <div class="bg-surface px-3 py-2.5">
          <dt class="font-label text-muted text-[10px] font-semibold tracking-[0.12em] uppercase">
            Goal
          </dt>
          <dd class="u-display mt-0.5 text-xl">
            {{ money(account.data.value?.yearly_sales_goal) }}
          </dd>
        </div>
        <div class="bg-surface px-3 py-2.5">
          <dt class="font-label text-muted text-[10px] font-semibold tracking-[0.12em] uppercase">
            Credit
          </dt>
          <dd class="u-display mt-0.5 text-xl">
            {{ humanize(account.data.value?.credit_status) }}
          </dd>
        </div>
      </dl>
    </AsyncState>

    <!-- Mini-dashboard: every number below is aggregated in Postgres. -->
    <AccountSummaryCard :customer-key="customerKey" />
    <AccountRevenueChart :customer-key="customerKey" />

    <!-- AI summary — cached copy first, regeneration on request only. -->
    <AppCard>
      <template #header>
        <h2 class="u-label text-ink">The story so far</h2>
        <AppButton
          variant="ghost"
          :loading="generate.isPending.value"
          @click="runSummary"
        >
          {{ ai.hasSummary.value ? 'Regenerate' : 'Summarize' }}
        </AppButton>
      </template>

      <AsyncState
        :loading="ai.isPending.value"
        :error="ai.error.value"
        :rows="2"
        @retry="ai.refetch()"
      >
        <div>
          <template v-if="ai.hasSummary.value">
            <p class="text-ink-2 text-[15px] leading-relaxed whitespace-pre-wrap">
              {{ ai.summary.value?.content }}
            </p>
            <p class="text-muted mt-2 text-xs">{{ ai.asOf.value }}</p>
          </template>
          <p v-else class="text-muted text-[15px] leading-relaxed">
            No summary yet. Tap Summarize and we'll read this account's numbers,
            recent orders and your notes back to you in a few sentences.
          </p>

          <p v-if="aiNotice" class="text-muted mt-3 text-sm">{{ aiNotice }}</p>
          <p
            v-if="aiError"
            role="alert"
            class="text-danger mt-3 text-sm font-medium"
          >
            {{ aiError }}
          </p>
        </div>
      </AsyncState>
    </AppCard>

    <!-- Open recommendations -->
    <section class="space-y-3">
      <h2 class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Needs attention
      </h2>
      <AsyncState
        :loading="recs.isPending.value"
        :error="recs.error.value"
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

    <!-- Visit survey — the one green button on this view. Opens inline. -->
    <section ref="surveySection" class="scroll-mt-16 space-y-3">
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
    <AccountOrdersCard :customer-key="customerKey" />

    <ContactsCard :customer-key="customerKey" />

    <!-- Notes -->
    <AppCard title="Notes">
      <form class="mb-4" @submit.prevent="submitNote">
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

    <!-- Photos that aren't tied to a survey — an endcap on the way past. -->
    <AppCard title="Photos">
      <PhotoPicker :customer-key="customerKey" @uploaded="invalidateAccount" />
    </AppCard>

    <VisitHistoryCard :customer-key="customerKey" />

    <!-- Activity -->
    <AppCard title="Activity">
      <AsyncState
        :loading="actions.isPending.value"
        :error="actions.error.value"
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
  </div>
</template>
