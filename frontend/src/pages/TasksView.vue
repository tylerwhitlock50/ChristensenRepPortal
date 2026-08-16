<script setup lang="ts">
import { computed, ref } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import TaskQuickAdd from '@/components/TaskQuickAdd.vue'
import { useSessionStore } from '@/stores/session'
import { useAccountNames } from '@/composables/useAccounts'
import {
  useCancelTask,
  useClosedTasks,
  useMyTasks,
  useToggleTask,
  type Task,
} from '@/composables/useTasks'
import { daysUntilDue, dueLabel, shortDate } from '@/lib/format'

const session = useSessionStore()
const { data, isPending, error, refetch } = useMyTasks()
const tasks = computed(() => data.value ?? [])

/* ---- open vs finished ---------------------------------------------------
   Two segments, not a tabs component. The repo has no tabs primitive and two
   mutually exclusive filters do not justify inventing one — this is the same
   `aria-pressed` pill row already used in AccountView, VisitSurvey and the
   mission composer.

   The closed query is gated on the segment, so the default view still costs
   exactly one round trip.
------------------------------------------------------------------------- */
type Segment = 'open' | 'closed'
const segment = ref<Segment>('open')

const closed = useClosedTasks(computed(() => segment.value === 'closed'))
const closedTasks = computed(() => closed.data.value ?? [])

const accountKeys = computed(() =>
  [...tasks.value, ...closedTasks.value]
    .map((t) => t.customer_key)
    .filter((k): k is string => !!k),
)
const { data: names } = useAccountNames(accountKeys)

/* ---- grouping -----------------------------------------------------------
   Four buckets in the order a rep works them. The query already sorts by
   due date with nulls last, so each bucket keeps that order for free.
------------------------------------------------------------------------- */
type Bucket = { id: string; label: string; tone: 'late' | 'high' | 'neutral'; items: Task[] }

const buckets = computed<Bucket[]>(() => {
  const overdue: Task[] = []
  const today: Task[] = []
  const upcoming: Task[] = []
  const someday: Task[] = []

  for (const t of tasks.value) {
    const days = daysUntilDue(t.due_date)
    if (days == null) someday.push(t)
    else if (days < 0) overdue.push(t)
    else if (days === 0) today.push(t)
    else upcoming.push(t)
  }

  const all: Bucket[] = [
    { id: 'overdue', label: 'Overdue', tone: 'late', items: overdue },
    { id: 'today', label: 'Today', tone: 'high', items: today },
    { id: 'upcoming', label: 'Upcoming', tone: 'neutral', items: upcoming },
    { id: 'someday', label: 'No due date', tone: 'neutral', items: someday },
  ]
  return all.filter((b) => b.items.length > 0)
})

const overdueCount = computed(
  () => buckets.value.find((b) => b.id === 'overdue')?.items.length ?? 0,
)

/* ---- acting on a task ---------------------------------------------------- */
const toggle = useToggleTask()
const cancel = useCancelTask()

const busyId = ref<number | null>(null)
const confirmingCancelId = ref<number | null>(null)
const actionError = ref('')
/** Read out by the live region — completing a task removes it from the list,
    so without this the only feedback is a row vanishing. */
const lastDone = ref('')

async function complete(task: Task) {
  if (busyId.value) return
  busyId.value = task.id
  actionError.value = ''
  try {
    await toggle.mutateAsync({ id: task.id, done: true })
    lastDone.value = task.title
  } catch (e) {
    actionError.value = (e as Error).message || 'Could not update that.'
  } finally {
    busyId.value = null
  }
}

/** Back to the open list. `useToggleTask` has supported this since it was
    written; nothing had ever called it, because nothing could reach a
    finished task. */
async function reopen(task: Task) {
  if (busyId.value) return
  busyId.value = task.id
  actionError.value = ''
  try {
    await toggle.mutateAsync({ id: task.id, done: false })
    lastDone.value = ''
  } catch (e) {
    actionError.value = (e as Error).message || 'Could not update that.'
  } finally {
    busyId.value = null
  }
}

async function drop(task: Task) {
  if (busyId.value) return
  busyId.value = task.id
  actionError.value = ''
  try {
    await cancel.mutateAsync({ id: task.id })
    confirmingCancelId.value = null
  } catch (e) {
    actionError.value = (e as Error).message || 'Could not update that.'
  } finally {
    busyId.value = null
  }
}

function accountLabel(task: Task): string {
  if (!task.customer_key) return ''
  return names.value?.[task.customer_key] || task.customer_key
}

/**
 * A dropped task has no completion date — `useCancelTask` leaves
 * `completed_at` null on purpose, because the execution reporting counts on
 * "dropped" and "done" being different things. Date it by when it was made
 * instead of rendering "Completed —".
 */
function closedLabel(task: Task): string {
  return task.status === 'cancelled'
    ? `Dropped · added ${shortDate(task.created_at)}`
    : `Completed ${shortDate(task.completed_at)}`
}
</script>

