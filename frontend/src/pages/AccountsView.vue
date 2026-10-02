<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { refDebounced } from '@vueuse/core'
import type { ColumnDef } from '@tanstack/vue-table'
import {
  useAccountSearch,
  useAccountTable,
  type AccountTableRow,
} from '@/composables/useAccounts'
import {
  currentGoalYear,
  paceLabel,
  useAccountGoalsFor,
  useAccountsBehindGoal,
  type AccountGoalProgress,
} from '@/composables/useAccountGoals'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import DataGrid from '@/components/DataGrid.vue'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import { exportCsv, type CsvColumn } from '@/lib/csv'
import { count as fmtCount, daysAgo, humanize, money, shortDate } from '@/lib/format'

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

/* ---- card / table toggle ------------------------------------------------
   Rep feedback: the book as a metric table — ships and bookings YTD/prior,
   open orders, rep, goal. Cards stay the phone experience (the toggle is
   hidden below sm); the table reads public.v_account_table, the whole book
   in one query, so every column sorts over ALL rows rather than the 50
   that happened to be loaded. Deep-linkable as ?view=table, same pattern
   as ?goal=behind above.
------------------------------------------------------------------------- */
const view = ref<'cards' | 'table'>(route.query.view === 'table' ? 'table' : 'cards')

watch(view, (v) => {
  void router.replace({
    query: { ...route.query, view: v === 'table' ? 'table' : undefined },
  })
})

const tableQuery = useAccountTable(
  activeOnly,
  computed(() => view.value === 'table'),
)

/** In table mode the Behind-goal chip is a filter, not a different list. */
const tableRows = computed(() => {
  const rows = tableQuery.data.value ?? []
  if (!goalMode.value) return rows
  return rows.filter((r) => r.goal_amount != null && r.on_track === false)
})

/** % of the prior year's same-days ships — the rep's "% of PYTD" column. */
function pctOfPytd(r: AccountTableRow): number | null {
  if (!r.revenue_prior_ytd) return null
  return (r.revenue_ytd / r.revenue_prior_ytd) * 100
}

const tableColumns: ColumnDef<AccountTableRow, any>[] = [
  {
    id: 'account',
    header: 'Account',
    // Name + key so the global search box sees both.
    accessorFn: (r) => `${r.customer_name ?? ''} ${r.customer_key}`.trim(),
  },
  {
    id: 'assigned_sales_rep_name',
    header: 'Rep',
    accessorKey: 'assigned_sales_rep_name',
    meta: { filter: 'select' },
  },
  { id: 'revenue_ytd', header: 'YTD ships', accessorKey: 'revenue_ytd' },
  { id: 'revenue_prior_ytd', header: 'PYTD ships', accessorKey: 'revenue_prior_ytd' },
  { id: 'revenue_prior_full', header: 'PY ships', accessorKey: 'revenue_prior_full' },
  { id: 'bookings_ytd', header: 'YTD orders', accessorKey: 'bookings_ytd' },
  {
    id: 'bookings_prior_ytd',
    header: 'PYTD orders',
    accessorKey: 'bookings_prior_ytd',
  },
  { id: 'open_order_value', header: 'Open orders', accessorKey: 'open_order_value' },
  { id: 'goal_amount', header: 'Goal', accessorKey: 'goal_amount' },
  { id: 'attainment_pct', header: '% of goal', accessorKey: 'attainment_pct' },
  { id: 'pct_of_pytd', header: '% of PYTD', accessorFn: (r) => pctOfPytd(r) },
  { id: 'last_order_date', header: 'Last order', accessorKey: 'last_order_date' },
]

