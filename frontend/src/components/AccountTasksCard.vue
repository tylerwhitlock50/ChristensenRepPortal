<script setup lang="ts">
import { computed, ref } from 'vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import TaskQuickAdd from '@/components/TaskQuickAdd.vue'
import { useSessionStore } from '@/stores/session'
import { useAccountTasks, useToggleTask, type Task } from '@/composables/useTasks'
import { daysUntilDue, dueLabel } from '@/lib/format'

/**
 * Follow-ups attached to this account.
 *
 * This closes a loop that was built and then never connected: `useAccountTasks`
 * has existed since the composable was written, with a docstring calling it
 * "the strip on the account page", and had zero callers. `TaskQuickAdd` has
 * accepted a `customerKey` prop just as long, and nothing ever passed one — so
 * every task in the database carries `customer_key = null`, while Today and
 * /tasks both render an account link for tasks that could have had one.
 *
 * Existing rows stay null. There is no signal left to recover the association
 * from, so there is nothing to backfill.
 */
const props = defineProps<{ customerKey: string }>()

const session = useSessionStore()

const query = useAccountTasks(computed(() => props.customerKey))
const tasks = computed<Task[]>(() => query.data.value ?? [])

const toggle = useToggleTask()
const busyId = ref<number | null>(null)
const actionError = ref('')
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
</script>

<template>
  <!-- "Your" is load-bearing: useAccountTasks filters by user_id, so an admin
       looking at a rep's account sees their own follow-ups here, not the
       rep's. That is right for a personal to-do list, but the empty state has
       to say so or it reads as "this account has none". -->
  <AppCard title="Your follow-ups here">
    <TaskQuickAdd
      v-if="session.canWrite"
      :customer-key="customerKey"
      placeholder="Remind me about this account…"
    />

    <p v-if="actionError" role="alert" class="text-danger mt-2 text-sm font-medium">
      {{ actionError }}
    </p>
    <p class="sr-only" role="status" aria-live="polite">
      <template v-if="lastDone">Done: {{ lastDone }}</template>
    </p>

    <div class="mt-4">
      <AsyncState
        :loading="query.isPending.value"
        :error="query.error.value"
        :empty="tasks.length === 0"
        empty-title="None yet"
        empty-body="Anything you add here shows up on Today with a link back to this account."
        :rows="1"
        @retry="query.refetch()"
      >
        <ul class="divide-line divide-y">
          <li
            v-for="task in tasks"
            :key="task.id"
            class="flex items-start gap-3 py-3 first:pt-0 last:pb-0"
          >
            <button
              v-if="session.canWrite"
              type="button"
              class="tap-target border-line-2 flex w-12 shrink-0 items-center justify-center rounded-[2px] border"
              :disabled="busyId === task.id"
              :aria-label="`Mark done: ${task.title}`"
              @click="complete(task)"
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
              <p class="text-ink text-[15px] font-semibold break-words">{{ task.title }}</p>
              <p
                class="mt-0.5 text-sm"
                :class="
                  (daysUntilDue(task.due_date) ?? 1) < 0
                    ? 'text-accent font-semibold'
                    : 'text-muted'
                "
              >
                {{ dueLabel(task.due_date) }}
              </p>
            </div>
          </li>
        </ul>
      </AsyncState>
    </div>
  </AppCard>
</template>
