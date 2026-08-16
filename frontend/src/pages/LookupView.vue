<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { refDebounced } from '@vueuse/core'
import {
  MIN_LOOKUP_LENGTH,
  matchLabel,
  statusSentence,
  useOrderLookup,
} from '@/composables/useOrderLookup'
import AppBadge from '@/components/ui/AppBadge.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count, money, shortDate } from '@/lib/format'

/**
 * "Where's my order?" — the answer, from a number.
 *
 * A dealer on the phone quotes ONE of three things: their own PO number, our
 * order number, or a tracking number. Every other screen in this app requires
 * the rep to know which account it belongs to first, which is exactly the
 * thing they are trying to work out. This page takes any of the three.
 *
 * Deep-linkable (?q=) so a rep can send a colleague the lookup, not just the
 * answer.
 */

const route = useRoute()
const router = useRouter()

const term = ref(typeof route.query.q === 'string' ? route.query.q : '')
// The rep is typing a number off a piece of paper — every keystroke would
// otherwise be a round trip over LTE.
const debounced = refDebounced(term, 350)

const { data, isPending, error, refetch, longEnough } = useOrderLookup(debounced)
const rows = computed(() => data.value ?? [])

watch(debounced, (q) => {
  void router.replace({ query: q.trim() ? { q: q.trim() } : {} })
})

/** UPS is the only carrier; the number goes straight to their tracking page. */
function upsTrackUrl(trackingNumber: string): string {
  return `https://www.ups.com/track?tracknum=${encodeURIComponent(trackingNumber.trim())}`
}

/** A row can carry several parcels' numbers, comma-joined by the RPC. */
function trackingList(value: string | null): string[] {
  return (value ?? '')
    .split(',')
    .map((v) => v.trim())
    .filter(Boolean)
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
      :loading="isPending"
      :error="error"
      :empty="!isPending && !error && rows.length === 0"
      empty-title="Nothing matches that"
      empty-body="Check the number, or try just the digits — a dealer's PO prefix isn't always what we recorded. Only orders on your own accounts are searched."
      :rows="3"
      @retry="refetch()"
    >
      <ul class="divide-line border-line bg-surface divide-y border">
        <li v-for="row in rows" :key="`${row.customer_key}-${row.order_id}`" class="p-4">
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

            <span v-if="row.next_promise_date" class="text-ink-2 text-sm">
              Promised {{ shortDate(row.next_promise_date) }}
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
        </li>
      </ul>

      <p
        v-if="rows.length >= 25"
        class="font-label text-muted mt-4 text-center text-xs font-semibold tracking-[0.12em] uppercase"
      >
        Showing the 25 newest matches — narrow the search to see older ones
      </p>
    </AsyncState>
  </div>
</template>