const tableVisible = ref<AccountTableRow[]>([])
const tableCsvColumns: CsvColumn<AccountTableRow>[] = [
  { key: 'customer_key', header: 'Customer key' },
  { key: 'customer_name', header: 'Account' },
  { key: 'sold_to_city', header: 'City' },
  { key: 'sold_to_state', header: 'State' },
  { key: 'assigned_sales_rep_name', header: 'Rep' },
  { key: 'revenue_ytd', header: 'YTD ships' },
  { key: 'revenue_prior_ytd', header: 'PYTD ships' },
  { key: 'revenue_prior_full', header: 'PY ships' },
  { key: 'bookings_ytd', header: 'YTD orders' },
  { key: 'bookings_prior_ytd', header: 'PYTD orders' },
  { key: 'open_order_value', header: 'Open order value' },
  { key: 'open_order_count', header: 'Open order count' },
  { key: 'goal_amount', header: 'Goal' },
  { key: 'attainment_pct', header: '% of goal' },
  { key: 'last_order_date', header: 'Last order' },
]

function pct(value: number | null | undefined): string {
  // The finite check matters: attainment against a zero-ish goal upstream
  // can arrive as Infinity, and "Infinity%" in a metric column reads as a
  // bug rather than "no basis".
  return value == null || !Number.isFinite(value) ? '—' : `${Math.round(value)}%`
}

const {
  data,
  isPending,
  error,
  refetch,
  fetchNextPage,
  hasNextPage,
  isFetchingNextPage,
} = useAccountSearch(
  debouncedSearch,
  activeOnly,
  // Table mode filters client-side over the whole book — the paged server
  // search would fire per keystroke for a list that isn't rendered.
  computed(() => view.value !== 'table'),
)

const rows = computed(() => data.value?.pages.flatMap((p) => p.rows) ?? [])
const total = computed(() => data.value?.pages[0]?.total ?? 0)

/**
 * Goals for the accounts currently on screen — one `.in()` over the visible
 * keys, not a query per row. Absent goals simply don't come back and the row
 * renders exactly as it did before.
 */
