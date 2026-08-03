<script setup lang="ts">
import { computed, ref } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import TaskQuickAdd from '@/components/TaskQuickAdd.vue'
import { useMyTasks, useToggleTask, type Task } from '@/composables/useTasks'
import { daysUntilDue, dueLabel } from '@/lib/format'

/**
 * The rep's own follow-ups, as they appear on Today.
 *
 * Lifted out of TodayView because that page had grown to hold two lists, two
 * mutations and two live regions, and the recommendation queue above it is the
 * part that needed the attention. This owns its own query and mutation; the
 * page passes nothing but account names.
 *
 * Deliberately still a to-do list and nothing else — no counts by bucket, no
 * charts (PRD: "Zero analytics beyond that"). The full page is /tasks.
 */
const props = withDefaults(
  defineProps<{
    /** customer_key → display name, resolved once by the page for both lists. */
    names?: Record<string, string>
    limit?: number
  }>(),
  { names: () => ({}), limit: 5 },
)

const query = useMyTasks()
const tasks = computed<Task[]>(() => query.data.value ?? [])

/**
 * Overdue first, then everything else in the query's order (due date ascending,
 * undated last). A stable partition rather than a re-sort: the point is that a
 * follow-up that has already slipped cannot be pushed off the preview by five
 * tasks due next month.
 */
const ordered = computed(() => {
  const late: Task[] = []
  const rest: Task[] = []
  for (const t of tasks.value) {
    const d = daysUntilDue(t.due_date)
    ;(d != null && d < 0 ? late : rest).push(t)
  }
  return [...late, ...rest]
})

const visible = computed(() => ordered.value.slice(0, props.limit))
const overdueCount = computed(
  () =>
    tasks.value.filter((t) => {
      const d = daysUntilDue(t.due_date)
      return d != null && d < 0
    }).length,
)

defineExpose({ overdueCount })

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
  return props.names[task.customer_key] || task.customer_key
}
</script>

<template>
  <section class="space-y-3">
    <h2
      class="font-label text-muted flex flex-wrap items-center gap-x-2 text-xs font-semibold tracking-[0.18em] uppercase"
    >
      <span>My follow-ups<template v-if="tasks.length"> · {{ tasks.length }}</template></span>
      <!-- Ember only for lateness, per the style.css contract. -->
      <span v-if="overdueCount > 0" class="text-accent">{{ overdueCount }} past due</span>
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
          :loading="query.isPending.value"
          :error="query.error.value"
          :empty="tasks.length === 0"
          empty-title="Nothing pending"
          empty-body="Add a follow-up above when something needs a nudge."
          :rows="1"
          @retry="query.refetch()"
        >
          <ul class="divide-line divide-y">
            <li
              v-for="task in visible"
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
                      (daysUntilDue(task.due_date) ?? 1) < 0 ? 'text-accent font-semibold' : ''
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

      <template v-if="tasks.length > limit" #footer>
        <RouterLink
          :to="{ name: 'tasks' }"
          class="font-label text-ink text-[13px] font-semibold tracking-[0.12em] uppercase underline underline-offset-4"
        >
          All {{ tasks.length }} follow-ups
        </RouterLink>
      </template>
    </AppCard>
  </section>
</template>
