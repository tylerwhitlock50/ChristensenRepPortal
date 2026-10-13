<script setup lang="ts">
import { computed } from 'vue'
import { useAccountOrderLines } from '@/composables/useAccountMetrics'
import type { OrderLookupRow } from '@/composables/useOrderLookup'
import { useAccountReach } from '@/composables/useBestContacts'
import { useSessionStore } from '@/stores/session'
import AppBadge from '@/components/ui/AppBadge.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count, humanize, shortDate } from '@/lib/format'
import {
  orderStatusMessage,
  senderName,
  smsHref,
  smsPlatform,
  trackingList,
  upsTrackUrl,
} from '@/lib/orderStatusMessage'

/**
 * One lookup result's lines, opened in place: which guns shipped, which are
 * still open and when they are expected, and the tracking for each line —
 * the part of "where's my order?" the result card can't answer, without
 * leaving the page the dealer's number was typed into.
 *
 * Mounted only while the rep has the lines open, so the three reads below
 * (lines, per-line tracking, the account's best contact) cost nothing until
 * the tap.
 */
const props = defineProps<{ order: OrderLookupRow }>()

const session = useSessionStore()

const customerKey = computed(() => props.order.customer_key)
const orderId = computed(() => props.order.order_id)

const linesQuery = useAccountOrderLines(customerKey, orderId)
// Each line carries its own tracking numbers (null without 20261013150000).
const lines = computed(() => linesQuery.data.value ?? [])

/* ---- "Text the buyer" ----------------------------------------------------
   The account's best contact (lib/contacts ranking: a real buyer over the
   AP mailbox the ERP calls primary). `callable` is false for a contact
   flagged do-not-call, and a do-not-call flag is honoured as do-not-text
   too: the flag records that the dealer asked not to be contacted on that
   number, and a text to it is the same intrusion as a call. No link then,
   and the reason is said rather than the button silently missing. */
const reachQuery = useAccountReach(customerKey)
const best = computed(() => reachQuery.reach.value?.best ?? null)
const buyerName = computed(() => best.value?.contact?.label ?? null)

const message = computed(() =>
  orderStatusMessage(props.order, {
    lines: lines.value.length ? lines.value : null,
    from: senderName(session.displayName),
  }),
)
const textHref = computed(() =>
  best.value?.callable
    ? smsHref(best.value.contact?.phone, message.value, smsPlatform())
    : null,
)
const textNote = computed(() => {
  if (reachQuery.isPending.value || reachQuery.error.value) return ''
  const b = best.value
  if (!b?.contact) return 'No buyer number on file to text.'
  // The flag, not the rank: a rep-entered primary keeps its 'rep-primary'
  // kind even when it is flagged do-not-call.
  if (b.contact.do_not_call === true) {
    return `${buyerName.value} is marked do not call, so no text either.`
  }
  if (!textHref.value) return `No number on file for ${buyerName.value}.`
  return ''
})

/** "3 ordered · 1 shipped · 2 open" — the three numbers a dealer asks for. */
function qtySentence(l: (typeof lines.value)[number]): string {
  const parts = [`${count(l.order_qty)} ordered`]
  const shipped = Number(l.total_shipped_qty_to_date ?? 0)
  if (shipped > 0) parts.push(`${count(shipped)} shipped`)
  if (l.is_backlog_line && Number(l.backlog_qty ?? 0) > 0) {
    parts.push(`${count(l.backlog_qty)} open`)
  }
  return parts.join(' · ')
}
</script>

<template>
  <div class="border-line mt-3 border-t">
    <AsyncState
      :loading="linesQuery.isPending.value"
      :error="linesQuery.error.value"
      :has-data="linesQuery.data.value !== undefined"
      :updated-at="linesQuery.dataUpdatedAt.value"
      :empty="!linesQuery.isPending.value && lines.length === 0"
      empty-title="No lines on this order"
      :rows="2"
      @retry="linesQuery.refetch()"
    >
      <ul class="divide-line divide-y" :aria-label="`Lines on order ${order.order_id}`">
        <li v-for="l in lines" :key="l.line_num" class="py-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="text-ink font-medium break-words">
                {{ l.part_id ?? l.part_key ?? '—' }}
              </p>
              <p v-if="l.part_description" class="text-muted text-[13px] break-words">
                {{ l.part_description }}
              </p>
            </div>
            <AppBadge v-if="l.is_backlog_line" tone="high" class="shrink-0">
              Open
            </AppBadge>
            <span v-else class="text-muted shrink-0 text-[13px]">
              {{ humanize(l.line_status_desc) }}
            </span>
          </div>

          <p class="text-ink-2 mt-1 text-[13px] tabular-nums">
            {{ qtySentence(l) }}
          </p>
          <p v-if="l.is_backlog_line" class="text-ink-2 text-[13px]">
            <template v-if="l.promise_date">
              Promised {{ shortDate(l.promise_date) }}
            </template>
            <template v-else-if="l.desired_ship_date">
              Est. production {{ shortDate(l.desired_ship_date) }}
            </template>
            <template v-else>No date yet</template>
          </p>

          <p
            v-if="trackingList(l.tracking_numbers).length"
            class="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1"
          >
            <span class="u-label text-muted">Tracking</span>
            <a
              v-for="t in trackingList(l.tracking_numbers)"
              :key="t"
              :href="upsTrackUrl(t)"
              target="_blank"
              rel="noopener noreferrer"
              class="text-ink inline-flex min-h-11 items-center text-sm break-all underline decoration-dotted underline-offset-2"
              :title="`Track ${t} on ups.com`"
            >
              {{ t }}
            </a>
          </p>
        </li>
      </ul>
    </AsyncState>

    <!-- The dealer's buyer, pre-addressed. The share button on the card
         reaches any app; this one goes straight to the person. -->
    <div v-if="textHref || textNote" class="border-line border-t pt-3">
      <a
        v-if="textHref"
        :href="textHref"
        class="tap-target font-label border-ink text-ink hover:bg-ink hover:text-canvas inline-flex w-full items-center justify-center gap-2 rounded-[2px] border-[1.5px] px-4 text-[13px] font-semibold tracking-[0.12em] uppercase sm:w-auto"
      >
        <svg
          class="size-4 shrink-0"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M4 5h16v11H9l-5 4z" />
        </svg>
        <span class="truncate">Text {{ buyerName }}</span>
      </a>
      <p v-else class="text-muted text-[13px]">{{ textNote }}</p>
    </div>
  </div>
</template>
