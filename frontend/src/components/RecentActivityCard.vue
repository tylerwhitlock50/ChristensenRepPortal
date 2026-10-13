<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { useSessionStore } from '@/stores/session'
import {
  groupActivity,
  isNewSince,
  useActivityFeed,
  useActivityLastSeen,
  type ShippedItem,
} from '@/composables/useActivityFeed'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count, dayMonth, daysAgo, money } from '@/lib/format'
import {
  senderName,
  shareOrCopy,
  shipmentMessage,
  upsTrackUrl,
} from '@/lib/orderStatusMessage'

/**
 * "Recent activity" on the Overview: the last 14 days of the book, in the
 * three groups a rep acts on from a parking lot —
 *
 *   Shipped     what went out, with the tracking to forward (and the
 *               backorders the dealer was waiting on, called out)
 *   New orders  what came in
 *   Heads-up    promise dates that moved — worth knowing before the
 *               dealer rings to ask
 *
 * Observations, not tasks: the card says what happened and links to the
 * order; what to do about it is the rep's call.
 *
 * Every row opens the order's lines on the account page (?order=). Items
 * dated since the rep's previous look carry a "New" marker.
 */

const session = useSessionStore()
const feed = useActivityFeed()
const seen = useActivityLastSeen(() => session.user?.id)

const groups = computed(() => groupActivity(feed.items.value))
const empty = computed(
  () =>
    groups.value.shipped.length === 0 &&
    groups.value.newOrders.length === 0 &&
    groups.value.headsUp.length === 0,
)

const isNew = (occurredOn: string | null) => isNewSince(occurredOn, seen.previous.value)
const newCount = computed(
  () =>
    groups.value.shipped.filter((i) => isNew(i.occurred_on)).length +
    groups.value.newOrders.filter((i) => isNew(i.occurred_on)).length +
    groups.value.headsUp.filter((i) => isNew(i.occurred_on)).length,
)

const hint = computed(() => {
  if (feed.usingFallback.value) return 'Orders, last 14 days'
  // Short: the card title shares its header row on a phone.
  if (newCount.value > 0) return `${count(newCount.value)} new since last look`
  return 'Last 14 days'
})

/* This look becomes "last looked" once the feed has actually shown
   something — a failed load must not swallow tomorrow's markers. */
watch(
  () => feed.hasData.value && !feed.error.value,
  (shown) => {
    if (shown) seen.markSeen()
  },
  { immediate: true },
)

/** Which order rows link to: its lines, opened on the account page. */
function orderLink(customerKey: string, orderId: string | null) {
  return {
    name: 'account',
    params: { customerKey },
    query: orderId ? { order: orderId } : {},
  }
}

/* ---- Send tracking --------------------------------------------------- */
const toast = ref('')
let toastTimer: ReturnType<typeof setTimeout> | undefined
onBeforeUnmount(() => clearTimeout(toastTimer))

async function sendTracking(item: ShippedItem) {
  const text = shipmentMessage(
    {
      order_id: item.order_id,
      customer_po_number: item.customer_po_number,
      ship_date: item.occurred_on,
      tracking_numbers: item.tracking.join(', '),
    },
    { from: senderName(session.displayName) },
  )
  const outcome = await shareOrCopy(text)
  if (outcome === 'copied' || outcome === 'failed') {
    toast.value =
      outcome === 'copied'
        ? 'Copied. Paste it into a text to the dealer.'
        : "Couldn't copy on this device."
    clearTimeout(toastTimer)
    toastTimer = setTimeout(() => (toast.value = ''), 2500)
  }
}

function slipLine(l: { part: string; before: string | null; after: string | null }): string {
  if (l.after && l.before) return `${l.part}: now ${dayMonth(l.after)}, was ${dayMonth(l.before)}`
  if (l.after) return `${l.part}: now ${dayMonth(l.after)}`
  return l.part
}

/** Groups render at most this many rows; the rest are a count. */
const PER_GROUP = 6
</script>

