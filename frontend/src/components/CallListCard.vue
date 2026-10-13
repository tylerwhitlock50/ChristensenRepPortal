<script setup lang="ts">
import { computed, ref } from 'vue'
import {
  CALL_LIST_REASONS,
  MAX_ROWS,
  REACTION_LABELS,
  REACTION_WINDOW_DAYS,
  REASON_LABELS,
  VISIBLE_ROWS,
  useCallList,
  useReactToCallList,
  useUndoCallListReaction,
  type CallListReaction,
  type CallListReason,
  type CallListRow,
} from '@/composables/useCallList'
import { useQuickCallLog } from '@/composables/useQuickCallLog'
import { useSessionStore } from '@/stores/session'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppModal from '@/components/ui/AppModal.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { money, telHref } from '@/lib/format'
import { YTD_TONE, ytdChange } from '@/lib/scoreReasons'

/**
 * "Worth a call today" — the top of the rep's morning (useCallList.ts).
 *
 * Observation voice, like the rest of the Overview: each row says what the
 * numbers show and offers the two things a rep does next — call the buyer,
 * or drive there. The "⋯" reaction is optional and only ever hides a row
 * from this rep's own list; nothing is assigned, closed or reported.
 */
const session = useSessionStore()
const list = useCallList()
const quickLog = useQuickCallLog()
const react = useReactToCallList()
const undo = useUndoCallListReaction()

const expanded = ref(false)
const rows = computed(() => list.rows.value)
const shown = computed(() => (expanded.value ? rows.value : rows.value.slice(0, VISIBLE_ROWS)))
const moreCount = computed(() => Math.min(rows.value.length, MAX_ROWS) - VISIBLE_ROWS)

/* ---- reach -------------------------------------------------------------- */

function reachFor(key: string) {
  return list.reach.byKey.value.get(key) ?? null
}

function callTarget(key: string) {
  const reach = reachFor(key)
  const c = reach?.best.callable ? reach.best.contact : null
  if (!c?.phone) return null
  return { href: telHref(c.phone), label: c.label, phone: c.phone }
}

const reachLoading = computed(
  () => list.rows.value.length > 0 && list.reach.isPending.value,
)

/** Everything a row renders, worked out once rather than per binding. */
const items = computed(() =>
  shown.value.map((row) => ({
    row,
    delta: ytdChange(row.revenue_ytd, row.revenue_prior_ytd, money),
    call: callTarget(row.customer_key),
    directions: reachFor(row.customer_key)?.directionsUrl ?? null,
  })),
)

function onCall(row: CallListRow, contactLabel: string) {
  quickLog.noteCallTap({
    customerKey: row.customer_key,
    customerName: row.customer_name,
    contactLabel,
  })
}

/* ---- reactions ---------------------------------------------------------- */

const canReact = computed(() => session.canWrite && list.reactionsAvailable.value)
const menuFor = ref<CallListRow | null>(null)
const showReasons = ref(false)
const menuOpen = computed({
  get: () => menuFor.value !== null,
  set: (v: boolean) => {
    if (!v) menuFor.value = null
  },
})

function openMenu(row: CallListRow) {
  showReasons.value = false
  menuFor.value = row
}

/** The last reaction, for the Undo line. Cleared on undo or the next one. */
const lastReaction = ref<{
  id: number | null
  name: string
  customerKey: string
  reaction: CallListReaction
  reason: CallListReason | null
} | null>(null)
const reactError = ref('')

function windowText(reaction: CallListReaction): string {
  const days = REACTION_WINDOW_DAYS[reaction]
  if (days % 7 === 0) return `${days / 7} week${days === 7 ? '' : 's'}`
  return `${days} days`
}

async function choose(reaction: CallListReaction, reason: CallListReason | null = null) {
  const row = menuFor.value
  if (!row) return
  menuFor.value = null
  reactError.value = ''
  lastReaction.value = {
    id: null,
    name: row.customer_name,
    customerKey: row.customer_key,
    reaction,
    reason,
  }
  try {
    const saved = await react.mutateAsync({ customerKey: row.customer_key, reaction, reason })
    if (lastReaction.value?.customerKey === row.customer_key) lastReaction.value.id = saved.id
  } catch {
    lastReaction.value = null
    reactError.value = `Couldn't save that for ${row.customer_name}, so it's still on your list.`
  }
}

