<script setup lang="ts">
import { computed, ref } from 'vue'
import { format } from 'date-fns'
import { useSessionStore } from '@/stores/session'
import { isMission, useNeedsAttention } from '@/composables/useRecommendations'
import { useAccountNames } from '@/composables/useAccounts'
import { useMyTasks, useToggleTask, type Task } from '@/composables/useTasks'
import MissionBanner from '@/components/MissionBanner.vue'
import NextActionCard from '@/components/NextActionCard.vue'
import RecommendationCard from '@/components/RecommendationCard.vue'
import TaskQuickAdd from '@/components/TaskQuickAdd.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { daysUntilDue, dueLabel } from '@/lib/format'

const session = useSessionStore()
const { data, isPending, error, refetch } = useNeedsAttention()

const items = computed(() => data.value ?? [])

// One next action up top, then the ranked list.
const first = computed(() => items.value[0])
const rest = computed(() => items.value.slice(1))

const overdue = computed(
  () =>
    items.value.filter((r) => {
      const d = daysUntilDue(r.due_date)
      return d != null && d < 0
    }).length,
)
const awaitingOutcome = computed(
  () => items.value.filter((r) => r.status === 'acted').length,
)

/* ---- missions -----------------------------------------------------------
   Admin-directed work gets a banner above everything else — a rep signing
   in must see it before the rest of the list. The cards themselves are in
   the ranked feed below, so "See them" scrolls to the list.
------------------------------------------------------------------------- */
const missions = computed(() => items.value.filter((r) => isMission(r)))
const missionsOverdue = computed(
  () =>
    missions.value.filter((r) => {
      const d = daysUntilDue(r.due_date)
      return d != null && d < 0
    }).length,
)

const listEl = ref<HTMLElement | null>(null)
function scrollToList() {
  listEl.value?.scrollIntoView({ behavior: 'smooth', block: 'start' })
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

/* ---- my follow-ups ------------------------------------------------------
   The rep's own reminders, under the recommendations sales ops sent them.
   Deliberately a to-do list and nothing else — no counts-by-bucket, no
   charts (PRD: "Zero analytics beyond that"). The full page is /tasks.
------------------------------------------------------------------------- */
const TASK_PREVIEW = 5

const myTasks = useMyTasks()
const tasks = computed<Task[]>(() => myTasks.data.value ?? [])
const visibleTasks = computed(() => tasks.value.slice(0, TASK_PREVIEW))

/** One name lookup for both lists — recommendations and account-linked tasks. */
const { data: names } = useAccountNames(
  computed(() => [
    ...items.value.map((r) => r.customer_key),
    ...tasks.value.map((t) => t.customer_key).filter((k): k is string => !!k),
  ]),
)

const toggle = useToggleTask()
const busyTaskId = ref<number | null>(null)
const taskError = ref('')
/** Completing a task removes the row; without this the only feedback is a gap. */
const lastDone = ref('')

async function completeTask(task: Task) {
  if (busyTaskId.value) return
  busyTaskId.value = task.id
  taskError.value = ''
  try {
    await toggle.mutateAsync({ id: task.id, done: true })
    lastDone.value = task.title
  } catch (e) {
    taskError.value = (e as Error).message || 'Could not update that.'
  } finally {
    busyTaskId.value = null
  }
}

function taskAccount(task: Task): string {
  if (!task.customer_key) return ''
  return names.value?.[task.customer_key] || task.customer_key
}
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
      :open="missions.length"
      :overdue="missionsOverdue"
      @show="scrollToList"
    />

    <div class="bg-line border-line grid grid-cols-3 gap-px border">
      <StatTile label="To do" :value="items.length" />
      <StatTile
        label="Overdue"
        :value="overdue"
        :tone="overdue > 0 ? 'alert' : 'default'"
      />
      <StatTile label="No outcome" :value="awaitingOutcome" />
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
        />

        <section v-if="rest.length" class="space-y-3">
          <h2 class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
            Then these · {{ rest.length }}
          </h2>
          <div class="-space-y-px">
            <RecommendationCard
              v-for="rec in rest"
              :key="rec.id"
              :rec="rec"
              :account-name="names?.[rec.customer_key]"
            />
          </div>
        </section>
      </div>
    </AsyncState>

    <!-- My own follow-ups. Separate from the list above on purpose: those come
         from sales ops, these are the rep's. -->
    <section class="space-y-3">
      <h2 class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        My follow-ups<template v-if="tasks.length"> · {{ tasks.length }}</template>
      </h2>

      <AppCard :padded="false">
        <div class="border-line border-b p-4">
          <TaskQuickAdd placeholder="Remind me to…" />
        </div>

        <p v-if="taskError" role="alert" class="text-danger px-4 pt-3 text-sm font-medium">
          {{ taskError }}
        </p>
        <p class="sr-only" role="status" aria-live="polite">
          <template v-if="lastDone">Done: {{ lastDone }}</template>
        </p>

        <div class="p-4">
          <AsyncState
            :loading="myTasks.isPending.value"
            :error="myTasks.error.value"
            :empty="tasks.length === 0"
            empty-title="Nothing pending"
            empty-body="Add a follow-up above when something needs a nudge."
            :rows="1"
            @retry="myTasks.refetch()"
          >
            <ul class="divide-line divide-y">
              <li
                v-for="task in visibleTasks"
                :key="task.id"
                class="flex items-start gap-3 py-3 first:pt-0 last:pb-0"
              >
                <button
                  type="button"
                  class="tap-target border-line-2 flex w-12 shrink-0 items-center justify-center rounded-[2px] border"
                  :disabled="busyTaskId === task.id"
                  :aria-label="`Mark done: ${task.title}`"
                  @click="completeTask(task)"
                >
                  <svg
                    class="text-muted size-5"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    aria-hidden="true"
                  >
                    <path d="M5 13l4 4L19 7" />
                  </svg>
                </button>

                <div class="min-w-0 flex-1">
                  <p class="text-ink text-[15px] font-semibold break-words">
                    {{ task.title }}
                  </p>
                  <p class="text-muted mt-0.5 flex flex-wrap items-center gap-x-2 text-sm">
                    <span
                      :class="
                        (daysUntilDue(task.due_date) ?? 1) < 0
                          ? 'text-accent font-semibold'
                          : ''
                      "
                    >
                      {{ dueLabel(task.due_date) }}
                    </span>
                    <RouterLink
                      v-if="task.customer_key"
                      :to="{ name: 'account', params: { customerKey: task.customer_key } }"
                      class="text-ink font-medium underline underline-offset-2"
                    >
                      {{ taskAccount(task) }}
                    </RouterLink>
                  </p>
                </div>
              </li>
            </ul>
          </AsyncState>
        </div>

        <template v-if="tasks.length > TASK_PREVIEW" #footer>
          <RouterLink
            :to="{ name: 'tasks' }"
            class="font-label text-ink text-[13px] font-semibold tracking-[0.12em] uppercase underline underline-offset-4"
          >
            All {{ tasks.length }} follow-ups
          </RouterLink>
        </template>
      </AppCard>
    </section>
  </div>
</template>