<template>
  <div class="space-y-6">
    <header>
      <h1 class="text-2xl font-semibold tracking-tight text-ink">
        My follow-ups
      </h1>
      <p class="mt-1 text-sm text-muted">
        Your own reminders. Recommendations from sales ops live on Today.
      </p>
    </header>

    <div class="flex flex-wrap gap-2">
      <button
        v-for="s in (['open', 'closed'] as Segment[])"
        :key="s"
        type="button"
        class="inline-flex min-h-11 items-center rounded-[2px] px-4 text-[15px] font-semibold"
        :class="
          segment === s ? 'bg-ink text-canvas' : 'border-line-2 text-ink-2 border bg-transparent'
        "
        :aria-pressed="segment === s"
        @click="segment = s"
      >
        {{ s === 'open' ? 'Open' : 'Finished' }}
        <span v-if="s === 'open' && tasks.length" class="ml-2 font-normal opacity-70">
          {{ tasks.length }}
        </span>
      </button>
    </div>

    <AppCard v-if="segment === 'open'">
      <TaskQuickAdd
        v-if="session.canWrite"
        placeholder="What do you need to remember?"
      />
    </AppCard>

    <p v-if="segment === 'open' && overdueCount > 0" class="text-sm font-medium text-danger">
      {{ overdueCount }} past due
    </p>

    <p v-if="actionError" role="alert" class="text-sm text-danger">
      {{ actionError }}
    </p>
    <p class="sr-only" role="status" aria-live="polite">
      <template v-if="lastDone">Done: {{ lastDone }}</template>
    </p>

    <AsyncState
      v-if="segment === 'open'"
      :loading="isPending"
      :error="error"
      :empty="tasks.length === 0"
      empty-title="Nothing on your list"
      empty-body="That's the whole list — you're not missing anything. Add a follow-up above when something needs a nudge."
      @retry="refetch()"
    >
      <div class="space-y-6">
        <section v-for="bucket in buckets" :key="bucket.id" class="space-y-2">
          <h2 class="flex items-center gap-2 text-sm font-semibold tracking-wide text-muted uppercase">
            {{ bucket.label }}
            <AppBadge :tone="bucket.tone">{{ bucket.items.length }}</AppBadge>
          </h2>

          <ul class="divide-y divide-line overflow-hidden rounded-none border border-line bg-surface">
            <li v-for="task in bucket.items" :key="task.id" class="p-3">
              <div class="flex items-start gap-3">
                <!-- 44px hit area, and it's a real control, not a hover trick -->
                <button
                  type="button"
                  class="tap-target flex w-11 shrink-0 items-center justify-center rounded-[2px] border border-line-2 bg-surface"
                  :disabled="busyId === task.id"
                  :aria-label="`Mark done: ${task.title}`"
                  @click="complete(task)"
                >
                  <svg
                    class="size-5 text-muted"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2.5"
                    aria-hidden="true"
                  >
                    <path d="M5 13l4 4L19 7" />
                  </svg>
                </button>

                <div class="min-w-0 flex-1">
                  <p class="font-medium break-words text-ink">{{ task.title }}</p>
                  <p class="mt-0.5 flex flex-wrap items-center gap-x-2 text-sm text-muted">
                    <span v-if="task.due_date">
                      {{ dueLabel(task.due_date) }} · {{ shortDate(task.due_date) }}
                    </span>
                    <RouterLink
                      v-if="task.customer_key"
                      :to="{ name: 'account', params: { customerKey: task.customer_key } }"
                      class="font-medium text-ink underline underline-offset-2"
                    >
                      {{ accountLabel(task) }}
                    </RouterLink>
                  </p>
                </div>

                <button
                  v-if="confirmingCancelId !== task.id"
                  type="button"
                  class="tap-target shrink-0 px-2 text-sm font-medium text-muted underline underline-offset-2"
                  @click="confirmingCancelId = task.id"
                >
                  Drop
                </button>
              </div>

              <!-- Inline confirm, never a modal -->
              <div
                v-if="confirmingCancelId === task.id"
                class="mt-2 flex flex-wrap items-center gap-2 rounded-[2px] bg-canvas p-2"
              >
                <span class="text-sm text-ink-2">Drop this follow-up?</span>
                <button
                  type="button"
                  class="tap-target rounded-[2px] border border-line-2 bg-surface px-3 text-sm font-medium text-ink"
                  :disabled="busyId === task.id"
                  @click="drop(task)"
                >
                  Drop it
                </button>
                <button
                  type="button"
                  class="tap-target px-3 text-sm font-medium text-ink-2"
                  @click="confirmingCancelId = null"
                >
                  Keep it
                </button>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </AsyncState>

    <!-- Finished: the last 50, done and dropped together. -->
    <AsyncState
      v-else
      :loading="closed.isPending.value"
      :error="closed.error.value"
      :empty="closedTasks.length === 0"
      empty-title="Nothing finished yet"
      empty-body="Follow-ups you complete or drop land here."
      @retry="closed.refetch()"
    >
      <ul class="divide-y divide-line overflow-hidden border border-line bg-surface">
        <li v-for="task in closedTasks" :key="task.id" class="flex items-start gap-3 p-3">
          <div class="min-w-0 flex-1">
            <p
              class="font-medium break-words"
              :class="task.status === 'cancelled' ? 'text-muted line-through' : 'text-ink'"
            >
              {{ task.title }}
            </p>
            <p class="mt-0.5 flex flex-wrap items-center gap-x-2 text-sm text-muted">
              <span>{{ closedLabel(task) }}</span>
              <RouterLink
                v-if="task.customer_key"
                :to="{ name: 'account', params: { customerKey: task.customer_key } }"
                class="font-medium text-ink underline underline-offset-2"
              >
                {{ accountLabel(task) }}
              </RouterLink>
            </p>
          </div>

          <button
            type="button"
            class="tap-target shrink-0 px-2 text-sm font-medium text-muted underline underline-offset-2"
            :disabled="busyId === task.id"
            :aria-label="`Reopen: ${task.title}`"
            @click="reopen(task)"
          >
            Reopen
          </button>
        </li>
      </ul>
    </AsyncState>
  </div>
</template>
