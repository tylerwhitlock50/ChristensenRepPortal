<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useRoute, useRouter, type RouteLocationRaw } from 'vue-router'
import { refDebounced } from '@vueuse/core'
import { useQueryClient } from '@tanstack/vue-query'
import { useSessionStore } from '@/stores/session'
import { useAccountNames } from '@/composables/useAccounts'
import { MIN_SEARCH_LENGTH, useGlobalSearch } from '@/composables/useGlobalSearch'
import {
  cachedAccountName,
  nameRecentAccounts,
  useRecentAccounts,
} from '@/composables/useRecentAccounts'
import { MIN_LOOKUP_LENGTH, statusSentence } from '@/composables/useOrderLookup'
import { count, daysAgo } from '@/lib/format'

/**
 * The header search's sheet (GlobalSearch.vue owns the button and loads
 * this on first use, so none of it rides in the app's entry chunk).
 *
 * A full-screen sheet on a phone, a panel under the header from md up. It
 * is a dialog: focus moves into the box, Tab stays inside, Esc or Close
 * leaves (the button gets focus back).
 *
 * Empty, it lists the dealers this rep opened lately. Typed, it shows
 * Dealers, Orders and Products (useGlobalSearch); choosing one navigates
 * and closes. Enter takes the first result.
 */

const emit = defineEmits<{ close: [restoreFocus: boolean] }>()

const route = useRoute()
const router = useRouter()
const session = useSessionStore()
const queryClient = useQueryClient()

const userId = () => session.user?.id ?? null
const { recents } = useRecentAccounts(userId)

const term = ref('')
// Every keystroke would otherwise be up to three round trips over LTE.
const debounced = refDebounced(term, 300)
const search = useGlobalSearch(debounced, true)

const panel = ref<HTMLElement | null>(null)
const input = ref<HTMLInputElement | null>(null)

function close(restoreFocus = true) {
  emit('close', restoreFocus)
}

onMounted(async () => {
  document.body.style.overflow = 'hidden'
  await nextTick()
  input.value?.focus()
})
onBeforeUnmount(() => {
  document.body.style.overflow = ''
})

/* A navigation from anywhere (a result, the back button) closes it. */
watch(
  () => route.fullPath,
  () => close(false),
)

/** Esc closes; Tab and Shift+Tab wrap inside the dialog. */
function onPanelKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape') {
    e.preventDefault()
    close()
    return
  }
  if (e.key !== 'Tab' || !panel.value) return
  const focusable = Array.from(
    panel.value.querySelectorAll<HTMLElement>(
      'a[href], button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])',
    ),
  ).filter((el) => el.offsetParent !== null || el === document.activeElement)
  if (focusable.length === 0) return
  const first = focusable[0]!
  const last = focusable[focusable.length - 1]!
  if (e.shiftKey && document.activeElement === first) {
    e.preventDefault()
    last.focus()
  } else if (!e.shiftKey && document.activeElement === last) {
    e.preventDefault()
    first.focus()
  }
}

/* ---- results ------------------------------------------------------------ */

type Hit = { key: string; to: RouteLocationRaw; title: string; detail: string }

const dealerHits = computed<Hit[]>(() =>
  search.dealers.value.map((d) => ({
    key: `d-${d.customer_key}`,
    to: { name: 'account', params: { customerKey: d.customer_key } },
    title: d.customer_name || d.customer_key,
    detail: [
      [d.sold_to_city, d.sold_to_state].filter(Boolean).join(', '),
      d.customer_key,
      d.active_flag !== 'Y' || d.deactivated_at ? 'inactive' : '',
    ]
      .filter(Boolean)
      .join(' · '),
  })),
)

const orderHits = computed<Hit[]>(() =>
  search.orders.value.map((o) => ({
    key: `o-${o.customer_key}-${o.order_id}`,
    to: {
      name: 'account',
      params: { customerKey: o.customer_key },
      query: { order: o.order_id },
    },
    title: `${o.order_id} · ${o.customer_name || o.customer_key}`,
    detail: [
      o.customer_po_number ? `Their PO ${o.customer_po_number}` : '',
      statusSentence(o),
      o.order_date ? `ordered ${daysAgo(o.order_date)}` : '',
    ]
      .filter(Boolean)
      .join(' · '),
  })),
)

