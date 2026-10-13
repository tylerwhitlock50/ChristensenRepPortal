<script setup lang="ts">
import { computed } from 'vue'
import { format, parseISO } from 'date-fns'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count, daysAgo, dayMonth, humanize, money, shortDate } from '@/lib/format'
import {
  useAccountOrderHeaders,
  useAccountSummary,
} from '@/composables/useAccountMetrics'
import {
  cadenceSentence,
  isOverdueForCadence,
  useAccountSignals,
} from '@/composables/useAccountSignals'
import { useAccountBacklog } from '@/composables/useIntel'
import { useReorderCandidates } from '@/composables/useReorderCandidates'

/**
 * Before you call — the four things a rep wants in their head before the
 * buyer picks up, in one card under the account header:
 *
 *   their rhythm   "Usually orders every 30 days — 41 since the last one"
 *   last order     when, and what it was, in one line
 *   what's owed    open orders and dollars, the next promise date, and what
 *                  is already past its promise
 *   bought before  up to three things they have bought before that we can
 *                  ship today, each with how much they bought last time
 *   pricing        which price list their customer type buys from
 *
 * Observations, not instructions — the same voice as the rest of the page.
 * "Bought 6 in Oct 2025 · 40 available" is a fact the rep can raise or not.
 *
 * Each of these used to appear somewhere further down, some of them twice;
 * they now appear here and only here. Most of it is data the page already
 * holds — the summary row, the account's signals row — and the rest is
 * fetched only when it has something to say:
 *
 *   - the newest order header, only when the account has ever ordered (it is
 *     the Recent orders card's first page, so that card opens instantly)
 *   - the backlog by SKU, only when there are open orders (likewise the On
 *     backorder card's rows)
 *   - three reorder candidates (report_reorder_candidates, 20261013100000).
 *     On a database without that function the section is simply absent.
 */
const props = withDefaults(
  defineProps<{
    customerKey: string
    /** dim_customer.customer_type — which price lists apply. */
    customerType?: string | null
    canWrite?: boolean
    /** feature.orders: offers "Add to order" when on (and canWrite). */
    ordersEnabled?: boolean
  }>(),
  { customerType: null, canWrite: true, ordersEnabled: false },
)

const emit = defineEmits<{
  /** Open one order's lines; '' = just take me to the orders. */
  'show-order': [orderId: string]
  'show-open-orders': []
}>()

const key = computed(() => props.customerKey)

/* ---- the summary row (already read by the page) ----------------------- */
const summary = useAccountSummary(key)
const s = computed(() => summary.data.value ?? null)

/* ---- rhythm ------------------------------------------------------------- */
const signals = useAccountSignals(key)
const cadence = computed(() => cadenceSentence(signals.data.value ?? null))
const overdue = computed(() => isOverdueForCadence(signals.data.value ?? null))

/* ---- last order --------------------------------------------------------- */
const hasOrdered = computed(() => !!s.value?.last_order_date)
const orders = useAccountOrderHeaders(key, { enabled: hasOrdered })
const newest = computed(() => orders.data.value?.pages[0]?.[0] ?? null)

/**
 * "51234 · $4,250 · 3 lines · their PO 7781 · 2 still open". The order's
 * own date joins the line only when it is not the date already shown above
 * it — the ERP's own last-order field can be newer than any order line.
 */
const newestLine = computed(() => {
  const o = newest.value
  if (!o) return ''
  const parts = [
    o.order_id,
    money(o.bookings),
    `${count(o.line_count)} line${o.line_count === 1 ? '' : 's'}`,
  ]
  if (o.order_date && o.order_date !== s.value?.last_order_date) {
    parts.unshift(shortDate(o.order_date))
  }
  if (o.customer_po_number) parts.push(`their PO ${o.customer_po_number}`)
  parts.push(
    o.open_line_count > 0
      ? `${count(o.backlog_qty)} still open`
      : humanize(o.order_state ?? o.order_status_desc),
  )
  return parts.join(' · ')
})