const { data: goals } = useAccountGoalsFor(
  computed(() =>
    goalMode.value || view.value === 'table'
      ? []
      : rows.value.map((r) => r.customer_key),
  ),
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
      <!-- Card-mode only: the table filters internal customers out, so its
           count is a different denominator — showing both would read as a
           discrepancy. The table has its own footer count. -->
      <span
        v-if="!goalMode && view === 'cards' && total"
        class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase tabular-nums"
      >
        {{ fmtCount(total) }} in book
      </span>
    </header>
    <p class="text-muted text-sm">
      Looking for shipment history? Select an account, then choose Shipment history
      to see packlists and tracking.
    </p>

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

        <!-- Cards or columns. Visible on phones too — ?view=table deep links
             land there, and without the toggle a phone would have no way
             back to cards. The table itself scrolls inside its own box. -->
        <div
          class="border-line ml-auto flex border"
          role="group"
          aria-label="Layout"
        >
          <button
            type="button"
            class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
            :class="view === 'cards' ? 'bg-ink text-canvas' : 'text-muted'"
            @click="view = 'cards'"
          >
            Cards
          </button>
          <button
            type="button"
            class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
            :class="view === 'table' ? 'bg-ink text-canvas' : 'text-muted'"
            @click="view = 'table'"
          >
            Table
          </button>
        </div>
      </div>
    </div>

    <!-- ── The table ────────────────────────────────────────────────────────
         The whole book with the metric columns, every one sortable over ALL
         rows. Behind-goal here is a filter on the same table, not the
         ranked list — that list is the cards experience. -->
    <AsyncState
      v-if="view === 'table'"
      :loading="tableQuery.isPending.value"
      :error="tableQuery.error.value"
      :empty="!tableQuery.isPending.value && tableRows.length === 0"
      :empty-title="goalMode ? 'Nothing behind goal' : 'No accounts'"
      :empty-body="
        goalMode
          ? 'No account with a goal is behind pace right now.'
          : 'Your book comes from the ERP. If this is empty, ask your admin to check your rep code.'
      "
      :rows="6"
      @retry="tableQuery.refetch()"
    >
      <div class="mb-2 flex items-center justify-between gap-3">
        <p class="text-muted text-sm">
          <template v-if="goalMode">
            Accounts with a {{ goalYear }} goal that are behind pace.
          </template>
          <template v-else>Ships are invoiced revenue; orders are bookings.</template>
        </p>
        <AppButton
          variant="ghost"
          :disabled="tableVisible.length === 0"
          @click="exportCsv('accounts', tableVisible, tableCsvColumns)"
        >
          Export CSV
        </AppButton>
      </div>

      <div class="border-line bg-surface border p-3">
        <DataGrid
          :columns="tableColumns"
          :data="tableRows"
          :initial-sorting="[{ id: 'revenue_ytd', desc: true }]"
          :global-filter="debouncedSearch"
          :get-row-id="(r: AccountTableRow) => r.customer_key"
          min-width="72rem"
          @rows-change="tableVisible = $event"
        >
          <template #cell-account="{ row }">
            <RouterLink
              :to="{ name: 'account', params: { customerKey: row.customer_key } }"
              class="text-ink block font-semibold underline-offset-2 hover:underline"
            >
              {{ row.customer_name || row.customer_key }}
            </RouterLink>
            <span class="text-muted block text-xs">
              {{ row.customer_key
              }}<template v-if="place(row)"> · {{ place(row) }}</template>
            </span>
          </template>
          <template #cell-revenue_ytd="{ row }">
            <span class="tabular-nums">{{ money(row.revenue_ytd) }}</span>
          </template>
          <template #cell-revenue_prior_ytd="{ row }">
            <span class="tabular-nums">{{ money(row.revenue_prior_ytd) }}</span>
          </template>
          <template #cell-revenue_prior_full="{ row }">
            <span class="tabular-nums">{{ money(row.revenue_prior_full) }}</span>
          </template>
          <template #cell-bookings_ytd="{ row }">
            <span class="tabular-nums">{{ money(row.bookings_ytd) }}</span>
          </template>
          <template #cell-bookings_prior_ytd="{ row }">
            <span class="tabular-nums">{{ money(row.bookings_prior_ytd) }}</span>
          </template>
          <template #cell-open_order_value="{ row }">
            <span class="tabular-nums">{{ money(row.open_order_value) }}</span>
            <span v-if="row.open_order_count" class="text-muted block text-xs tabular-nums">
              {{ fmtCount(row.open_order_count) }} orders
            </span>
          </template>
          <template #cell-goal_amount="{ row }">
            <span class="tabular-nums">
              {{ row.goal_amount == null ? '—' : money(row.goal_amount) }}
            </span>
          </template>
          <template #cell-attainment_pct="{ row }">
            <span
              class="tabular-nums"
              :class="row.on_track === false ? 'text-accent font-semibold' : ''"
            >
              {{ pct(row.attainment_pct) }}
            </span>
          </template>
          <template #cell-pct_of_pytd="{ row }">
            <span class="tabular-nums">{{ pct(pctOfPytd(row)) }}</span>
          </template>
          <template #cell-last_order_date="{ row }">
            <span class="whitespace-nowrap tabular-nums">
              {{ shortDate(row.last_order_date) }}
            </span>
          </template>
        </DataGrid>
      </div>

      <p
        class="font-label text-muted mt-4 text-center text-xs font-semibold tracking-[0.12em] uppercase tabular-nums"
      >
        {{ fmtCount(tableVisible.length) }} of {{ fmtCount(tableRows.length) }} shown
      </p>
    </AsyncState>

    <!-- ── Ranked by attainment ─────────────────────────────────────────── -->
    <AsyncState
      v-else-if="goalMode"
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
              <!-- The rep's own write-off outranks the ERP flag: an account
                   can be both, and "you deactivated this" is the label that
                   explains why it's off the default list. -->
              <span
                v-if="a.deactivated_at"
                class="border-line text-muted font-label shrink-0 border px-1.5 py-0.5 text-[11px] font-semibold tracking-[0.1em] uppercase"
              >
                Deactivated
              </span>
              <span
                v-else-if="a.active_flag !== 'Y'"
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
