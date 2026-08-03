<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { format } from 'date-fns'
import { useSessionStore } from '@/stores/session'
import { isMission, useNeedsAttention } from '@/composables/useRecommendations'
import { useAccountNames } from '@/composables/useAccounts'
import { useMyDueTasks, useMyTasks } from '@/composables/useTasks'
import { useAiHeadlines } from '@/composables/useAiSummary'
import MissionBanner from '@/components/MissionBanner.vue'
import NextActionCard from '@/components/NextActionCard.vue'
import RecommendationCard from '@/components/RecommendationCard.vue'
import FollowUpsCard from '@/components/FollowUpsCard.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { daysUntilDue } from '@/lib/format'

const session = useSessionStore()
const { data, isPending, error, refetch } = useNeedsAttention()

const items = computed(() => data.value ?? [])

function isLate(dueDate: string | null): boolean {
  const d = daysUntilDue(dueDate)
  return d != null && d < 0
}

const overdue = computed(() => items.value.filter((r) => isLate(r.due_date)).length)

/* ---- the queue --------------------------------------------------------
   The screen used to render every open recommendation. At 95 of them the
   mission banner scrolled away, the follow-ups below were unreachable, and
   the ranked list stopped being a list and became a wall.

   So: one "do this first", then a short window onto the rest. Nothing is
   hidden — the count is always on screen and the window opens — but the
   default is a page a rep can act on rather than read.

   Replenishment needs no code. Closing an item invalidates the query, the
   item leaves the array, and the next one moves under the cap on its own.
------------------------------------------------------------------------- */
const QUEUE_SIZE = 4
const QUEUE_STEP = 10
const MISSION_PREVIEW = 3

const first = computed(() => items.value[0])
const rest = computed(() => items.value.slice(1))

/* Missions get their own section above the queue. They are admin-directed
   work — "directive, not optional" — and must never be paginated below a
   stack of algorithmic suggestions. */
const missions = computed(() => rest.value.filter((r) => isMission(r)))
const queue = computed(() => rest.value.filter((r) => !isMission(r)))

const missionsOverdue = computed(() => missions.value.filter((r) => isLate(r.due_date)).length)
/** The banner counts every open mission, including one sitting in the do-first slot. */
const missionsOpen = computed(() => items.value.filter((r) => isMission(r)).length)

const visibleCount = ref(QUEUE_SIZE)
const showAllMissions = ref(false)

const visibleQueue = computed(() => queue.value.slice(0, visibleCount.value))
const hiddenCount = computed(() => Math.max(0, queue.value.length - visibleCount.value))
const visibleMissions = computed(() =>
  showAllMissions.value ? missions.value : missions.value.slice(0, MISSION_PREVIEW),
)

/* A refetch that ADDS work (the nightly job ran, or another device closed
   nothing) resets the window — otherwise a rep who expanded once yesterday
   comes back to a wall again. Shrinking is left alone: closing four items in
   a row should not keep collapsing the list under the rep's thumb. */
watch(
  () => queue.value.length,
  (now, before) => {
    if (now > before) visibleCount.value = QUEUE_SIZE
  },
)

const listEl = ref<HTMLElement | null>(null)
const missionsEl = ref<HTMLElement | null>(null)

/** The banner points at the missions section, and opens it far enough to
    actually contain them — scrolling to a truncated list is a dead end. */