const productHits = computed<Hit[]>(() =>
  search.products.value.map((p) => ({
    key: `p-${p.part_key}`,
    // The ATS list, with the part in ?q= for its filter box to pick up.
    to: { name: 'intel-ats', query: { q: p.part_id ?? p.part_key } },
    title: p.part_id ?? p.part_key,
    detail: [p.part_description, `${count(p.ats_qty)} available`].filter(Boolean).join(' · '),
  })),
)

const groups = computed(() =>
  [
    { id: 'dealers', label: 'Dealers', hits: dealerHits.value, loading: search.dealersLoading.value, error: search.dealersError.value },
    { id: 'orders', label: 'Orders', hits: orderHits.value, loading: search.ordersLoading.value, error: search.ordersError.value },
    { id: 'products', label: 'Products in stock', hits: productHits.value, loading: search.productsLoading.value, error: search.productsError.value },
  ].filter((g) => g.hits.length > 0 || g.loading || g.error),
)

const anyLoading = computed(() => groups.value.some((g) => g.loading))
const nothing = computed(
  () => search.longEnough.value && !anyLoading.value && groups.value.length === 0,
)
/* The debounce is still running: the results on screen are for an older
   term. Say "Searching" rather than "Nothing matches". */
const typing = computed(() => term.value.trim() !== debounced.value.trim())

function go(to: RouteLocationRaw) {
  void router.push(to)
  close(false)
}

function onEnter() {
  const first = groups.value.find((g) => g.hits.length)?.hits[0]
  if (first) go(first.to)
}

/* ---- recents --------------------------------------------------------- */

/* Names for recents recorded before their account had loaded: from the
   cache if it has them now, else one small read — only while the sheet is
   open and only for the nameless. */
const namelessKeys = computed(() =>
  recents.value.filter((r) => !r.customer_name).map((r) => r.customer_key),
)
const names = useAccountNames(namelessKeys)
watch(
  [namelessKeys, () => names.data.value],
  ([keys, fetched]) => {
    if (keys.length === 0) return
    const found: Record<string, string> = { ...(fetched ?? {}) }
    for (const k of keys) {
      const cached = cachedAccountName(queryClient, k)
      if (cached) found[k] = cached
    }
    nameRecentAccounts(userId(), found)
  },
  { immediate: true },
)
</script>