/* ---- what's owed -------------------------------------------------------- */
const hasOpen = computed(() => (s.value?.open_order_count ?? 0) > 0)
/* An empty key keeps the read disabled (useAccountBacklog runs only with a
   key) — an account with nothing open costs no request here. */
const backlog = useAccountBacklog(computed(() => (hasOpen.value ? props.customerKey : '')))

/**
 * The promise dates come per SKU (v_backlog_by_sku's earliest open-line
 * promise), so "past its promise" counts SKUs whose earliest open line is
 * late — the same rows the On backorder card lists, so the two agree.
 */
const owed = computed(() => {
  const sum = s.value
  if (!sum || sum.open_order_count <= 0) return null
  const n = sum.open_order_count
  const units = sum.backlog_qty ? ` · ${count(Math.round(sum.backlog_qty))} units` : ''
  const headline = `${n} open order${n === 1 ? '' : 's'} · ${money(sum.open_order_value)}${units}`

  const rows = backlog.data.value
  if (!rows) return { headline, detail: '' }
  const today = format(new Date(), 'yyyy-MM-dd')
  const late = rows.filter((r) => r.earliest_promise_date && r.earliest_promise_date < today)
  const next = rows
    .map((r) => r.earliest_promise_date)
    .filter((d): d is string => !!d && d >= today)
    .sort()[0]
  const lateAmount = late.reduce((a, r) => a + r.backlog_amount, 0)
  const detail = [
    next ? `Next promise ${dayMonth(next)}` : '',
    late.length
      ? `${late.length} item${late.length === 1 ? '' : 's'} past promise (${money(lateAmount)})`
      : '',
  ]
    .filter(Boolean)
    .join(' · ')
  return { headline, detail }
})

/* ---- bought before, in stock now --------------------------------------- */
const REORDER_LIMIT = 3
const reorders = useReorderCandidates(key, REORDER_LIMIT)
/* Hidden outright when the function is missing (a preview database without
   20261013100000) or there is nothing to say; a real failure still shows. */
const showReorders = computed(
  () =>
    !reorders.unavailable.value &&
    (reorders.isPending.value || !!reorders.error.value || reorders.rows.value.length > 0),
)
const canOrder = computed(() => props.ordersEnabled && props.canWrite)

function boughtLine(r: { last_qty: number; last_bought_month: string; ats_qty: number }): string {
  const month = format(parseISO(r.last_bought_month), 'MMM yyyy')
  return `Bought ${count(r.last_qty)} in ${month} · ${count(r.ats_qty)} available`
}

/* ---- nothing at all ----------------------------------------------------- */
const nothingToSay = computed(
  () =>
    !summary.isPending.value &&
    !cadence.value &&
    !hasOrdered.value &&
    !owed.value &&
    !showReorders.value &&
    !props.customerType,
)
</script>