function showMissions() {
  showAllMissions.value = true
  const target = missionsEl.value ?? listEl.value
  target?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

/* ---- follow-ups ---------------------------------------------------------
   The card owns its own query and mutation. This page reads the same query
   for the tile and the name lookup — vue-query dedupes on the key, so that
   is one request, not two.
------------------------------------------------------------------------- */
const myTasks = useMyTasks()
const tasks = computed(() => myTasks.data.value ?? [])
const dueTasks = useMyDueTasks()
const followUpsDue = computed(() => dueTasks.data.value?.due ?? 0)
const followUpsOverdue = computed(() => dueTasks.data.value?.overdue ?? 0)

/** One name lookup for both lists — recommendations and account-linked tasks. */
const { data: names } = useAccountNames(
  computed(() => [
    ...items.value.map((r) => r.customer_key),
    ...tasks.value.map((t) => t.customer_key).filter((k): k is string => !!k),
  ]),
)

/* Pre-generated briefings for the cards actually on screen — one `.in()`
   over the visible keys, not a query per card. Absent or stale headlines
   simply don't come back and each card falls through to its reason string. */
const { data: headlines } = useAiHeadlines(
  computed(() => [
    ...(first.value ? [first.value.customer_key] : []),
    ...visibleMissions.value.map((r) => r.customer_key),
    ...visibleQueue.value.map((r) => r.customer_key),
  ]),
)
function headlineFor(customerKey: string): string | undefined {
  return headlines.value?.[customerKey]?.headline
}

// displayName falls back to the email when the profile has no full_name;
// an address has no spaces, so strip the domain before taking the first word.
const firstName = computed(() => session.displayName.split('@')[0].split(' ')[0])

/**
 * Reps do their entry at the end of a route as often as the start of one, and
 * a fixed "Morning" at 6pm reads like the page is stale.
 */
const greeting = computed(() => {
  const h = new Date().getHours()
  if (h < 12) return 'Morning'
  if (h < 17) return 'Afternoon'
  return 'Evening'
})
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.16em] uppercase">
        {{ format(new Date(), 'EEEE, MMMM d') }}
      </p>
      <h1 class="u-display mt-1 text-[34px] wrap-anywhere">
        {{ greeting }}, {{ firstName }}
      </h1>
    </header>

    <MissionBanner
      :open="missionsOpen"
      :overdue="missionsOverdue"
      @show="showMissions"
    />

    <div class="bg-line border-line grid grid-cols-3 gap-px border">
      <StatTile label="To do" :value="items.length" />
      <StatTile
        label="Overdue"
        :value="overdue"
        :tone="overdue > 0 ? 'alert' : 'default'"
      />
      <StatTile
        label="Follow-ups"
        :value="followUpsDue"
        sub="due"
        :tone="followUpsOverdue > 0 ? 'alert' : 'default'"
      />
    </div>

    <AsyncState
      :loading="isPending"
      :error="error"
      :empty="items.length === 0"
      empty-title="That's the whole list."
      empty-body="Nothing needs attention right now. New recommendations land overnight — go home."
      @retry="refetch()"
    >
      <div ref="listEl" class="scroll-mt-16 space-y-5">
        <NextActionCard
          v-if="first"
          :rec="first"
          :account-name="names?.[first.customer_key]"
          :headline="headlineFor(first.customer_key)"
        />

        <!-- Sales ops' own work, above the algorithm's. -->
        <section v-if="missions.length" ref="missionsEl" class="scroll-mt-16 space-y-3">
          <h2 class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
            From sales ops · {{ missions.length }}
          </h2>
          <div class="-space-y-px">
            <RecommendationCard
              v-for="rec in visibleMissions"
              :key="rec.id"
              :rec="rec"
              :account-name="names?.[rec.customer_key]"
              :headline="headlineFor(rec.customer_key)"
            />
          </div>
          <AppButton
            v-if="missions.length > visibleMissions.length"
            variant="ghost"
            block
            @click="showAllMissions = true"
          >
            Show {{ missions.length - visibleMissions.length }} more missions
          </AppButton>
        </section>

        <section v-if="queue.length" class="space-y-3">
          <h2 class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
            Then these · {{ queue.length }}
          </h2>
          <div class="-space-y-px">
            <RecommendationCard
              v-for="rec in visibleQueue"
              :key="rec.id"
              :rec="rec"
              :account-name="names?.[rec.customer_key]"
              :headline="headlineFor(rec.customer_key)"
            />
          </div>

          <!-- Nothing is hidden: the count is on screen even when collapsed. -->
          <AppButton
            v-if="hiddenCount > 0"
            variant="ghost"
            block
            @click="visibleCount += QUEUE_STEP"
          >
            {{ hiddenCount }} more waiting — show
            {{ Math.min(QUEUE_STEP, hiddenCount) }}
          </AppButton>
        </section>

        <!-- Closing an item silently removes a card; say what's left. -->
        <p class="sr-only" role="status" aria-live="polite">
          {{ items.length }} still need attention
        </p>
      </div>
    </AsyncState>

    <!-- The rep's own reminders. Separate from the list above on purpose:
         those come from sales ops, these are theirs. -->
    <FollowUpsCard :names="names ?? {}" />
  </div>
</template>