async function undoLast() {
  const last = lastReaction.value
  if (!last?.id) return
  try {
    await undo.mutateAsync({ id: last.id })
    lastReaction.value = null
  } catch {
    reactError.value = "Couldn't undo that. It will come back on its own."
  }
}

/** Store closed / buys elsewhere may be for good — point at the real switch. */
const suggestDeactivate = computed(
  () =>
    lastReaction.value?.reason === 'store_closed' ||
    lastReaction.value?.reason === 'buys_elsewhere',
)

const NOT_RELEVANT_REASONS = CALL_LIST_REASONS.filter((r) => r !== 'other')
</script>

<template>
  <AppCard :padded="false">
    <template #header>
      <h2 class="u-label text-ink">Worth a call today</h2>
      <span
        v-if="rows.length"
        class="font-label text-muted text-xs tracking-[0.08em] tabular-nums"
      >
        {{ rows.length }} {{ rows.length === 1 ? 'account' : 'accounts' }}
      </span>
    </template>

    <!-- The territory rows are the one input the list cannot do without
         (names, money, the fallback); a failed ranking read falls back
         instead (useCallList), so it never shows as an error here. -->
    <AsyncState
      :loading="list.isPending.value"
      :error="list.territory.error.value"
      :has-data="
        list.territory.data.value !== undefined &&
        (list.signals.data.value !== undefined || list.usingFallback.value)
      "
      :updated-at="list.territory.dataUpdatedAt.value"
      :empty="!list.isPending.value && rows.length === 0"
      empty-title="Nothing stands out today"
      :empty-body="
        list.feedback.data.value?.length
          ? 'Nobody else is late against their usual ordering rhythm, slipping sharply, or waiting on a big late order. Accounts you reacted to come back on their own.'
          : 'Nobody is late against their usual ordering rhythm, slipping sharply, or waiting on a big late order.'
      "
      :rows="3"
      @retry="list.territory.refetch(); list.signals.refetch()"
    >
      <p class="text-muted border-line border-b px-4 py-2.5 text-[13px] leading-snug">
        <template v-if="list.usingFallback.value">
          Who stands out in your numbers, and why.
        </template>
        <template v-else>Who stands out in last night's numbers, and why.</template>
        Money is this year so far, with the change on the same time last year.
      </p>

      <!-- The last reaction, with a way back. -->
      <div
        v-if="lastReaction || reactError"
        class="bg-canvas border-line border-b px-4 py-2"
        role="status"
      >
        <p v-if="reactError" class="text-danger text-sm font-medium">{{ reactError }}</p>
        <div v-else-if="lastReaction" class="flex items-center justify-between gap-3">
          <p class="text-ink-2 min-w-0 text-sm">
            {{ lastReaction.name }} is off your list for
            {{ windowText(lastReaction.reaction) }}.
            <template v-if="suggestDeactivate">
              If that's for good,
              <RouterLink
                :to="{ name: 'account', params: { customerKey: lastReaction.customerKey } }"
                class="underline underline-offset-2"
              >deactivate it on the account page</RouterLink>.
            </template>
          </p>
          <button
            type="button"
            class="tap-target font-label text-ink shrink-0 px-2 text-[13px] font-semibold tracking-[0.12em] uppercase underline underline-offset-4 disabled:opacity-50"
            :disabled="!lastReaction.id || undo.isPending.value"
            @click="undoLast"
          >
            Undo
          </button>
        </div>
      </div>

      <ol class="divide-line divide-y">
        <li v-for="{ row, delta, call, directions } in items" :key="row.customer_key" class="px-4 py-3">
          <div class="flex items-start gap-1">
            <!-- The whole read is the link to the account: a 70px target,
                 not a line of text to aim at. -->
            <RouterLink
              :to="{ name: 'account', params: { customerKey: row.customer_key } }"
              class="hover:bg-canvas -mx-2 block min-w-0 flex-1 px-2 py-0.5"
            >
              <span class="text-ink block truncate text-[17px] font-semibold">
                {{ row.customer_name }}
              </span>
              <span class="text-muted flex flex-wrap items-baseline gap-x-1.5 text-sm">
                <span v-if="row.place">{{ row.place }}</span>
                <template v-if="row.revenue_ytd != null">
                  <span v-if="row.place" aria-hidden="true">·</span>
                  <span class="text-ink-2 tabular-nums">{{ money(row.revenue_ytd) }} this year</span>
                  <span v-if="delta" class="font-semibold tabular-nums" :class="YTD_TONE[delta.direction]">
                    <span aria-hidden="true">{{ delta.text }}</span>
                    <span class="sr-only">{{ delta.sr }}</span>
                  </span>
                </template>
              </span>
              <ul v-if="row.chips.length" class="mt-1.5 flex flex-wrap gap-1.5" aria-label="Why">
                <li
                  v-for="chip in row.chips"
                  :key="chip.key"
                  class="border-line bg-canvas text-ink-2 border px-2 py-0.5 text-[13px] leading-snug"
                  :title="chip.detail !== chip.label ? chip.detail : undefined"
                >
                  {{ chip.label }}
                </li>
              </ul>
            </RouterLink>

            <button
              v-if="canReact"
              type="button"
              class="tap-target text-muted hover:text-ink -mt-1 -mr-2 flex w-12 shrink-0 items-center justify-center text-2xl leading-none"
              aria-haspopup="dialog"
              :aria-label="`${row.customer_name}: on it, handled, or not relevant`"
              @click="openMenu(row)"
            >
              <span aria-hidden="true">⋯</span>
            </button>
          </div>

          <!-- Call the buyer, or drive there. Each appears only when there is
               something real behind it: a dialable number that is not marked
               do-not-call, a street address. -->
          <div v-if="call || directions" class="mt-2.5 flex gap-2">
            <a
              v-if="call"
              :href="call.href"
              class="btn-secondary min-w-0 flex-1 gap-1.5 px-3 text-[15px]"
              :title="`${call.label} · ${call.phone}`"
              @click="onCall(row, call.label)"
            >
              <span class="shrink-0">Call</span>
              <span class="truncate tracking-normal normal-case">{{ call.label }}</span>
            </a>
            <a
              v-if="directions"
              :href="directions"
              target="_blank"
              rel="noopener"
              class="btn-ghost shrink-0 px-3 text-[15px]"
              :aria-label="`Directions to ${row.customer_name}`"
            >
              Directions
            </a>
          </div>
          <div v-else-if="reachLoading" class="mt-2.5 min-h-12" aria-hidden="true" />
        </li>
      </ol>

      <div v-if="!expanded && moreCount > 0" class="border-line border-t p-3 text-center">
        <AppButton variant="ghost" :aria-expanded="false" @click="expanded = true">
          Show {{ moreCount }} more
        </AppButton>
      </div>
    </AsyncState>

    <!-- The reaction menu. A sheet, not a popover: thumb-reachable on a
         phone, and every option is a full-width 48px target. -->
    <AppModal
      v-model:open="menuOpen"
      :title="menuFor?.customer_name ?? ''"
      subtitle="Takes it off your list for a while. Nothing else changes."
    >
      <div class="grid gap-2">
        <AppButton block @click="choose('on_it')">
          {{ REACTION_LABELS.on_it }}
          <span class="text-muted normal-case tracking-normal">· back in {{ windowText('on_it') }}</span>
        </AppButton>
        <AppButton block @click="choose('handled')">
          {{ REACTION_LABELS.handled }}
          <span class="text-muted normal-case tracking-normal">· back in {{ windowText('handled') }}</span>
        </AppButton>
        <AppButton block :aria-expanded="showReasons" @click="showReasons = !showReasons">
          {{ REACTION_LABELS.not_relevant }}
          <span aria-hidden="true">{{ showReasons ? '▾' : '▸' }}</span>
        </AppButton>
        <div v-if="showReasons" class="grid grid-cols-2 gap-2">
          <AppButton
            v-for="reason in NOT_RELEVANT_REASONS"
            :key="reason"
            variant="ghost"
            @click="choose('not_relevant', reason)"
          >
            {{ REASON_LABELS[reason] }}
          </AppButton>
        </div>
        <p v-if="showReasons" class="text-muted text-sm">
          Back in {{ windowText('not_relevant') }}.
        </p>
      </div>
    </AppModal>
  </AppCard>
</template>
