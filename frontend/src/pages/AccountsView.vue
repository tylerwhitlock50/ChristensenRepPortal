<script setup lang="ts">
import { computed, ref, shallowRef, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { refDebounced, useMediaQuery } from '@vueuse/core'
import type { ColumnDef } from '@tanstack/vue-table'
import {
  isRankedSort,
  rankAccountRows,
  useAccountSearch,
  useAccountsByKeys,
  useAccountTable,
  type AccountListRow,
  type AccountSort,
  type AccountTableRow,
} from '@/composables/useAccounts'
import { observeAccount, useTerritoryAccounts } from '@/composables/useOverview'
import {
  accountFamilyDetail,
  accountSkuDetail,
  useBookSkuSales,
  type AccountFamilyDetailRow,
  type AccountIdentity,
  type AccountSkuDetailRow,
} from '@/composables/useIntel'
import { useTerritorySignals } from '@/composables/useAccountSignals'
import { useBestContacts, type AccountReach } from '@/composables/useBestContacts'
import { usePlan } from '@/composables/usePlan'
import {
  currentGoalYear,
  paceLabel,
  useAccountGoalsFor,
  useAccountsBehindGoal,
  type AccountGoalProgress,
} from '@/composables/useAccountGoals'
import AccountListCard from '@/components/AccountListCard.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import DataGrid from '@/components/DataGrid.vue'
import GoalProgressBar from '@/components/GoalProgressBar.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import type { ExportColumn } from '@/lib/xlsx'
import { count as fmtCount, humanize, money, shortDate } from '@/lib/format'
import { formatAddress, MAX_ROUTE_STOPS, multiStopRouteUrl } from '@/lib/maps'

const route = useRoute()
const router = useRouter()

const search = ref('')
// Every keystroke would otherwise be a round trip over LTE.
const debouncedSearch = refDebounced(search, 300)
const activeOnly = ref(true)

/* ---- sort chips ----------------------------------------------------------
   One list, five orders. A–Z is the whole book, paged and searched in
   Postgres. Biggest / Slipping / Longest since order rank the WHOLE book —
   sorting a page of 50 would silently rank only the 50 that loaded — so they
   read the table's whole-book rows (one cache with table mode) and filter
   the search in place. "Behind goal" is the goals ranked worst-first, which
   has to happen in Postgres too: only accounts with a goal have a row, so
   that list is small enough to hold whole.

   Deep-linkable: ?sort=biggest|slipping|quiet, and ?goal=behind as before
   (the Today page's book line points there).
------------------------------------------------------------------------- */
const SORT_CHIPS: { value: AccountSort; label: string }[] = [
  { value: 'az', label: 'A–Z' },
  { value: 'biggest', label: 'Biggest' },
  { value: 'slipping', label: 'Slipping' },
  { value: 'quiet', label: 'Longest since order' },
  { value: 'behind', label: 'Behind goal' },
]

function sortFromRoute(): AccountSort {
  if (route.query.goal === 'behind') return 'behind'
  const q = route.query.sort
  return q === 'biggest' || q === 'slipping' || q === 'quiet' ? q : 'az'
}

const sort = ref<AccountSort>(sortFromRoute())
const goalYear = currentGoalYear()

/** In table mode Behind goal is a filter chip, so it reads as a boolean too. */
const goalMode = computed({
  get: () => sort.value === 'behind',
  set: (on: boolean) => (sort.value = on ? 'behind' : 'az'),
})
const ranked = computed(() => isRankedSort(sort.value))

watch(sort, (s) => {
  void router.replace({
    query: {
      ...route.query,
      goal: s === 'behind' ? 'behind' : undefined,
      sort: isRankedSort(s) ? s : undefined,
    },
  })
})

/* ---- card / table toggle ------------------------------------------------
   Rep feedback: the book as a metric table — revenue and bookings YTD/prior,
   open orders, rep, goal. The table reads public.v_account_table, the whole
   book in one query, so every column sorts over ALL rows. It needs 72rem,
   so it is a wide-screen view: below sm the toggle is hidden and the page
   is cards whatever ?view says, which also means a ?view=table link opened
   on a phone lands somewhere usable instead of a sideways-scrolling grid.
------------------------------------------------------------------------- */
const view = ref<'cards' | 'table'>(route.query.view === 'table' ? 'table' : 'cards')
const wide = useMediaQuery('(min-width: 640px)')
const effectiveView = computed(() => (wide.value ? view.value : 'cards'))

watch(view, (v) => {
  void router.replace({
    query: { ...route.query, view: v === 'table' ? 'table' : undefined },
  })
})

/* ---- my plan --------------------------------------------------------------
   Starred accounts (usePlan: this device, this user), shown as their own
   list with one "Route these" link through their addresses.
------------------------------------------------------------------------- */
const {
  keys: planKeys,
  count: planCount,
  full: planFull,
  has: inPlan,
  toggle: togglePlan,
  clear: clearPlan,
} = usePlan()
const planMode = ref(route.query.plan === '1' && planCount.value > 0)
watch(planMode, (on) => {
  void router.replace({ query: { ...route.query, plan: on ? '1' : undefined } })
})
// An empty plan has nothing to show; the chip turns itself off.
watch(planCount, (n) => {
  if (n === 0) planMode.value = false
})

const tableQuery = useAccountTable(
  activeOnly,
  computed(() => effectiveView.value === 'table' || (ranked.value && !planMode.value)),
)

/** In table mode the Behind-goal chip is a filter, not a different list. */
const tableRows = computed(() => {
  const rows = tableQuery.data.value ?? []
  if (!goalMode.value) return rows
  return rows.filter((r) => r.goal_amount != null && r.on_track === false)
})

/** % of the prior year's same-days revenue — the rep's "% of PYTD" column. */
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
  // Invoiced revenue, never "ships": shipping runs ahead of invoicing, and
  // shipped value is its own figure (Sales Intel › Shipments). G10.
  { id: 'revenue_ytd', header: 'YTD revenue', accessorKey: 'revenue_ytd' },
  { id: 'revenue_prior_ytd', header: 'PYTD revenue', accessorKey: 'revenue_prior_ytd' },
  { id: 'revenue_prior_full', header: 'PY revenue', accessorKey: 'revenue_prior_full' },
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
/** The grid's search + Rep filter, in words (DataGrid filtersChange). */
const tableGridFilters = ref<string[]>([])
/* An empty result unmounts the grid and `tableVisible` keeps what it last
   emitted: nothing on screen then, so nothing to download. */
const tableExportRows = computed(() => (tableRows.value.length ? tableVisible.value : []))

/** A 0–100 whole percent → the fraction Excel's percent format wants. */
function pctFraction(value: number | null | undefined): number | null {
  return value == null || !Number.isFinite(value) ? null : value / 100
}

const tableExportColumns: ExportColumn<AccountTableRow>[] = [
  { key: 'customer_key', header: 'Customer key', type: 'text' },
  { key: 'customer_name', header: 'Account' },
  { key: 'sold_to_city', header: 'City' },
  { key: 'sold_to_state', header: 'State' },
  { key: 'assigned_sales_rep_name', header: 'Rep' },
  { key: 'revenue_ytd', header: 'YTD revenue', type: 'money' },
  { key: 'revenue_prior_ytd', header: 'PYTD revenue', type: 'money' },
  { key: 'revenue_prior_full', header: 'PY revenue', type: 'money' },
  { key: 'bookings_ytd', header: 'YTD orders', type: 'money' },
  { key: 'bookings_prior_ytd', header: 'PYTD orders', type: 'money' },
  { key: 'open_order_value', header: 'Open orders', type: 'money' },
  { key: 'open_order_count', header: 'Open order count', type: 'integer' },
  { key: 'goal_amount', header: 'Goal', type: 'money' },
  {
    key: 'attainment_pct',
    header: '% of goal',
    type: 'percent',
    format: (r) => pctFraction(r.attainment_pct),
  },
  // The screen shows behind-pace attainment in ember; the file says it.
  {
    key: 'on_track',
    header: 'On goal pace',
    format: (r) => (r.on_track == null ? null : r.on_track ? 'Yes' : 'No'),
  },
  {
    key: 'pct_of_pytd',
    header: '% of PYTD',
    type: 'percent',
    format: (r) => pctFraction(pctOfPytd(r)),
  },
  { key: 'last_order_date', header: 'Last order', type: 'date' },
]

const tableExportTitle = computed(() =>
  goalMode.value ? `Accounts behind goal — ${goalYear}` : 'Accounts — revenue and orders',
)
const tableExportFilename = computed(() =>
  goalMode.value ? `accounts-behind-goal-${goalYear}` : 'accounts',
)
const TABLE_EXPORT_DESCRIPTION =
  'Revenue is invoiced (shipped and billed); orders are bookings (placed). YTD is this year ' +
  'to date, PYTD the same days last year, PY all of last year. Internal customers are left out.'
const tableExportDetails = computed(() => [
  activeOnly.value
    ? 'Active accounts only (inactive and deactivated hidden)'
    : 'Includes inactive and deactivated accounts',
  goalMode.value && `Behind goal: accounts with a ${goalYear} goal that are behind pace`,
  ...tableGridFilters.value,
])

/* ---- download detail ------------------------------------------------------
   The same accounts, with what they bought underneath: one row per account
   and family, product line, or SKU. Flat rows on purpose — every row carries
   its account, rep and family, so Excel's filter arrows (and a PivotTable)
   drill account → family → SKU without the file having an opinion about it.

   The SKU rows are the whole book's, read once when a level is first picked
   (useBookSkuSales); the table's search, Rep filter and Behind goal then
   narrow them in memory, so the file always matches the accounts on screen.
   Two years only: this year to date and all of last year, the SKU pages'
   pairing. The rollup has no "same days last year" at SKU grain, so there is
   no PYTD column here to mistake for the table's.
------------------------------------------------------------------------- */
type DetailLevel = 'accounts' | 'family' | 'line' | 'sku'
const DETAIL_LEVELS: { value: DetailLevel; label: string }[] = [
  { value: 'accounts', label: 'Accounts only' },
  { value: 'family', label: 'By family' },
  { value: 'line', label: 'By product line' },
  { value: 'sku', label: 'By SKU' },
]
const detailLevel = ref<DetailLevel>('accounts')
const detailYear = new Date().getFullYear()

const bookSku = useBookSkuSales(
  computed(() => effectiveView.value === 'table' && detailLevel.value !== 'accounts'),
  detailYear - 1,
)
const detailReady = computed(() => bookSku.data.value !== undefined)

const skuDetailRows = computed<AccountSkuDetailRow[]>(() =>
  detailLevel.value === 'sku' && detailReady.value
    ? accountSkuDetail(tableExportRows.value, bookSku.data.value ?? [], detailYear)
    : [],
)
const familyDetailRows = computed<AccountFamilyDetailRow[]>(() =>
  (detailLevel.value === 'family' || detailLevel.value === 'line') && detailReady.value
    ? accountFamilyDetail(
        tableExportRows.value,
        bookSku.data.value ?? [],
        detailLevel.value,
        detailYear,
      )
    : [],
)

/** The account columns every detail row leads with. */
const DETAIL_ACCOUNT_COLUMNS: ExportColumn<AccountIdentity>[] = [
  { key: 'customer_key', header: 'Customer key', type: 'text' },
  { key: 'customer_name', header: 'Account' },
  { key: 'sold_to_city', header: 'City' },
  { key: 'sold_to_state', header: 'State' },
  { key: 'assigned_sales_rep_name', header: 'Rep' },
]
const skuDetailColumns: ExportColumn<AccountSkuDetailRow>[] = [
  ...DETAIL_ACCOUNT_COLUMNS,
  // The by-family file's own family names, so the two files add up alike.
  { key: 'family', header: 'Family' },
  { key: 'product_code', header: 'Product line' },
  { key: 'part_id', header: 'SKU', type: 'text' },
  { key: 'part_description', header: 'Description' },
  { key: 'chambering', header: 'Chambering' },
  { key: 'upc', header: 'UPC', type: 'text' },
  { key: 'qtyThisYear', header: `Units ${detailYear} to date`, type: 'number' },
  { key: 'revenueThisYear', header: `Revenue ${detailYear} to date`, type: 'money' },
  { key: 'qtyLastYear', header: `Units all of ${detailYear - 1}`, type: 'number' },
  { key: 'revenueLastYear', header: `Revenue all of ${detailYear - 1}`, type: 'money' },
  { key: 'lastInvoiceDate', header: 'Last invoice', type: 'date' },
]
const familyDetailColumns = computed<ExportColumn<AccountFamilyDetailRow>[]>(() => [
  ...DETAIL_ACCOUNT_COLUMNS,
  { key: 'key', header: detailLevel.value === 'line' ? 'Product line' : 'Family' },
  { key: 'skuCount', header: 'SKUs', type: 'integer' },
  { key: 'qtyThisYear', header: `Units ${detailYear} to date`, type: 'number' },
  { key: 'revenueThisYear', header: `Revenue ${detailYear} to date`, type: 'money' },
  // Of the ACCOUNT's revenue: each account's rows add up to 100%.
  { key: 'shareThisYear', header: `Share of account ${detailYear}`, type: 'percent' },
  { key: 'qtyLastYear', header: `Units all of ${detailYear - 1}`, type: 'number' },
  { key: 'revenueLastYear', header: `Revenue all of ${detailYear - 1}`, type: 'money' },
  { key: 'shareLastYear', header: `Share of account ${detailYear - 1}`, type: 'percent' },
  { key: 'lastInvoiceDate', header: 'Last invoice', type: 'date' },
])

const DETAIL_WORDS: Record<Exclude<DetailLevel, 'accounts'>, { noun: string; slug: string }> = {
  family: { noun: 'family', slug: 'by-family' },
  line: { noun: 'product line', slug: 'by-product-line' },
  sku: { noun: 'SKU', slug: 'by-sku' },
}
const detailWords = computed(() =>
  detailLevel.value === 'accounts' ? null : DETAIL_WORDS[detailLevel.value],
)
const detailExportTitle = computed(
  () =>
    `${goalMode.value ? `Accounts behind goal — ${goalYear}` : 'Accounts'} — sales by ${detailWords.value?.noun}`,
)
const detailExportFilename = computed(
  () => `${tableExportFilename.value}-${detailWords.value?.slug}`,
)
const DETAIL_EXPORT_DESCRIPTION =
  `Invoiced units and revenue. ${detailYear} is year to date; ${detailYear - 1} is the ` +
  'whole calendar year, not the same period. Internal customers are left out.'
const detailExportDetails = computed(() => [
  `One row per account and ${detailWords.value?.noun}, for the accounts in the table ` +
    `(${fmtCount(tableExportRows.value.length)}); an account with nothing invoiced in ` +
    `${detailYear - 1} or ${detailYear} has no rows`,
  detailLevel.value === 'line' && 'Product line is the ERP product code ("Family" in Tableau)',
  detailLevel.value === 'family' &&
    'Barreled actions, and components & accessories, are one family row each',
  ...tableExportDetails.value,
])

function pct(value: number | null | undefined): string {
  // The finite check matters: attainment against a zero-ish goal upstream
  // can arrive as Infinity, and "Infinity%" in a metric column reads as a
  // bug rather than "no basis".
  return value == null || !Number.isFinite(value) ? '—' : `${Math.round(value)}%`
}

const {
  data,
  dataUpdatedAt,
  isPending,
  fetchStatus,
  error,
  refetch,
  fetchNextPage,
  hasNextPage,
  isFetchingNextPage,
} = useAccountSearch(
  debouncedSearch,
  activeOnly,
  // Only the A–Z list is paged on the server. Every other mode filters its
  // own rows in place, and a keystroke must not cost round trips for a list
  // that isn't rendered.
  computed(
    () => effectiveView.value === 'cards' && sort.value === 'az' && !planMode.value,
  ),
)

const rows = computed(() => data.value?.pages.flatMap((p) => p.rows) ?? [])
/* No signal (or the offline open, where every read waits): a list or search
   that was never loaded is waiting, not loading — a skeleton for ever said
   nothing. AsyncState shows the offline line instead. */
const bookWaiting = computed(() => fetchStatus.value === 'paused' && data.value === undefined)
const total = computed(() => data.value?.pages[0]?.total ?? 0)

/**
 * Goals for the accounts currently on screen — one `.in()` over the visible
 * keys, not a query per row. Absent goals simply don't come back and the row
 * renders exactly as it did before.
 */
const { data: goals } = useAccountGoalsFor(
  computed(() =>
    sort.value !== 'az' || planMode.value || effectiveView.value === 'table'
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

/* ---- what each card says ------------------------------------------------
   This year's money and the one reason chip come from the territory rows
   the Overview already holds (v_territory_account_yoy: the only list with
   trailing-12-month and past-promise money, which the classifier needs) and
   the nightly signals, so a card says about an account exactly what the
   Overview's call list would. Both are whole-book reads shared with other
   pages; an account missing from them (inactive) just shows no money line.
------------------------------------------------------------------------- */
// Only the card lists that print money or a reason read them; the table and
// the goal-ranked list don't.
const decorated = computed(() => effectiveView.value === 'cards' && sort.value !== 'behind')
const territory = useTerritoryAccounts(decorated)
const signals = useTerritorySignals(decorated)
const territoryByKey = computed(
  () => new Map((territory.data.value ?? []).map((r) => [r.customer_key, r])),
)

function moneyFor(key: string) {
  const t = territoryByKey.value.get(key)
  return {
    revenueYtd: t ? t.revenue_ytd : null,
    revenuePriorYtd: t ? t.revenue_prior_ytd : null,
  }
}

function reasonFor(key: string): string | null {
  const t = territoryByKey.value.get(key)
  if (!t) return null
  return observeAccount(t, signals.data.value?.[key] ?? null)?.chip ?? null
}

function statusOf(a: {
  deactivated_at?: string | null
  active_flag?: string | null
}): 'deactivated' | 'inactive' | null {
  // The rep's own write-off outranks the ERP flag: an account can be both,
  // and "you deactivated this" is the label that explains why it's off the
  // default list.
  if (a.deactivated_at) return 'deactivated'
  if (a.active_flag != null && a.active_flag !== 'Y') return 'inactive'
  return null
}

function matchesSearch(a: {
  customer_key: string
  customer_name: string | null
  sold_to_city: string | null
}): boolean {
  const term = search.value.trim().toLowerCase()
  if (!term) return true
  return (
    (a.customer_name ?? '').toLowerCase().includes(term) ||
    a.customer_key.toLowerCase().includes(term) ||
    (a.sold_to_city ?? '').toLowerCase().includes(term)
  )
}

/* ---- ranked modes ----------------------------------------------------- */
const RANKED_PAGE = 50
const rankedShown = ref(RANKED_PAGE)
watch([sort, debouncedSearch, activeOnly], () => (rankedShown.value = RANKED_PAGE))

const rankedRows = computed(() => {
  const s = sort.value
  if (!isRankedSort(s)) return []
  return rankAccountRows((tableQuery.data.value ?? []).filter(matchesSearch), s)
})

const RANKED_CAPTION: Record<string, string> = {
  biggest: 'Most invoiced this year first.',
  slipping: 'Behind the same time last year, biggest dollar drop first.',
  quiet: 'Ordered in the last two years, longest since an order first.',
}
const RANKED_EMPTY: Record<string, string> = {
  biggest: 'No accounts to rank.',
  slipping: 'Nobody is behind the same time last year.',
  quiet: 'No account has ordered in the last two years.',
}

/* ---- plan list -------------------------------------------------------- */
const planAccounts = useAccountsByKeys(computed(() => (planMode.value ? planKeys.value : [])))
const planRows = computed(() => {
  const byKey = new Map((planAccounts.data.value ?? []).map((a) => [a.customer_key, a]))
  // Star order, which is the order the route drives them in.
  return planKeys.value
    .map((k) => byKey.get(k))
    .filter((a): a is AccountListRow => !!a && matchesSearch(a))
})

const planReach = useBestContacts(computed(() => (planMode.value ? planKeys.value : [])))
// Un-starring changes the key set and refetches; the last answer still
// covers every account left on the plan, so the Route button stays put
// instead of blinking out and back. A newly starred account is not in it,
// so nothing below shows until the fetch that includes it lands.
const lastReach = shallowRef(new Map<string, AccountReach>())
watch(
  () => planReach.data.value,
  (data) => {
    if (data !== undefined) lastReach.value = planReach.byKey.value
  },
)
const reachMap = computed(() =>
  planReach.data.value !== undefined ? planReach.byKey.value : lastReach.value,
)
const reachReady = computed(
  () => planKeys.value.length > 0 && planKeys.value.every((k) => reachMap.value.has(k)),
)
const routeStops = computed(() =>
  planKeys.value
    .map((k) => reachMap.value.get(k)?.address)
    .filter((a) => !!formatAddress(a)),
)
const routeUrl = computed(() => (reachReady.value ? multiStopRouteUrl(routeStops.value) : null))
const missingAddresses = computed(() =>
  reachReady.value ? planKeys.value.length - routeStops.value.length : 0,
)

/** One tap would lose the day's plan; ask first. */
function confirmClearPlan() {
  const n = planCount.value
  if (window.confirm(`Clear all ${n} starred ${n === 1 ? 'account' : 'accounts'} from your plan?`)) {
    clearPlan()
  }
}

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
        v-if="sort === 'az' && !planMode && effectiveView === 'cards' && total"
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

      <!-- Sort chips: one list, five orders (see the script). Cards only —
           the table sorts by its own column headers. -->
      <div
        v-if="effectiveView === 'cards' && !planMode"
        class="flex flex-wrap gap-2"
        role="radiogroup"
        aria-label="Sort accounts"
      >
        <button
          v-for="chip in SORT_CHIPS"
          :key="chip.value"
          type="button"
          role="radio"
          :aria-checked="sort === chip.value"
          class="tap-target font-label inline-flex items-center px-3.5 text-[13px] font-semibold tracking-[0.1em] uppercase"
          :class="
            sort === chip.value
              ? 'bg-ink text-canvas'
              : 'border-line-2 text-ink-2 border bg-transparent'
          "
          @click="sort = chip.value"
        >
          {{ chip.label }}
        </button>
      </div>

      <!-- Filter chips, not checkboxes — thumb-sized, glove-proof. -->
      <div class="flex flex-wrap gap-2">
        <!-- Not in My plan: a starred account is shown whatever its status. -->
        <button
          v-if="!planMode"
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
          v-if="planCount > 0 && effectiveView === 'cards'"
          type="button"
          class="tap-target font-label inline-flex items-center gap-1.5 px-4 text-[13px] font-semibold tracking-[0.1em] uppercase tabular-nums"
          :class="
            planMode
              ? 'bg-ink text-canvas'
              : 'border-line-2 text-ink-2 border bg-transparent'
          "
          :aria-pressed="planMode"
          @click="planMode = !planMode"
        >
          <span aria-hidden="true">★</span> My plan ({{ planCount }})
        </button>
        <!-- In the table, Behind goal filters the same rows instead. -->
        <button
          v-if="effectiveView === 'table'"
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

        <!-- Cards or columns, from sm up. The table needs 72rem; on a phone
             the page is cards whatever ?view says (see the script). -->
        <div
          class="border-line ml-auto hidden border sm:flex"
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
      v-if="effectiveView === 'table'"
      :loading="tableQuery.isPending.value"
      :error="tableQuery.error.value"
      :has-data="tableQuery.data.value !== undefined"
      :updated-at="tableQuery.dataUpdatedAt.value"
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
      <div class="mb-2 flex flex-wrap items-center justify-between gap-x-3 gap-y-2">
        <p class="text-muted text-sm">
          <template v-if="goalMode">
            Accounts with a {{ goalYear }} goal that are behind pace.
          </template>
          <template v-else>Revenue is invoiced; orders are bookings.</template>
        </p>
        <div class="ml-auto flex shrink-0 items-center gap-2">
          <!-- What the file holds under each account (see "download detail"
               in the script). The SKU rows load when a level is first
               picked, and the button waits for them. -->
          <span
            v-if="detailLevel !== 'accounts' && bookSku.error.value"
            role="alert"
            class="text-accent text-sm"
          >
            Couldn't load the sales detail.
            <button type="button" class="underline" @click="bookSku.refetch()">Retry</button>
          </span>
          <span
            v-else-if="detailLevel !== 'accounts' && !detailReady"
            role="status"
            class="text-muted text-sm"
          >
            Loading sales detail…
          </span>
          <label class="flex items-center gap-2">
            <span
              class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase"
            >
              Detail
            </span>
            <select v-model="detailLevel" class="field w-auto">
              <option v-for="l in DETAIL_LEVELS" :key="l.value" :value="l.value">
                {{ l.label }}
              </option>
            </select>
          </label>
          <!-- Disabled while "Active only" is refetching: keepPreviousData
               keeps the old list on screen, and the file would carry it under
               the new toggle's label. One menu per row shape, so each keeps
               its own column types. -->
          <ExportMenu
            v-if="detailLevel === 'accounts'"
            :rows="tableExportRows"
            :disabled="tableQuery.isPlaceholderData.value"
            :columns="tableExportColumns"
            :title="tableExportTitle"
            :filename="tableExportFilename"
            :description="TABLE_EXPORT_DESCRIPTION"
            :details="tableExportDetails"
            sheet-name="Accounts"
          />
          <ExportMenu
            v-else-if="detailLevel === 'sku'"
            :rows="skuDetailRows"
            :disabled="tableQuery.isPlaceholderData.value || !detailReady"
            :columns="skuDetailColumns"
            :title="detailExportTitle"
            :filename="detailExportFilename"
            :description="DETAIL_EXPORT_DESCRIPTION"
            :details="detailExportDetails"
            sheet-name="Accounts by SKU"
          />
          <ExportMenu
            v-else
            :rows="familyDetailRows"
            :disabled="tableQuery.isPlaceholderData.value || !detailReady"
            :columns="familyDetailColumns"
            :title="detailExportTitle"
            :filename="detailExportFilename"
            :description="DETAIL_EXPORT_DESCRIPTION"
            :details="detailExportDetails"
            :sheet-name="detailLevel === 'line' ? 'Accounts by product line' : 'Accounts by family'"
          />
        </div>
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
          @filters-change="tableGridFilters = $event"
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

    <!-- ── My plan ─────────────────────────────────────────────────────────
         The starred accounts, in star order, and one link that drives them
         in that order. -->
    <section v-else-if="planMode" aria-label="My plan" class="space-y-2.5">
      <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1">
        <p class="text-muted text-sm">Starred on this phone, in the order you starred them.</p>
        <AppButton variant="ghost" @click="confirmClearPlan">Clear plan</AppButton>
      </div>

      <template v-if="routeUrl">
        <a
          :href="routeUrl"
          target="_blank"
          rel="noopener"
          class="btn-primary w-full gap-2 tabular-nums"
        >
          <template v-if="routeStops.length > MAX_ROUTE_STOPS">
            Route the first {{ MAX_ROUTE_STOPS }}
          </template>
          <template v-else>
            Route {{ routeStops.length === 1 ? 'this stop' : `these ${routeStops.length}` }}
          </template>
        </a>
        <p class="text-muted text-[13px] leading-snug">
          Opens Google Maps, starting from where you are.
          <template v-if="routeStops.length > 4">
            A phone browser shows the first 4 stops; the Maps app shows them all.
          </template>
          <template v-if="missingAddresses > 0">
            {{ missingAddresses }} {{ missingAddresses === 1 ? 'account has' : 'accounts have' }}
            no street address on file and {{ missingAddresses === 1 ? 'is' : 'are' }} left out.
          </template>
        </p>
      </template>
      <p v-else-if="reachReady" class="text-muted text-[13px]">
        None of these has a street address on file to route to.
      </p>

      <AsyncState
        :loading="planAccounts.isPending.value"
        :error="planAccounts.error.value"
        :has-data="planAccounts.data.value !== undefined"
        :updated-at="planAccounts.dataUpdatedAt.value"
        :empty="planRows.length === 0"
        empty-title="Nothing here"
        :empty-body="
          search
            ? 'No starred account matches that search.'
            : 'Starred accounts that have left your book drop off this list.'
        "
        :rows="3"
        @retry="planAccounts.refetch()"
      >
        <ul class="divide-line border-line bg-surface divide-y border">
          <AccountListCard
            v-for="a in planRows"
            :key="a.customer_key"
            :customer-key="a.customer_key"
            :name="a.customer_name"
            :place="place(a)"
            :last-order-date="a.last_order_date"
            :status="statusOf(a)"
            v-bind="moneyFor(a.customer_key)"
            :reason="reasonFor(a.customer_key)"
            :starred="inPlan(a.customer_key)"
            @toggle-star="togglePlan(a.customer_key)"
          />
        </ul>
      </AsyncState>
    </section>

    <!-- ── Ranked: Biggest / Slipping / Longest since order ─────────────── -->
    <AsyncState
      v-else-if="ranked"
      :loading="tableQuery.isPending.value"
      :error="tableQuery.error.value"
      :has-data="tableQuery.data.value !== undefined"
      :updated-at="tableQuery.dataUpdatedAt.value"
      :empty="rankedRows.length === 0"
      :empty-title="search ? 'No matches' : 'Nothing to show'"
      :empty-body="
        search
          ? 'Try a shorter search, or turn off the active-only filter.'
          : RANKED_EMPTY[sort]
      "
      :rows="6"
      @retry="tableQuery.refetch()"
    >
      <p class="text-muted text-sm">{{ RANKED_CAPTION[sort] }}</p>

      <ul class="divide-line border-line bg-surface mt-2.5 divide-y border">
        <AccountListCard
          v-for="a in rankedRows.slice(0, rankedShown)"
          :key="a.customer_key"
          :customer-key="a.customer_key"
          :name="a.customer_name"
          :place="place(a)"
          :last-order-date="a.last_order_date"
          :status="statusOf(a)"
          :revenue-ytd="a.revenue_ytd"
          :revenue-prior-ytd="a.revenue_prior_ytd"
          :reason="reasonFor(a.customer_key)"
          :starred="inPlan(a.customer_key)"
          :star-disabled="planFull"
          @toggle-star="togglePlan(a.customer_key)"
        />
      </ul>

      <div class="mt-4 text-center">
        <p class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase tabular-nums">
          Showing {{ fmtCount(Math.min(rankedShown, rankedRows.length)) }} of
          {{ fmtCount(rankedRows.length) }}
        </p>
        <AppButton
          v-if="rankedShown < rankedRows.length"
          variant="secondary"
          class="mt-2"
          @click="rankedShown += RANKED_PAGE"
        >
          Show more
        </AppButton>
      </div>
    </AsyncState>

    <!-- ── Ranked by attainment ─────────────────────────────────────────── -->
    <AsyncState
      v-else-if="goalMode"
      :loading="behind.isPending.value"
      :error="behind.error.value"
      :has-data="behind.data.value !== undefined"
      :updated-at="behind.dataUpdatedAt.value"
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
        <AccountListCard
          v-for="g in behindRows"
          :key="g.customer_key"
          :customer-key="g.customer_key"
          :name="g.customer_name"
          :place="place(g)"
          :starred="inPlan(g.customer_key)"
          :star-disabled="planFull"
          @toggle-star="togglePlan(g.customer_key)"
        >
          <GoalProgressBar
            height="sm"
            :attainment-pct="g.attainment_pct"
            :expected-pct="g.expected_pct"
            :on-track="g.on_track"
            :label="`${g.customer_name || g.customer_key} goal progress`"
          />
          <span class="text-muted truncate text-sm">
            <span
              class="font-semibold tabular-nums"
              :class="g.on_track === false ? 'text-accent' : 'text-ink'"
            >
              {{ Math.round(g.attainment_pct) }}%
            </span>
            · {{ goalAmounts(g) }}
            <template v-if="paceLabel(g)"> · {{ paceLabel(g) }}</template>
          </span>
        </AccountListCard>
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
      :loading="isPending && !bookWaiting"
      :error="error"
      :has-data="data !== undefined"
      :updated-at="dataUpdatedAt"
      :empty="rows.length === 0"
      :empty-title="bookWaiting ? 'You\'re offline' : search ? 'No matches' : 'No accounts assigned yet'"
      :empty-body="
        bookWaiting
          ? 'This list needs a signal to load. Accounts you opened recently are in the search at the top.'
          : search
            ? 'Try a shorter search, or turn off the active-only filter.'
            : 'Your book comes from the ERP. If this is empty, ask your admin to check your rep code.'
      "
      :rows="6"
      @retry="refetch()"
    >
      <ul class="divide-line border-line bg-surface divide-y border">
        <AccountListCard
          v-for="a in rows"
          :key="a.customer_key"
          :customer-key="a.customer_key"
          :name="a.customer_name"
          :place="place(a)"
          :last-order-date="a.last_order_date"
          :status="statusOf(a)"
          v-bind="moneyFor(a.customer_key)"
          :reason="reasonFor(a.customer_key)"
          :starred="inPlan(a.customer_key)"
          :star-disabled="planFull"
          @toggle-star="togglePlan(a.customer_key)"
        >
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
        </AccountListCard>
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
