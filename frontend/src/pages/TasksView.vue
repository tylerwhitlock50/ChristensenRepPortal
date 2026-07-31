<script setup lang="ts">
import { computed, ref } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import TaskQuickAdd from '@/components/TaskQuickAdd.vue'
import { useAccountNames } from '@/composables/useAccounts'
import {
  useCancelTask,
  useMyTasks,
  useToggleTask,
  type Task,
} from '@/composables/useTasks'
import { daysUntilDue, dueLabel, shortDate } from '@/lib/format'

const { data, isPending, error, refetch } = useMyTasks()
const tasks = computed(() => data.value ?? [])

const accountKeys = computed(() =>
  tasks.value.map((t) => t.customer_key).filter((k): k is string => !!k),
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
</script>

<template>
  <div class="space-y-6">
    <header>
      <h1 class="text-2xl font-semibold tracking-tight text-zinc-900">
        My follow-ups
      </h1>
      <p class="mt-1 text-sm text-zinc-500">
        Your own reminders. Recommendations from sales ops live on Today.
      </p>
    </header>

    <AppCard>
      <TaskQuickAdd placeholder="What do you need to remember?" />
    </AppCard>

    <p v-if="overdueCount > 0" class="text-sm font-medium text-red-700">
      {{ overdueCount }} past due
    </p>

    <p v-if="actionError" role="alert" class="text-sm text-red-700">
      {{ actionError }}
    </p>
    <p class="sr-only" role="status" aria-live="polite">
      <template v-if="lastDone">Done: {{ lastDone }}</template>
    </p>

    <AsyncState
      :loading="isPending"
      :error="error"
      :empty="tasks.length === 0"
      empty-title="Nothing on your list"
      empty-body="That's the whole list — you're not missing anything. Add a follow-up above when something needs a nudge."
      @retry="refetch()"
    >
      <div class="space-y-6">
        <section v-for="bucket in buckets" :key="bucket.id" class="space-y-2">
          <h2 class="flex items-center gap-2 text-sm font-semibold tracking-wide text-zinc-500 uppercase">
            {{ bucket.label }}
            <AppBadge :tone="bucket.tone">{{ bucket.items.length }}</AppBadge>
          </h2>

          <ul class="divide-y divide-zinc-100 overflow-hidden rounded-xl border border-zinc-200 bg-white">
            <li v-for="task in bucket.items" :key="task.id" class="p-3">
              <div class="flex items-start gap-3">
                <!-- 44px hit area, and it's a real control, not a hover trick -->
                <button
                  type="button"
                  class="tap-target flex w-11 shrink-0 items-center justify-center rounded-lg border border-zinc-300 bg-white"
                  :disabled="busyId === task.id"
                  :aria-label="`Mark done: ${task.title}`"
                  @click="complete(task)"
                >
                  <svg
                    class="size-5 text-zinc-400"
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
                  <p class="font-medium break-words text-zinc-900">{{ task.title }}</p>
                  <p class="mt-0.5 flex flex-wrap items-center gap-x-2 text-sm text-zinc-500">
                    <span v-if="task.due_date">
                      {{ dueLabel(task.due_date) }} · {{ shortDate(task.due_date) }}
                    </span>
                    <RouterLink
                      v-if="task.customer_key"
                      :to="{ name: 'account', params: { customerKey: task.customer_key } }"
                      class="font-medium text-zinc-900 underline underline-offset-2"
                    >
                      {{ accountLabel(task) }}
                    </RouterLink>
                  </p>
                </div>

                <button
                  v-if="confirmingCancelId !== task.id"
                  type="button"
                  class="tap-target shrink-0 px-2 text-sm font-medium text-zinc-500 underline underline-offset-2"
                  @click="confirmingCancelId = task.id"
                >
                  Drop
                </button>
              </div>

              <!-- Inline confirm, never a modal -->
              <div
                v-if="confirmingCancelId === task.id"
                class="mt-2 flex flex-wrap items-center gap-2 rounded-lg bg-zinc-50 p-2"
              >
                <span class="text-sm text-zinc-700">Drop this follow-up?</span>
                <button
                  type="button"
                  class="tap-target rounded-lg border border-zinc-300 bg-white px-3 text-sm font-medium text-zinc-900"
                  :disabled="busyId === task.id"
                  @click="drop(task)"
                >
                  Drop it
                </button>
                <button
                  type="button"
                  class="tap-target px-3 text-sm font-medium text-zinc-600"
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
  </div>
</template>
