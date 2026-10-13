<script setup lang="ts">
import { computed, onBeforeUnmount, reactive, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { refDebounced } from '@vueuse/core'
import { useQueryClient } from '@tanstack/vue-query'
import {
  MIN_LOOKUP_LENGTH,
  cachedOrderLines,
  matchLabel,
  statusSentence,
  useOrderLookup,
  type OrderLookupRow,
} from '@/composables/useOrderLookup'
import { useSessionStore } from '@/stores/session'
import AppBadge from '@/components/ui/AppBadge.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import LookupOrderLines from '@/components/LookupOrderLines.vue'
import { count, money, shortDate } from '@/lib/format'
import {
  isPastDate,
  orderStatusMessage,
  senderName,
  shareOrCopy,
  trackingList,
  upsTrackUrl,
} from '@/lib/orderStatusMessage'

/**
 * "Where's my order?" — the answer, from a number.
 *
 * A dealer on the phone quotes ONE of three things: their own PO number, our
 * order number, or a tracking number. Every other screen in this app requires
 * the rep to know which account it belongs to first, which is exactly the
 * thing they are trying to work out. This page takes any of the three.
 *
 * Each result then answers the follow-ups without leaving the page: its
 * lines open in place ("which guns are still open?"), "Send status" hands
 * the dealer-ready answer to the phone's share sheet, and "Open in account"
 * lands on that order's lines on the account page.
 *
 * Deep-linkable (?q=) so a rep can send a colleague the lookup, not just the
 * answer.
 */

const route = useRoute()
const router = useRouter()
const session = useSessionStore()
const queryClient = useQueryClient()

const term = ref(typeof route.query.q === 'string' ? route.query.q : '')
// The rep is typing a number off a piece of paper — every keystroke would
// otherwise be a round trip over LTE.
const debounced = refDebounced(term, 350)

const { data, dataUpdatedAt, isPending, fetchStatus, error, refetch, longEnough } =
  useOrderLookup(debounced)
/* No signal (or the offline open): the lookup waits for one instead of
   failing, and a waiting read is not a loading one. */
const waitingForSignal = computed(() => fetchStatus.value === 'paused' && data.value === undefined)
const rows = computed(() => data.value ?? [])

watch(debounced, (q) => {
  void router.replace({ query: q.trim() ? { q: q.trim() } : {} })
})

const rowKey = (row: OrderLookupRow) => `${row.customer_key}-${row.order_id}`

/* Which results have their lines open. Several at once is fine — a dealer
   with two POs in flight asks about both. */
const open = reactive(new Set<string>())
function toggleLines(row: OrderLookupRow) {
  const k = rowKey(row)
  if (open.has(k)) open.delete(k)
  else open.add(k)
}

/* ---- Send status ---------------------------------------------------------
   The share sheet on a phone, the clipboard elsewhere. The lines are used
   when they are already loaded (the rep opened them); nothing is fetched
   first, because Safari only opens the share sheet inside the tap. */
const toast = ref('')
let toastTimer: ReturnType<typeof setTimeout> | undefined
function say(text: string) {
  toast.value = text
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (toast.value = ''), 2500)
}
onBeforeUnmount(() => clearTimeout(toastTimer))

async function sendStatus(row: OrderLookupRow) {
  const text = orderStatusMessage(row, {
    lines: cachedOrderLines(queryClient, row.customer_key, row.order_id),
    from: senderName(session.displayName),
  })
  const outcome = await shareOrCopy(text)
  if (outcome === 'copied') say('Copied. Paste it into a text to the dealer.')
  else if (outcome === 'failed') say("Couldn't copy on this device.")
}
</script>

