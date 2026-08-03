<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { refDebounced } from '@vueuse/core'
import { useAccountSearch } from '@/composables/useAccounts'
import {
  currentGoalYear,
  paceLabel,
  useAccountGoalsFor,
  useAccountsBehindGoal,
  type AccountGoalProgress,
} from '@/composables/useAccountGoals'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import { count as fmtCount, daysAgo, humanize, money } from '@/lib/format'

const route = useRoute()
const router = useRouter()

const search = ref('')
// Every keystroke would otherwise be a round trip over LTE.
const debouncedSearch = refDebounced(search, 300)
const activeOnly = ref(true)

/* ---- goal mode ----------------------------------------------------------
   Two sources, one list. The default is the whole book, paged and searched in
   Postgres; "Behind goal" swaps in the goals ranked worst-first.

   That ranking has to happen in Postgres too. The accounts a rep needs are
   the ones at the BOTTOM of it, and sorting a page of 50 client-side would
   silently rank only the 50 that happened to load. Only accounts with a goal
   have a row, so the ranked list is small enough to hold whole.

   Deep-linkable (?goal=behind) because the Today page's book line points here.
------------------------------------------------------------------------- */
const goalMode = ref(route.query.goal === 'behind')
const goalYear = currentGoalYear()

watch(goalMode, (on) => {
  void router.replace({
    query: { ...route.query, goal: on ? 'behind' : undefined },
  })
})

const {
  data,
  isPending,
  error,
  refetch,
  fetchNextPage,
  hasNextPage,
  isFetchingNextPage,
} = useAccountSearch(debouncedSearch, activeOnly)

const rows = computed(() => data.value?.pages.flatMap((p) => p.rows) ?? [])
const total = computed(() => data.value?.pages[0]?.total ?? 0)

/**
 * Goals for the accounts currently on screen — one `.in()` over the visible
 * keys, not a query per row. Absent goals simply don't come back and the row
 * renders exactly as it did before.
 */
const { data: goals } = useAccountGoalsFor(
  computed(() => (goalMode.value ? [] : rows.value.map((r) => r.customer_key))),
  goalYear,
)

const behind = useAccountsBehindGoal(goalYear)

/**
 * The ranked list is already bounded and sorted by Postgres, so the search box
 * and the active-only chip filter it in place rather than round-tripping.
 */
const behindRows = computed(() => {
  const term = search.value.trim().toLowerCase()
  return (behind.data.value ?? []).filter((g) => {
    if (activeOnly.value && g.active_flag !== 'Y') return false
    if (!term) return true
    return (
      (g.customer_name ?? '').toLowerCase().includes(term) ||
      g.customer_key.toLowerCase().includes(term) ||
      (g.sold_to_city ?? '').toLowerCase().includes(term)
    )
  })
})

function place(a: { sold_to_city: string | null; sold_to_state: string | null }) {
  return [humanize(a.sold_to_city), a.sold_to_state]
    .filter((v) => v && v !== '—')
    .join(', ')
}

function goalFor(customerKey: string): AccountGoalProgress | undefined {
  return goals.value?.[customerKey]
}

/** "$49,300 of $85,000" — the two numbers, in the order a rep reads them. */
function goalAmounts(g: AccountGoalProgress): string {
  return `${money(g.revenue_to_date)} of ${money(g.target_amount)}`
}
</script>

