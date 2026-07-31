<script setup lang="ts">
import { computed, ref } from 'vue'
import { useAccount } from '@/composables/useAccounts'
import { useAccountRecommendations } from '@/composables/useRecommendations'
import {
  useAccountActions,
  useAddNote,
  useContacts,
  useLogAccountAction,
  useNotes,
} from '@/composables/useAccountData'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import RecommendationCard from '@/components/RecommendationCard.vue'
import { ACTION_LABELS, ACTION_TYPES, type ActionType } from '@/types/domain'
import { daysAgo, humanize, money, shortDate } from '@/lib/format'

const props = defineProps<{ customerKey: string }>()
const key = computed(() => props.customerKey)

const account = useAccount(key)
const recs = useAccountRecommendations(key)
const notes = useNotes(key)
const contacts = useContacts(key)
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
</script>

<template>
  <div class="space-y-6">
    <RouterLink
      :to="{ name: 'accounts' }"
      class="inline-flex items-center gap-1 text-sm text-zinc-500 hover:text-zinc-900"
    >
      <svg
        class="size-4"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        aria-hidden="true"
      >
        <path d="M15 18l-6-6 6-6" />
      </svg>
      All accounts
    </RouterLink>

    <AsyncState
      :loading="account.isPending.value"
      :error="account.error.value"
      :empty="!account.isPending.value && !account.data.value"
      empty-title="Account not found"
      empty-body="It may not be in your book, or the ERP load hasn't run yet."
      :rows="2"
      @retry="account.refetch()"
    >
      <header>
        <h1 class="text-2xl font-semibold tracking-tight text-zinc-900">
          {{ title }}
        </h1>
        <p class="mt-1 text-sm text-zinc-500">
          {{ customerKey }}<template v-if="place"> · {{ place }}</template>
        </p>
        <div class="mt-3 flex flex-wrap items-center gap-2">
          <AppBadge
            v-if="account.data.value?.active_flag === 'Y'"
            tone="good"
          >
            Active
          </AppBadge>
          <AppBadge v-else tone="neutral">Inactive</AppBadge>
          <AppBadge v-if="account.data.value?.territory" tone="neutral">
            {{ account.data.value.territory }}
          </AppBadge>
          <span
            v-if="account.data.value?.assigned_sales_rep_name"
            class="text-sm text-zinc-500"
          >
            Rep: {{ account.data.value.assigned_sales_rep_name }}
          </span>
        </div>
      </header>

      <!--
        The mini-dashboard (current vs prior-year revenue, 12-month order
        history, charts) is deliberately absent: it needs the public.v_* rollup
        views from TECH_STACK §3.3. Aggregating erp facts in the browser would
        ship thousands of rows to a phone.
      -->
      <dl class="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <div class="rounded-xl border border-zinc-200 bg-white p-3">
          <dt class="text-xs text-zinc-500">Last order</dt>
          <dd class="mt-0.5 font-medium text-zinc-900">
            {{ daysAgo(account.data.value?.last_order_date) }}
          </dd>
        </div>
        <div class="rounded-xl border border-zinc-200 bg-white p-3">
          <dt class="text-xs text-zinc-500">Customer since</dt>
          <dd class="mt-0.5 font-medium text-zinc-900">
            {{ shortDate(account.data.value?.account_open_date) }}
          </dd>
        </div>
        <div class="rounded-xl border border-zinc-200 bg-white p-3">
          <dt class="text-xs text-zinc-500">Yearly goal</dt>
          <dd class="mt-0.5 font-medium text-zinc-900">
            {{ money(account.data.value?.yearly_sales_goal) }}
          </dd>
        </div>
        <div class="rounded-xl border border-zinc-200 bg-white p-3">
          <dt class="text-xs text-zinc-500">Credit</dt>
          <dd class="mt-0.5 font-medium text-zinc-900">
            {{ humanize(account.data.value?.credit_status) }}
          </dd>
        </div>
      </dl>
    </AsyncState>

    <!-- Log a contact -->
    <AppCard title="Log a contact">
      <div v-if="!logging">
        <p class="mb-3 text-sm text-zinc-600">
          Record a call, visit, or email against this account.
        </p>
        <AppButton @click="logging = true">Log a contact</AppButton>
      </div>
      <div v-else>
        <fieldset>
          <legend class="mb-2 text-sm font-medium text-zinc-700">
            What did you do?
          </legend>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="t in ACTION_TYPES"
              :key="t"
              type="button"
              class="tap-target rounded-lg border px-3 text-sm font-medium"
              :class="
                actionType === t
                  ? 'border-zinc-900 bg-zinc-900 text-white'
                  : 'border-zinc-300 bg-white text-zinc-700'
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
          class="mt-3 w-full rounded-lg border border-zinc-300 p-3 text-sm outline-none focus:border-zinc-900"
        />
        <p v-if="logError" role="alert" class="mt-2 text-sm text-red-700">
          {{ logError }}
        </p>
        <div class="mt-3 flex gap-2">
          <AppButton :loading="logMutation.isPending.value" @click="submitLog">
            Save
          </AppButton>
          <AppButton variant="ghost" @click="logging = false">Cancel</AppButton>
        </div>
      </div>
    </AppCard>

    <!-- Open recommendations -->
    <section class="space-y-3">
      <h2 class="text-sm font-semibold tracking-wide text-zinc-500 uppercase">
        Needs attention
      </h2>
      <AsyncState
        :loading="recs.isPending.value"
        :error="recs.error.value"
        :empty="openRecs.length === 0"
        empty-title="Nothing open on this account"
        :rows="1"
        @retry="recs.refetch()"
      >
        <div class="space-y-3">
          <RecommendationCard
            v-for="rec in openRecs"
            :key="rec.id"
            :rec="rec"
            hide-account-link
          />
        </div>
      </AsyncState>
    </section>

    <!-- Contacts -->
    <AppCard title="Contacts" :hint="`${contacts.data.value?.length ?? 0}`">
      <AsyncState
        :loading="contacts.isPending.value"
        :error="contacts.error.value"
        :empty="(contacts.data.value?.length ?? 0) === 0"
        empty-title="No contacts yet"
        empty-body="Add the buyer's name and number so the next person has it."
        :rows="2"
        @retry="contacts.refetch()"
      >
        <ul class="divide-y divide-zinc-100">
          <li
            v-for="c in contacts.data.value"
            :key="c.id"
            class="flex items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
          >
            <div class="min-w-0">
              <p class="truncate font-medium text-zinc-900">
                {{ c.name }}
                <AppBadge v-if="c.is_primary" tone="info">Primary</AppBadge>
              </p>
              <p class="truncate text-sm text-zinc-500">
                {{ [c.title, c.phone, c.email].filter(Boolean).join(' · ') }}
              </p>
            </div>
            <a
              v-if="c.phone"
              :href="`tel:${c.phone}`"
              class="tap-target inline-flex items-center rounded-lg border border-zinc-300 px-3 text-sm font-medium"
            >
              Call
            </a>
          </li>
        </ul>
      </AsyncState>
    </AppCard>

    <!-- Notes -->
    <AppCard title="Notes">
      <form class="mb-4" @submit.prevent="submitNote">
        <label class="sr-only" for="note">Add a note</label>
        <textarea
          id="note"
          v-model="noteBody"
          rows="3"
          placeholder="Add a note…"
          class="w-full rounded-lg border border-zinc-300 p-3 text-sm outline-none focus:border-zinc-900"
        />
        <p v-if="noteError" role="alert" class="mt-2 text-sm text-red-700">
          {{ noteError }}
        </p>
        <AppButton
          type="submit"
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
          <li
            v-for="n in notes.data.value"
            :key="n.id"
            class="rounded-lg bg-zinc-50 p-3"
          >
            <p class="text-sm whitespace-pre-wrap text-zinc-800">{{ n.body }}</p>
            <p class="mt-1 text-xs text-zinc-500">{{ daysAgo(n.created_at) }}</p>
          </li>
        </ul>
      </AsyncState>
    </AppCard>

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
        <ul class="space-y-3">
          <li v-for="a in actions.data.value" :key="a.id" class="flex gap-3">
            <span
              class="mt-1.5 size-2 shrink-0 rounded-full bg-zinc-300"
              aria-hidden="true"
            />
            <div class="min-w-0">
              <p class="text-sm font-medium text-zinc-900">
                {{ ACTION_LABELS[a.action_type as ActionType] ?? a.action_type }}
                <span class="font-normal text-zinc-500">
                  · {{ shortDate(a.action_date) }}
                </span>
              </p>
              <p v-if="a.note" class="text-sm whitespace-pre-wrap text-zinc-600">
                {{ a.note }}
              </p>
            </div>
          </li>
        </ul>
      </AsyncState>
    </AppCard>
  </div>
</template>