<template>
  <div class="space-y-5">
    <header>
      <h1 class="u-display text-[34px]">Find an order</h1>
      <p class="text-muted mt-1 text-[15px]">
        Type the dealer's PO number, our order number, or a tracking number.
      </p>
    </header>

    <label class="block">
      <span class="sr-only">Order, PO, or tracking number</span>
      <input
        v-model="term"
        type="search"
        placeholder="PO 44182, SO51234, or 1Z…"
        autocapitalize="none"
        spellcheck="false"
        autofocus
        class="field"
      />
    </label>

    <p v-if="!longEnough" class="text-muted text-[15px]">
      <template v-if="term.trim()">
        Keep going — at least {{ MIN_LOOKUP_LENGTH }} characters.
      </template>
      <template v-else>
        This searches every account in your book, so you don't need to know
        which dealer it was.
      </template>
    </p>

    <AsyncState
      v-else
      :loading="isPending && !waitingForSignal"
      :error="error"
      :has-data="data !== undefined"
      :updated-at="dataUpdatedAt"
      :empty="(!isPending || waitingForSignal) && rows.length === 0"
      :empty-title="waitingForSignal ? 'You\'re offline' : 'Nothing matches that'"
      :empty-body="
        waitingForSignal
          ? 'Find needs a signal to search orders. It will run when you\'re back online.'
          : 'Check the number, or try just the digits — a dealer\'s PO prefix isn\'t always what we recorded. Only orders on your own accounts are searched.'
      "
      :rows="3"
      @retry="refetch()"
    >
      <ul class="divide-line border-line bg-surface divide-y border">
        <li v-for="row in rows" :key="rowKey(row)" class="p-4">
          <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
            <RouterLink
              :to="{ name: 'account', params: { customerKey: row.customer_key } }"
              class="text-ink text-[17px] font-semibold underline-offset-4 hover:underline"
            >
              {{ row.customer_name || row.customer_key }}
            </RouterLink>
            <span class="u-display text-ink shrink-0 text-lg tabular-nums">
              {{ money(row.bookings) }}
            </span>
          </div>

          <p class="text-muted mt-0.5 text-sm tabular-nums">
            Order {{ row.order_id }} · {{ shortDate(row.order_date) }} ·
            {{ count(row.line_count) }} lines
          </p>

          <!-- The number the dealer is holding, said back to them. -->
          <p v-if="row.customer_po_number" class="text-ink-2 mt-1 text-sm break-words">
            Their PO {{ row.customer_po_number }}
          </p>

          <div class="mt-2 flex flex-wrap items-center gap-2">
            <AppBadge v-if="row.open_line_count > 0" tone="high">
              {{ statusSentence(row) }}
            </AppBadge>
            <AppBadge v-else tone="good">{{ statusSentence(row) }}</AppBadge>

            <span
              v-if="row.next_promise_date"
              class="text-sm"
              :class="isPastDate(row.next_promise_date) ? 'text-accent' : 'text-ink-2'"
            >
              Promised {{ shortDate(row.next_promise_date) }}
              <template v-if="isPastDate(row.next_promise_date)"> · past promise</template>
            </span>
            <span
              v-else-if="row.next_desired_ship_date"
              class="text-ink-2 text-sm"
            >
              Est. production {{ shortDate(row.next_desired_ship_date) }}
            </span>
            <span v-if="row.last_ship_date" class="text-muted text-sm">
              Last shipped {{ shortDate(row.last_ship_date) }}
            </span>
          </div>

          <div
            v-if="trackingList(row.tracking_numbers).length"
            class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1"
          >
            <span class="u-label text-muted">Tracking</span>
            <a
              v-for="t in trackingList(row.tracking_numbers)"
              :key="t"
              :href="upsTrackUrl(t)"
              target="_blank"
              rel="noopener noreferrer"
              class="text-ink text-sm underline decoration-dotted underline-offset-2"
              :title="`Track ${t} on ups.com`"
            >
              {{ t }}
            </a>
          </div>

          <!-- Say WHY this row came back. With three searchable fields, a hit
               on a tracking number looks like a mystery otherwise. -->
          <p v-if="matchLabel(row.matched_on)" class="text-muted mt-2 text-xs">
            {{ matchLabel(row.matched_on) }}
          </p>

          <!-- Three equal columns at 390px; each is a 48px tap target. -->
          <div class="mt-3 grid grid-cols-3 gap-2">
            <button
              type="button"
              class="tap-target font-label border-line-2 text-ink hover:border-ink inline-flex items-center justify-center gap-1 rounded-[2px] border px-1.5 text-[13px] font-semibold tracking-[0.08em] uppercase"
              :aria-expanded="open.has(rowKey(row))"
              :aria-controls="`lines-${rowKey(row)}`"
              @click="toggleLines(row)"
            >
              {{ open.has(rowKey(row)) ? 'Hide lines' : 'Show lines' }}
              <svg
                class="size-4 shrink-0 transition-transform"
                :class="open.has(rowKey(row)) ? 'rotate-180' : ''"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <path d="M6 9l6 6 6-6" />
              </svg>
            </button>
            <button
              type="button"
              class="tap-target font-label border-ink text-ink hover:bg-ink hover:text-canvas inline-flex items-center justify-center rounded-[2px] border-[1.5px] px-1.5 text-[13px] font-semibold tracking-[0.08em] uppercase"
              :aria-label="`Send the status of order ${row.order_id} to the dealer`"
              @click="sendStatus(row)"
            >
              Send status
            </button>
            <RouterLink
              :to="{
                name: 'account',
                params: { customerKey: row.customer_key },
                query: { order: row.order_id },
              }"
              class="tap-target font-label border-line-2 text-ink hover:border-ink inline-flex items-center justify-center rounded-[2px] border px-1.5 text-center text-[13px] font-semibold tracking-[0.08em] uppercase"
              :aria-label="`Open order ${row.order_id} on the account page`"
            >
              Open in account
            </RouterLink>
          </div>

          <LookupOrderLines
            v-if="open.has(rowKey(row))"
            :id="`lines-${rowKey(row)}`"
            :order="row"
          />
        </li>
      </ul>

      <p
        v-if="rows.length >= 25"
        class="font-label text-muted mt-4 text-center text-xs font-semibold tracking-[0.12em] uppercase"
      >
        Showing the 25 newest matches — narrow the search to see older ones
      </p>
    </AsyncState>

    <!-- "Send status" fell back to the clipboard. Above the phone's bottom
         bar; bottom-right from md up. The live region is always there so a
         screen reader hears the message when it appears; it takes no taps. -->
    <div
      role="status"
      class="pointer-events-none fixed inset-x-0 bottom-[calc(66px+env(safe-area-inset-bottom))] z-40 px-4 pb-3 md:inset-x-auto md:right-4 md:bottom-4 md:w-96 md:px-0 md:pb-0"
    >
      <p v-if="toast" class="bg-ink text-canvas px-4 py-3 text-[15px] leading-snug shadow-lg">
        {{ toast }}
      </p>
    </div>
  </div>
</template>