<template>
  <AppCard title="Before you call" :padded="false">
    <AsyncState
      :loading="summary.isPending.value"
      :has-data="summary.data.value !== undefined"
      :updated-at="summary.dataUpdatedAt.value"
      :rows="2"
    >
      <p v-if="nothingToSay" class="text-muted px-4 py-3 text-[15px]">
        Nothing on file for this account yet — no orders, nothing owed.
      </p>

      <ul v-else class="divide-line divide-y">
        <!-- Their own rhythm, from the nightly signals: the sentence that
             gives "last order" its meaning. Ember when they are well past
             it. Absent when there is nothing true to say. -->
        <li v-if="cadence" class="px-4 py-3">
          <p class="font-label text-muted text-[11px] font-semibold tracking-[0.14em] uppercase">
            Ordering rhythm
          </p>
          <p
            class="mt-0.5 text-[15px]"
            :class="overdue ? 'text-accent font-semibold' : 'text-ink'"
          >
            {{ cadence }}
          </p>
        </li>

        <!-- Last order: straight to its lines. -->
        <li v-if="s?.last_order_date">
          <button
            type="button"
            class="tap-target hover:bg-canvas flex w-full items-center justify-between gap-3 px-4 py-3 text-left"
            :aria-label="`Last order ${shortDate(s.last_order_date)} — show its lines`"
            @click="emit('show-order', newest?.order_id ?? '')"
          >
            <span class="min-w-0">
              <span class="font-label text-muted block text-[11px] font-semibold tracking-[0.14em] uppercase">
                Last order
              </span>
              <span class="text-ink mt-0.5 block text-[15px] font-semibold">
                {{ shortDate(s.last_order_date)
                }}<template v-if="!cadence"> · {{ daysAgo(s.last_order_date) }}</template>
              </span>
              <span v-if="newestLine" class="text-muted block text-[13px] break-words">
                {{ newestLine }}
              </span>
            </span>
            <svg
              class="text-muted size-4 shrink-0"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M9 6l6 6-6 6" />
            </svg>
          </button>
        </li>

        <!-- What they are still waiting on. Silent when the book is clean:
             "0 open orders" is a line the rep would read past every visit. -->
        <li v-if="owed">
          <button
            type="button"
            class="tap-target hover:bg-canvas flex w-full items-center justify-between gap-3 px-4 py-3 text-left"
            @click="emit('show-open-orders')"
          >
            <span class="min-w-0">
              <span class="font-label text-muted block text-[11px] font-semibold tracking-[0.14em] uppercase">
                Still owed
              </span>
              <span class="text-ink mt-0.5 block text-[15px] font-semibold">
                {{ owed.headline }}
              </span>
              <span v-if="owed.detail" class="text-muted block text-[13px]">
                {{ owed.detail }}
              </span>
            </span>
            <svg
              class="text-muted size-4 shrink-0"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M9 6l6 6-6 6" />
            </svg>
          </button>
        </li>

        <!-- Their own repeat buys that we can ship today. -->
        <li v-if="showReorders" class="px-4 py-3">
          <p class="font-label text-muted text-[11px] font-semibold tracking-[0.14em] uppercase">
            Bought before · in stock now
          </p>
          <AsyncState
            :loading="reorders.isPending.value"
            :error="reorders.error.value"
            :has-data="reorders.data.value !== undefined"
            :updated-at="reorders.dataUpdatedAt.value"
            :rows="1"
            @retry="reorders.refetch()"
          >
            <ul class="divide-line mt-1 divide-y">
              <li
                v-for="r in reorders.rows.value"
                :key="r.part_key"
                class="flex items-center justify-between gap-3 py-2"
              >
                <span class="min-w-0">
                  <span class="text-ink block text-[15px] font-semibold">
                    {{ r.part_id ?? r.part_key }}
                  </span>
                  <span
                    v-if="r.part_description"
                    class="text-ink-2 block truncate text-[13px]"
                  >
                    {{ r.part_description }}
                  </span>
                  <span class="text-muted block text-[13px] tabular-nums">
                    {{ boughtLine(r) }}
                  </span>
                </span>
                <RouterLink
                  v-if="canOrder && r.part_id"
                  :to="{ name: 'orders-new', query: { customer: customerKey, sku: r.part_id } }"
                  class="tap-target font-label border-ink text-ink hover:bg-ink hover:text-canvas inline-flex shrink-0 items-center rounded-[2px] border-[1.5px] px-3 text-[12px] font-semibold tracking-[0.1em] uppercase"
                >
                  Add to order
                </RouterLink>
              </li>
            </ul>
          </AsyncState>
        </li>

        <!-- Which list prices them. -->
        <li v-if="customerType">
          <RouterLink
            :to="{ name: 'intel-price-lists' }"
            class="tap-target hover:bg-canvas flex w-full items-center justify-between gap-3 px-4 py-3"
          >
            <span class="min-w-0">
              <span class="font-label text-muted block text-[11px] font-semibold tracking-[0.14em] uppercase">
                Pricing
              </span>
              <span class="text-ink mt-0.5 block text-[15px]">
                {{ humanize(customerType) }} price list
              </span>
            </span>
            <svg
              class="text-muted size-4 shrink-0"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M9 6l6 6-6 6" />
            </svg>
          </RouterLink>
        </li>
      </ul>
    </AsyncState>
  </AppCard>
</template>