<template>
  <AppCard title="Recent activity" :hint="hint" :padded="false">
    <AsyncState
      :loading="feed.isPending.value"
      :error="feed.error.value"
      :has-data="feed.hasData.value"
      :updated-at="feed.updatedAt.value"
      :empty="!feed.isPending.value && empty"
      empty-title="Nothing in the last two weeks"
      empty-body="No orders placed, nothing shipped and no promise dates moved on your accounts in 14 days."
      :rows="3"
      @retry="feed.refetch()"
    >
      <!-- Shipped -->
      <section v-if="groups.shipped.length" aria-labelledby="activity-shipped">
        <h3 id="activity-shipped" class="u-label bg-canvas border-line border-b px-4 py-2">
          Shipped
        </h3>
        <ul class="divide-line divide-y">
          <li v-for="s in groups.shipped.slice(0, PER_GROUP)" :key="s.key" class="px-4 py-3">
            <RouterLink
              :to="orderLink(s.customer_key, s.order_id)"
              class="group flex items-start justify-between gap-3"
            >
              <span class="min-w-0">
                <span class="flex items-center gap-2">
                  <span class="text-ink truncate text-[15px] font-semibold group-hover:underline">
                    {{ s.customer_name || s.customer_key }}
                  </span>
                  <span v-if="isNew(s.occurred_on)" class="u-label text-brand shrink-0">New</span>
                </span>
                <span class="text-muted block text-xs">
                  <template v-if="s.order_id">Order {{ s.order_id }} · </template>
                  shipped {{ daysAgo(s.occurred_on) }}
                  <template v-if="s.ship_via"> · {{ s.ship_via }}</template>
                </span>
                <span v-if="s.backorder" class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1">
                  <AppBadge tone="good">Backorder shipped</AppBadge>
                  <span v-if="s.backorderParts.length" class="text-ink-2 text-xs break-words">
                    {{ s.backorderParts.slice(0, 2).join(', ') }}
                    <template v-if="s.backorderParts.length > 2">
                      and {{ s.backorderParts.length - 2 }} more
                    </template>
                  </span>
                </span>
              </span>
              <span
                v-if="s.amount != null"
                class="text-ink shrink-0 text-[15px] font-semibold tabular-nums"
              >
                {{ money(s.amount) }}
              </span>
            </RouterLink>

            <div v-if="s.tracking.length" class="mt-2 grid grid-cols-2 gap-2">
              <a
                :href="upsTrackUrl(s.tracking[0]!)"
                target="_blank"
                rel="noopener noreferrer"
                class="tap-target font-label border-line-2 text-ink hover:border-ink inline-flex items-center justify-center rounded-[2px] border px-2 text-[13px] font-semibold tracking-[0.08em] uppercase"
                :aria-label="`Track ${s.tracking[0]} on ups.com`"
              >
                Track<template v-if="s.tracking.length > 1"> (1 of {{ s.tracking.length }})</template>
              </a>
              <button
                type="button"
                class="tap-target font-label border-ink text-ink hover:bg-ink hover:text-canvas inline-flex items-center justify-center rounded-[2px] border-[1.5px] px-2 text-[13px] font-semibold tracking-[0.08em] uppercase"
                :aria-label="`Send the tracking for ${s.customer_name || s.customer_key} to the dealer`"
                @click="sendTracking(s)"
              >
                Send tracking
              </button>
            </div>
          </li>
        </ul>
        <p
          v-if="groups.shipped.length > PER_GROUP"
          class="text-muted border-line border-t px-4 py-2 text-xs"
        >
          and {{ groups.shipped.length - PER_GROUP }} more shipments
        </p>
      </section>

      <!-- New orders -->
      <section v-if="groups.newOrders.length" aria-labelledby="activity-new">
        <h3
          id="activity-new"
          class="u-label bg-canvas border-line border-b px-4 py-2"
          :class="groups.shipped.length ? 'border-t' : ''"
        >
          New orders
        </h3>
        <ul class="divide-line divide-y">
          <li v-for="o in groups.newOrders.slice(0, PER_GROUP)" :key="`${o.customer_key}-${o.order_id}`">
            <RouterLink
              :to="orderLink(o.customer_key, o.order_id)"
              class="hover:bg-canvas flex items-center justify-between gap-3 px-4 py-3"
            >
              <span class="min-w-0">
                <span class="flex items-center gap-2">
                  <span class="text-ink truncate text-[15px] font-semibold">
                    {{ o.customer_name || o.customer_key }}
                  </span>
                  <span v-if="isNew(o.occurred_on)" class="u-label text-brand shrink-0">New</span>
                </span>
                <span class="text-muted block text-xs">
                  Order {{ o.order_id }} · {{ daysAgo(o.occurred_on) }}
                  <template v-if="o.customer_po_number"> · their PO {{ o.customer_po_number }}</template>
                  <template v-if="o.has_backlog"> · has backorder lines</template>
                </span>
              </span>
              <span class="text-ink shrink-0 text-[15px] font-semibold tabular-nums">
                {{ money(o.amount) }}
              </span>
            </RouterLink>
          </li>
        </ul>
        <p
          v-if="groups.newOrders.length > PER_GROUP"
          class="text-muted border-line border-t px-4 py-2 text-xs"
        >
          and {{ groups.newOrders.length - PER_GROUP }} more orders
        </p>
      </section>

      <!-- Heads-up -->
      <section v-if="groups.headsUp.length" aria-labelledby="activity-heads-up">
        <h3
          id="activity-heads-up"
          class="u-label bg-canvas border-line border-b px-4 py-2"
          :class="groups.shipped.length || groups.newOrders.length ? 'border-t' : ''"
        >
          Heads-up
        </h3>
        <ul class="divide-line divide-y">
          <li v-for="p in groups.headsUp.slice(0, PER_GROUP)" :key="p.key">
            <RouterLink
              :to="orderLink(p.customer_key, p.order_id)"
              class="hover:bg-canvas block px-4 py-3"
            >
              <span class="flex items-center gap-2">
                <span class="text-ink truncate text-[15px] font-semibold">
                  {{ p.customer_name || p.customer_key }}
                </span>
                <span v-if="isNew(p.occurred_on)" class="u-label text-brand shrink-0">New</span>
              </span>
              <span class="text-muted block text-xs">
                Promise date moved on order {{ p.order_id }}
              </span>
              <span
                v-for="(l, i) in p.lines.slice(0, 3)"
                :key="i"
                class="text-ink-2 block text-sm break-words"
              >
                {{ slipLine(l) }}
              </span>
              <span v-if="p.lines.length > 3" class="text-muted block text-xs">
                and {{ p.lines.length - 3 }} more lines
              </span>
            </RouterLink>
          </li>
        </ul>
        <p
          v-if="groups.headsUp.length > PER_GROUP"
          class="text-muted border-line border-t px-4 py-2 text-xs"
        >
          and {{ groups.headsUp.length - PER_GROUP }} more orders
        </p>
      </section>
    </AsyncState>

    <!-- "Send tracking" fell back to the clipboard. Same placement as Lookup's. -->
    <div
      role="status"
      class="pointer-events-none fixed inset-x-0 bottom-[calc(66px+env(safe-area-inset-bottom))] z-40 px-4 pb-3 md:inset-x-auto md:right-4 md:bottom-4 md:w-96 md:px-0 md:pb-0"
    >
      <p v-if="toast" class="bg-ink text-canvas px-4 py-3 text-[15px] leading-snug shadow-lg">
        {{ toast }}
      </p>
    </div>
  </AppCard>
</template>