<template>
  <div class="space-y-4">
    <header class="flex items-baseline justify-between gap-3">
      <h1 class="u-display text-[34px]">Accounts</h1>
      <span
        v-if="!goalMode && total"
        class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase tabular-nums"
      >
        {{ fmtCount(total) }} in book
      </span>
    </header>

    <div class="space-y-2.5">
      <label class="block">
        <span class="sr-only">Search accounts</span>
        <input
          v-model="search"
          type="search"
          placeholder="Name, city, or customer #"
          autocapitalize="none"
          spellcheck="false"
          class="field"
        />
      </label>

      <!-- Filter chips, not checkboxes — thumb-sized, glove-proof. -->
      <div class="flex flex-wrap gap-2">
        <button
          type="button"
          class="tap-target font-label inline-flex items-center px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
          :class="
            activeOnly
              ? 'bg-ink text-canvas'
              : 'border-line-2 text-ink-2 border bg-transparent'
          "
          :aria-pressed="activeOnly"
          @click="activeOnly = !activeOnly"
        >
          Active only
        </button>
        <button
          type="button"
          class="tap-target font-label inline-flex items-center px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
          :class="
            goalMode
              ? 'bg-ink text-canvas'
              : 'border-line-2 text-ink-2 border bg-transparent'
          "
          :aria-pressed="goalMode"
          @click="goalMode = !goalMode"
        >
          Behind goal
        </button>
      </div>
    </div>

    <!-- ── Ranked by attainment ─────────────────────────────────────────── -->
    <AsyncState
      v-if="goalMode"
      :loading="behind.isPending.value"
      :error="behind.error.value"
      :empty="behindRows.length === 0"
      empty-title="No goals to rank"
      :empty-body="
        search
          ? 'No account with a goal matches that search.'
          : `Nothing in your book has a ${goalYear} goal yet. Open an account and set one on the Performance card.`
      "
      :rows="6"
      @retry="behind.refetch()"
    >
      <p class="text-muted text-sm">
        Every account with a {{ goalYear }} goal, furthest behind first.
      </p>

      <ul class="divide-line border-line bg-surface mt-2.5 divide-y border">
        <li v-for="g in behindRows" :key="g.customer_key">
          <RouterLink
            :to="{ name: 'account', params: { customerKey: g.customer_key } }"
            class="tap-target hover:bg-canvas flex flex-col justify-center gap-1 px-4 py-3.5"
          >
            <span class="flex items-baseline justify-between gap-3">
              <span class="flex min-w-0 items-baseline gap-1.5">
                <span class="text-ink truncate text-[17px] font-semibold">
                  {{ g.customer_name || g.customer_key }}
                </span>
                <span
                  v-if="g.customer_name"
                  class="text-muted shrink-0 text-[13px] font-medium"
                >
                  ({{ g.customer_key }})
                </span>
              </span>
              <span
                class="u-display shrink-0 text-lg tabular-nums"
                :class="g.on_track === false ? 'text-accent' : 'text-ink'"
              >
                {{ Math.round(g.attainment_pct) }}%
              </span>
            </span>

            <GoalProgressBar
              height="sm"
              :attainment-pct="g.attainment_pct"
              :expected-pct="g.expected_pct"
              :on-track="g.on_track"
              :label="`${g.customer_name || g.customer_key} goal progress`"
            />

            <span class="text-muted truncate text-sm">
              {{ goalAmounts(g) }}
              <template v-if="paceLabel(g)"> · {{ paceLabel(g) }}</template>
            </span>
          </RouterLink>
        </li>
      </ul>

      <p
        class="font-label text-muted mt-4 text-center text-xs font-semibold tracking-[0.12em] uppercase tabular-nums"
      >
        {{ fmtCount(behindRows.length) }} with a {{ goalYear }} goal
      </p>
    </AsyncState>

    <!-- ── The book ─────────────────────────────────────────────────────── -->
    <AsyncState
      v-else
      :loading="isPending"
      :error="error"
      :empty="rows.length === 0"
      :empty-title="search ? 'No matches' : 'No accounts assigned yet'"
      :empty-body="
        search
          ? 'Try a shorter search, or turn off the active-only filter.'
          : 'Your book comes from the ERP. If this is empty, ask your admin to check your rep code.'
      "
      :rows="6"
      @retry="refetch()"
    >
      <ul class="divide-line border-line bg-surface divide-y border">
        <li v-for="a in rows" :key="a.customer_key">
          <RouterLink
            :to="{ name: 'account', params: { customerKey: a.customer_key } }"
            class="tap-target hover:bg-canvas flex flex-col justify-center gap-1 px-4 py-3.5"
          >
            <span class="flex items-baseline justify-between gap-3">
              <!-- The ID is the disambiguator — a book has many "GUN SHOP"s.
                   It sits outside the truncating name span so a long name
                   clips itself rather than the one field that tells two
                   look-alike accounts apart. -->
              <span class="flex min-w-0 items-baseline gap-1.5">
                <span class="text-ink truncate text-[17px] font-semibold">
                  {{ a.customer_name || a.customer_key }}
                </span>
                <span
                  v-if="a.customer_name"
                  class="text-muted shrink-0 text-[13px] font-medium"
                >
                  ({{ a.customer_key }})
                </span>
              </span>
              <span
                v-if="a.active_flag !== 'Y'"
                class="border-line text-muted font-label shrink-0 border px-1.5 py-0.5 text-[11px] font-semibold tracking-[0.1em] uppercase"
              >
                Inactive
              </span>
            </span>
            <span class="text-muted truncate text-sm">
              <template v-if="place(a)">{{ place(a) }} · </template>
              Last order {{ daysAgo(a.last_order_date) }}
            </span>

            <!-- Goal, when the rep has set one. One quiet line: the number
                 they committed to and whether it is on track. -->
            <span
              v-if="goalFor(a.customer_key)"
              class="text-muted flex items-center gap-2 text-[13px]"
            >
              <GoalProgressBar
                height="sm"
                class="max-w-24 shrink-0"
                :attainment-pct="goalFor(a.customer_key)!.attainment_pct"
                :expected-pct="goalFor(a.customer_key)!.expected_pct"
                :on-track="goalFor(a.customer_key)!.on_track"
                :label="`${a.customer_name || a.customer_key} goal progress`"
              />
              <span
                class="truncate tabular-nums"
                :class="goalFor(a.customer_key)!.on_track === false ? 'text-accent font-semibold' : ''"
              >
                {{ Math.round(goalFor(a.customer_key)!.attainment_pct) }}% of
                {{ money(goalFor(a.customer_key)!.target_amount) }}
              </span>
            </span>
          </RouterLink>
        </li>
      </ul>

      <!-- Always says how much of the result set is on screen; a paged list
           that just stops is indistinguishable from a complete one. -->
      <div class="mt-4 text-center">
        <p class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase tabular-nums">
          Showing {{ fmtCount(rows.length) }} of {{ fmtCount(total) }}
        </p>
        <AppButton
          v-if="hasNextPage"
          variant="secondary"
          class="mt-2"
          :loading="isFetchingNextPage"
          @click="fetchNextPage()"
        >
          Load more
        </AppButton>
      </div>
    </AsyncState>
  </div>
</template>