<template>
  <Teleport to="body">
    <div
      class="text-ink fixed inset-0 z-50 md:bg-ink/40 md:px-4 md:pt-16"
      @click.self="close()"
    >
      <div
        ref="panel"
        role="dialog"
        aria-modal="true"
        aria-label="Search"
        class="bg-surface flex h-full flex-col md:mx-auto md:h-auto md:max-h-[75vh] md:w-full md:max-w-xl md:border md:border-line md:shadow-lg"
        @keydown="onPanelKeydown"
      >
        <!-- The box. On a phone it sits where the header was. -->
        <div class="border-line flex items-center gap-2 border-b pt-[max(0.375rem,env(safe-area-inset-top))] pr-1 pb-1.5 pl-4">
          <svg
            class="text-muted size-5 shrink-0"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            stroke-linecap="round"
            stroke-linejoin="round"
            aria-hidden="true"
          >
            <circle cx="11" cy="11" r="7" />
            <path d="M20 20l-3.5-3.5" />
          </svg>
          <label class="min-w-0 flex-1">
            <span class="sr-only">Search dealers, orders and products</span>
            <input
              ref="input"
              v-model="term"
              type="search"
              placeholder="Dealer, PO, order # or SKU"
              autocapitalize="none"
              autocomplete="off"
              spellcheck="false"
              enterkeyhint="search"
              class="tap-target w-full bg-transparent text-base outline-none"
              @keydown.enter.prevent="onEnter"
            />
          </label>
          <button
            type="button"
            class="tap-target font-label text-muted hover:text-ink flex min-w-12 shrink-0 items-center justify-center px-3 text-[13px] font-semibold tracking-[0.12em] uppercase"
            @click="close()"
          >
            Close
          </button>
        </div>

        <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain pb-[env(safe-area-inset-bottom)]">
          <!-- Empty box: where the rep has been. -->
          <template v-if="!term.trim()">
            <section v-if="recents.length" aria-labelledby="search-recent">
              <h2 id="search-recent" class="u-label bg-canvas border-line border-b px-4 py-2">
                Recently opened
              </h2>
              <ul class="divide-line divide-y">
                <li v-for="r in recents" :key="r.customer_key">
                  <RouterLink
                    :to="{ name: 'account', params: { customerKey: r.customer_key } }"
                    class="hover:bg-canvas flex min-h-12 flex-col justify-center px-4 py-2"
                    @click="close(false)"
                  >
                    <span class="text-ink truncate text-[15px] font-semibold">
                      {{ r.customer_name || r.customer_key }}
                    </span>
                    <span class="text-muted text-xs">
                      {{ r.customer_key }}<template v-if="r.at"> · opened {{ daysAgo(r.at) }}</template>
                    </span>
                  </RouterLink>
                </li>
              </ul>
            </section>
            <p class="text-muted px-4 py-4 text-[15px] leading-relaxed">
              Find a dealer by name, city or customer number, an order by
              their PO, our order number or a tracking number, or a product
              by SKU.
            </p>
          </template>

          <p v-else-if="!search.longEnough.value" class="text-muted px-4 py-4 text-[15px]">
            Keep typing — at least {{ MIN_SEARCH_LENGTH }} characters.
          </p>

          <template v-else>
            <section
              v-for="g in groups"
              :key="g.id"
              :aria-labelledby="`search-${g.id}`"
            >
              <h2 :id="`search-${g.id}`" class="u-label bg-canvas border-line border-b px-4 py-2">
                {{ g.label }}
              </h2>
              <p v-if="g.loading && !g.hits.length" class="text-muted px-4 py-3 text-sm" aria-busy="true">
                Searching…
              </p>
              <p v-else-if="g.error && !g.hits.length" class="text-muted px-4 py-3 text-sm">
                Couldn't search {{ g.label.toLowerCase() }} just now.
              </p>
              <ul class="divide-line divide-y">
                <li v-for="h in g.hits" :key="h.key">
                  <RouterLink
                    :to="h.to"
                    class="hover:bg-canvas flex min-h-12 flex-col justify-center px-4 py-2"
                    @click="close(false)"
                  >
                    <span class="text-ink text-[15px] font-semibold break-words">{{ h.title }}</span>
                    <span v-if="h.detail" class="text-muted text-xs break-words">{{ h.detail }}</span>
                  </RouterLink>
                </li>
              </ul>
            </section>

            <p v-if="!search.ordersLongEnough.value" class="text-muted px-4 py-3 text-sm">
              Orders search from {{ MIN_LOOKUP_LENGTH }} characters.
            </p>

            <div v-if="nothing" class="px-4 py-4">
              <p class="text-ink text-[17px] font-semibold">
                {{ typing ? 'Searching…' : 'Nothing matches that' }}
              </p>
              <p v-if="!typing" class="text-muted mt-1 text-[15px] leading-relaxed">
                Only your own accounts are searched. Try fewer characters, or
                just the digits of a PO.
              </p>
            </div>

            <RouterLink
              v-if="search.ordersLongEnough.value"
              :to="{ name: 'lookup', query: { q: term.trim() } }"
              class="font-label text-ink border-line hover:bg-canvas flex min-h-12 items-center border-t px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
              @click="close(false)"
            >
              All order matches in Find →
            </RouterLink>
          </template>
        </div>
      </div>
    </div>
  </Teleport>
</template>
