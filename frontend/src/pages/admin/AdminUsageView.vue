<script setup lang="ts">
/**
 * Usage — what the team looks at, and how often. Activity (the tab beside
 * this one) answers "did they open the portal"; this answers "and then
 * what": which screens, which accounts, on a phone or at a desk, by whom.
 *
 * Counted from usage_events (lib/usage.ts): one page view per screen, plus
 * downloads and "Who should I call?". Nothing is logged while an admin is
 * viewing as a rep. Admins' own use is left out unless asked for — the
 * question is how the field uses it.
 *
 * Pick a person (the dropdown, or tap their row) and every card narrows to
 * them, and the trail at the bottom becomes their last 200 steps.
 */
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import type { ColumnDef } from '@tanstack/vue-table'
import {
  isUsageReportMissing,
  useUsageReport,
  type UsageAccountRow,
  type UsageActionRow,
  type UsagePageRow,
  type UsageRecentRow,
  type UsageUserRow,
} from '@/composables/useUsageReport'
import DataGrid from '@/components/DataGrid.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { count, dayMonth, daysAgo, shortDate } from '@/lib/format'
import { pageLabel } from '@/lib/usage'
import type { ExportColumn } from '@/lib/xlsx'

const WINDOWS = [7, 30, 90] as const
const days = ref<number>(30)
const userId = ref('')
const includeAdmins = ref(false)

const query = useUsageReport(days, userId, includeAdmins)
const report = computed(() => query.data.value ?? null)
const missing = computed(() => isUsageReportMissing(query.error.value))

/* Route name → the nav's words. Read off the router so a renamed tab renames
   itself here; a page that no longer exists shows its stored name. */
const router = useRouter()
const titles = computed(() => {
  const map: Record<string, string> = {}
  for (const r of router.getRoutes()) {
    if (typeof r.name === 'string' && typeof r.meta.title === 'string') map[r.name] = r.meta.title
  }
  return map
})
const label = (page: string | null | undefined) => pageLabel(page, titles.value)

/* ---- the person filter --------------------------------------------------
   Options come from the unfiltered report and are kept while one person is
   picked (the filtered report lists only them). */
const everyone = ref<UsageUserRow[]>([])
const people = computed(() => {
  if (!userId.value && report.value) everyone.value = report.value.by_user
  return [...everyone.value].sort((a, b) => nameOf(a).localeCompare(nameOf(b)))
})
function nameOf(u: Pick<UsageUserRow, 'full_name' | 'email' | 'user_id'>) {
  return u.full_name || u.email || u.user_id
}
const pickedName = computed(() => {
  const u = everyone.value.find((x) => x.user_id === userId.value)
  return u ? nameOf(u) : ''
})

/* ---- headline ------------------------------------------------------------ */
const totals = computed(() => report.value?.totals ?? null)
const phoneShare = computed(() => {
  const t = totals.value
  return t && t.device_views > 0 ? `${Math.round((t.phone_views / t.device_views) * 100)}%` : '—'
})
const dash = '—'

/** Tracking began inside the window: say so, or a short history reads as low use. */
const startedInWindow = computed(() => {
  const r = report.value
  if (!r?.first_event_at) return null
  return r.first_event_at.slice(0, 10) > r.from ? r.first_event_at : null
})

/* ---- by day: one series (page views), bars on a zero baseline ------------ */
const dayRows = computed(() => report.value?.by_day ?? [])
const dayMax = computed(() => Math.max(1, ...dayRows.value.map((d) => d.views)))
/** Parsed as a local date: `new Date('2026-11-16')` is UTC and shows the 15th in Denver. */
const localDay = (iso: string) => new Date(`${iso}T12:00:00`)
const isWeekend = (iso: string) => [0, 6].includes(localDay(iso).getDay())
const dayExport: ExportColumn<{ day: string; views: number; users: number }>[] = [
  { key: 'day', header: 'Day', type: 'date' },
  { key: 'views', header: 'Page views', type: 'integer' },
  { key: 'users', header: 'People', type: 'integer' },
]

/* ---- grids --------------------------------------------------------------- */
const pct = (part: number, whole: number) => (whole > 0 ? `${Math.round((part / whole) * 100)}%` : '—')

const pageColumns: ColumnDef<UsagePageRow, any>[] = [
  { id: 'page', accessorFn: (r) => label(r.page), header: 'Page' },
  { id: 'views', accessorKey: 'views', header: 'Views' },
  { id: 'users', accessorKey: 'users', header: 'People' },
  { id: 'phone', accessorFn: (r) => (r.views ? r.phone_views / r.views : 0), header: 'On a phone' },
  { id: 'last_at', accessorKey: 'last_at', header: 'Last viewed' },
]
const pageExport: ExportColumn<UsagePageRow>[] = [
  { key: 'page', header: 'Page', format: (r) => label(r.page) },
  { key: 'views', header: 'Views', type: 'integer' },
  { key: 'users', header: 'People', type: 'integer' },
  { key: 'phone_views', header: 'Views on a phone', type: 'integer' },
  { key: 'last_at', header: 'Last viewed', type: 'datetime' },
]
const pageRows = computed(() => report.value?.by_page ?? [])
const visiblePages = ref<UsagePageRow[]>([])

const userColumns: ColumnDef<UsageUserRow, any>[] = [
  { id: 'full_name', accessorFn: (r) => nameOf(r), header: 'Person' },
  { id: 'rep_group', accessorFn: (r) => r.rep_group ?? '', header: 'Rep group' },
  { id: 'active_days', accessorKey: 'active_days', header: 'Days used' },
  { id: 'views', accessorKey: 'views', header: 'Page views' },
  { id: 'accounts', accessorKey: 'accounts', header: 'Accounts opened' },
  { id: 'exports', accessorKey: 'exports', header: 'Downloads' },
  { id: 'phone', accessorFn: (r) => (r.views ? r.phone_views / r.views : 0), header: 'On a phone' },
  { id: 'top_page', accessorFn: (r) => (r.top_page ? label(r.top_page) : ''), header: 'Most used' },
  { id: 'last_at', accessorKey: 'last_at', header: 'Last seen' },
]
const userExport: ExportColumn<UsageUserRow>[] = [
  { key: 'full_name', header: 'Person', format: (r) => nameOf(r) },
  { key: 'email', header: 'Email' },
  { key: 'role', header: 'Role' },
  { key: 'rep_group', header: 'Rep group', type: 'text' },
  { key: 'active_days', header: 'Days used', type: 'integer' },
  { key: 'views', header: 'Page views', type: 'integer' },
  { key: 'accounts', header: 'Accounts opened', type: 'integer' },
  { key: 'exports', header: 'Downloads', type: 'integer' },
  { key: 'phone_views', header: 'Views on a phone', type: 'integer' },
  { key: 'top_page', header: 'Most used page', format: (r) => (r.top_page ? label(r.top_page) : '') },
  { key: 'last_at', header: 'Last seen', type: 'datetime' },
]
const userRows = computed(() => report.value?.by_user ?? [])
const visibleUsers = ref<UsageUserRow[]>([])

const accountColumns: ColumnDef<UsageAccountRow, any>[] = [
  { id: 'customer', accessorFn: (r) => r.customer_name ?? r.customer_key, header: 'Account' },
  { id: 'views', accessorKey: 'views', header: 'Views' },
  { id: 'users', accessorKey: 'users', header: 'People' },
  { id: 'last_at', accessorKey: 'last_at', header: 'Last viewed' },
]
const accountExport: ExportColumn<UsageAccountRow>[] = [
  { key: 'customer_id', header: 'Customer ID', type: 'text' },
  { key: 'customer_name', header: 'Account' },
  { key: 'views', header: 'Views', type: 'integer' },
  { key: 'users', header: 'People', type: 'integer' },
  { key: 'last_at', header: 'Last viewed', type: 'datetime' },
]
const accountRows = computed(() => report.value?.by_account ?? [])
const visibleAccounts = ref<UsageAccountRow[]>([])

const ACTION_WORDS: Record<string, string> = {
  export: 'Downloaded',
  who_to_call: 'Who should I call?',
}
const actionWord = (event: string) => ACTION_WORDS[event] ?? event.replace(/_/g, ' ')
const actionRows = computed(() => report.value?.by_action ?? [])
const actionColumns: ColumnDef<UsageActionRow, any>[] = [
  { id: 'action', accessorFn: (r) => actionWord(r.event), header: 'Action' },
  { id: 'what', accessorKey: 'what', header: 'What' },
  { id: 'page', accessorFn: (r) => (r.page ? label(r.page) : ''), header: 'From' },
  { id: 'count', accessorKey: 'count', header: 'Times' },
  { id: 'users', accessorKey: 'users', header: 'People' },
  { id: 'last_at', accessorKey: 'last_at', header: 'Last' },
]

/* ---- the trail ----------------------------------------------------------- */
const TRAIL_STEP = 25
const trailLimit = ref(TRAIL_STEP)
const allRecent = computed(() => report.value?.recent ?? [])
const recent = computed(() => allRecent.value.slice(0, trailLimit.value))
function trailText(e: UsageRecentRow): string {
  if (e.event === 'page_view') return `Viewed ${label(e.page)}`
  const what = String(e.detail?.report ?? e.detail?.what ?? '')
  return `${actionWord(e.event)}${what ? ` · ${what}` : ''}`
}
const timeOf = (iso: string) =>
  new Date(iso).toLocaleString(undefined, { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })

/* ---- export context ------------------------------------------------------ */
const scope = computed(() => [
  `Last ${days.value} days${report.value ? ` (${shortDate(localDay(report.value.from))} – ${shortDate(localDay(report.value.through))})` : ''}`,
  pickedName.value ? `Person: ${pickedName.value}` : 'Everyone',
  includeAdmins.value ? 'Admins included' : 'Admins left out',
  startedInWindow.value && `Usage tracking began ${shortDate(startedInWindow.value)}: nothing is counted before then`,
])
const DESCRIPTION =
  'A page view is one screen opened in the portal (changing a filter on the same screen ' +
  'does not count again). Nothing is counted while an admin is viewing as a rep.'
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">Usage</p>
      <h1 class="u-display mt-1 text-4xl">What is the team looking at?</h1>
      <p class="text-muted mt-2 text-[15px]">
        Screens, accounts and downloads — by page and by person.
      </p>
    </header>

    <!-- One filter row for the whole page. -->
    <div class="flex flex-wrap items-center gap-2">
      <div class="border-line flex border" role="group" aria-label="Time window">
        <button
          v-for="w in WINDOWS"
          :key="w"
          type="button"
          class="tap-target font-label min-w-12 px-3 text-[13px] font-semibold tracking-[0.1em] uppercase"
          :class="days === w ? 'bg-ink text-canvas' : 'text-muted'"
          :aria-pressed="days === w"
          @click="days = w"
        >
          {{ w }}d
        </button>
      </div>
      <label class="min-w-0">
        <span class="sr-only">Person</span>
        <select v-model="userId" class="field max-w-64">
          <option value="">Everyone</option>
          <option v-for="p in people" :key="p.user_id" :value="p.user_id">{{ nameOf(p) }}</option>
        </select>
      </label>
      <label class="text-ink-2 tap-target inline-flex items-center gap-2 text-[15px]">
        <input v-model="includeAdmins" type="checkbox" class="h-4 w-4" />
        Include admins
      </label>
    </div>

    <AppCard v-if="missing" title="Usage">
      <p class="text-ink-2 text-[15px] leading-relaxed">
        Usage tracking is not in the database yet. Apply
        <code>supabase/migrations/20261116120000_usage_events.sql</code>, then reload.
      </p>
    </AppCard>

    <AsyncState
      v-else
      :loading="query.isPending.value"
      :error="query.error.value"
      :has-data="!!report"
      :updated-at="query.dataUpdatedAt.value"
      :rows="4"
      @retry="query.refetch()"
    >
      <div class="space-y-5" :class="query.isPlaceholderData.value ? 'opacity-60' : ''">
        <p v-if="startedInWindow" class="text-muted text-[13px]">
          Usage tracking began {{ shortDate(startedInWindow) }}. Nothing is counted before then.
        </p>

        <div class="bg-line border-line grid grid-cols-2 gap-px border md:grid-cols-4">
          <StatTile
            :label="userId ? 'Days used' : 'People'"
            :value="totals ? (userId ? count(userRows[0]?.active_days) : count(totals.users)) : dash"
            :sub="userId ? `of the last ${days}` : 'used the portal'"
          />
          <StatTile label="Page views" :value="totals ? count(totals.views) : dash" />
          <StatTile
            label="Accounts opened"
            :value="totals ? count(totals.accounts) : dash"
            sub="different accounts"
          />
          <StatTile label="On a phone" :value="phoneShare" sub="of page views" />
        </div>

        <!-- By day -->
        <AppCard>
          <template #header>
            <h2 class="u-label text-ink">Page views by day</h2>
            <ExportMenu
              :rows="dayRows"
              :columns="dayExport"
              title="Portal page views by day"
              filename="usage-by-day"
              :description="DESCRIPTION"
              :details="scope"
              sheet-name="By day"
            />
          </template>
          <p v-if="!totals?.views" class="text-muted py-6 text-center text-[15px]">
            No page views in this window yet.
          </p>
          <div v-else>
            <div
              class="border-line-2 flex h-36 items-end gap-[2px] border-b"
              role="img"
              :aria-label="`Page views per day, last ${days} days. Busiest day ${count(dayMax)}.`"
            >
              <div
                v-for="d in dayRows"
                :key="d.day"
                class="group relative flex h-full min-w-0 flex-1 items-end"
                :title="`${shortDate(localDay(d.day))}: ${count(d.views)} page views, ${count(d.users)} ${d.users === 1 ? 'person' : 'people'}`"
              >
                <div
                  class="w-full rounded-t-[3px] group-hover:opacity-70"
                  :class="isWeekend(d.day) ? 'bg-line-2' : 'bg-brand'"
                  :style="{ height: `${(d.views / dayMax) * 100}%`, minHeight: d.views ? '2px' : '0' }"
                />
              </div>
            </div>
            <div class="text-muted mt-1 flex justify-between text-xs tabular-nums">
              <span>{{ dayMonth(localDay(dayRows[0]!.day)) }}</span>
              <span>busiest day {{ count(dayMax) }} · weekends in grey</span>
              <span>{{ dayMonth(localDay(dayRows[dayRows.length - 1]!.day)) }}</span>
            </div>
          </div>
        </AppCard>

        <!-- By page -->
        <AppCard :padded="false">
          <template #header>
            <h2 class="u-label text-ink">By page</h2>
            <ExportMenu
              :rows="visiblePages"
              :columns="pageExport"
              title="Portal usage by page"
              filename="usage-by-page"
              :description="DESCRIPTION"
              :details="scope"
              sheet-name="By page"
            />
          </template>
          <DataGrid
            :columns="pageColumns"
            :data="pageRows"
            :initial-sorting="[{ id: 'views', desc: true }]"
            :get-row-id="(r: UsagePageRow) => r.page"
            min-width="36rem"
            class="p-3"
            @rows-change="visiblePages = $event"
          >
            <template #cell-page="{ row }">
              <span class="text-ink font-semibold">{{ label(row.page) }}</span>
            </template>
            <template #cell-views="{ row }">
              <div class="flex items-center gap-2">
                <span class="w-10 text-right tabular-nums">{{ count(row.views) }}</span>
                <span class="bg-line hidden h-2 w-24 sm:block" aria-hidden="true">
                  <span
                    class="bg-brand block h-full"
                    :style="{ width: `${(row.views / Math.max(1, pageRows[0]?.views ?? 1)) * 100}%` }"
                  />
                </span>
              </div>
            </template>
            <template #cell-users="{ row }">
              <span class="tabular-nums">{{ count(row.users) }}</span>
            </template>
            <template #cell-phone="{ row }">
              <span class="tabular-nums">{{ pct(row.phone_views, row.views) }}</span>
            </template>
            <template #cell-last_at="{ row }">
              <span class="whitespace-nowrap">{{ daysAgo(row.last_at) }}</span>
            </template>
            <template #card="{ row }">
              <div class="flex items-baseline justify-between gap-3">
                <p class="text-ink min-w-0 font-semibold">{{ label(row.page) }}</p>
                <p class="text-ink shrink-0 tabular-nums">{{ count(row.views) }} views</p>
              </div>
              <p class="text-muted mt-0.5 text-[13px]">
                {{ count(row.users) }} {{ row.users === 1 ? 'person' : 'people' }} ·
                {{ pct(row.phone_views, row.views) }} on a phone · last {{ daysAgo(row.last_at) }}
              </p>
            </template>
            <template #empty>
              <p class="text-muted py-10 text-center text-[15px]">No page views in this window yet.</p>
            </template>
          </DataGrid>
        </AppCard>

        <!-- By person -->
        <AppCard :padded="false">
          <template #header>
            <div class="min-w-0">
              <h2 class="u-label text-ink">By person</h2>
              <p class="text-muted mt-1 text-[13px]">Tap a name to see only their use.</p>
            </div>
            <ExportMenu
              :rows="visibleUsers"
              :columns="userExport"
              title="Portal usage by person"
              filename="usage-by-person"
              :description="DESCRIPTION"
              :details="scope"
              sheet-name="By person"
            />
          </template>
          <DataGrid
            :columns="userColumns"
            :data="userRows"
            :initial-sorting="[{ id: 'views', desc: true }]"
            searchable
            search-label="Search people"
            search-placeholder="Search people…"
            :get-row-id="(r: UsageUserRow) => r.user_id"
            min-width="60rem"
            class="p-3"
            @rows-change="visibleUsers = $event"
          >
            <template #cell-full_name="{ row }">
              <button
                type="button"
                class="text-ink text-left font-semibold underline decoration-dotted underline-offset-2"
                @click="userId = userId === row.user_id ? '' : row.user_id"
              >
                {{ nameOf(row) }}
              </button>
              <span v-if="row.role && row.role !== 'rep'" class="text-muted ml-1 text-[13px]">
                ({{ row.role === 'order_entry' ? 'inside sales' : row.role }})
              </span>
              <span v-if="!row.active" class="text-muted ml-1 text-[13px]">(inactive)</span>
            </template>
            <template #cell-rep_group="{ row }">
              <span class="text-ink-2">{{ row.rep_group || '—' }}</span>
            </template>
            <template #cell-active_days="{ row }">
              <span class="tabular-nums" :class="row.active_days ? '' : 'text-muted'">
                {{ count(row.active_days) }}
              </span>
            </template>
            <template #cell-views="{ row }">
              <span class="tabular-nums" :class="row.views ? '' : 'text-muted'">{{ count(row.views) }}</span>
            </template>
            <template #cell-accounts="{ row }">
              <span class="tabular-nums">{{ count(row.accounts) }}</span>
            </template>
            <template #cell-exports="{ row }">
              <span class="tabular-nums">{{ count(row.exports) }}</span>
            </template>
            <template #cell-phone="{ row }">
              <span class="tabular-nums">{{ pct(row.phone_views, row.views) }}</span>
            </template>
            <template #cell-top_page="{ row }">
              <span class="text-ink-2">{{ row.top_page ? label(row.top_page) : '—' }}</span>
            </template>
            <template #cell-last_at="{ row }">
              <span class="whitespace-nowrap">{{ row.last_at ? daysAgo(row.last_at) : 'no use' }}</span>
            </template>
            <template #card="{ row }">
              <div class="flex items-baseline justify-between gap-3">
                <button
                  type="button"
                  class="text-ink min-w-0 text-left font-semibold underline decoration-dotted underline-offset-2"
                  @click="userId = userId === row.user_id ? '' : row.user_id"
                >
                  {{ nameOf(row) }}
                </button>
                <p class="shrink-0 tabular-nums" :class="row.views ? 'text-ink' : 'text-muted'">
                  {{ count(row.views) }} views
                </p>
              </div>
              <p class="text-muted mt-0.5 text-[13px]">
                <template v-if="row.views">
                  {{ count(row.active_days) }} {{ row.active_days === 1 ? 'day' : 'days' }} ·
                  {{ count(row.accounts) }} accounts · mostly {{ label(row.top_page) }} ·
                  last {{ daysAgo(row.last_at) }}
                </template>
                <template v-else>No use in this window</template>
              </p>
            </template>
            <template #empty>
              <p class="text-muted py-10 text-center text-[15px]">Nobody matches that search.</p>
            </template>
          </DataGrid>
        </AppCard>

        <!-- Most-viewed accounts -->
        <AppCard :padded="false">
          <template #header>
            <div class="min-w-0">
              <h2 class="u-label text-ink">Accounts opened most</h2>
              <p class="text-muted mt-1 text-[13px]">Top 100 by views of the account page.</p>
            </div>
            <ExportMenu
              :rows="visibleAccounts"
              :columns="accountExport"
              title="Accounts opened most in the portal"
              filename="usage-by-account"
              :description="DESCRIPTION"
              :details="scope"
              sheet-name="By account"
            />
          </template>
          <DataGrid
            :columns="accountColumns"
            :data="accountRows"
            :initial-sorting="[{ id: 'views', desc: true }]"
            searchable
            search-label="Search accounts"
            search-placeholder="Search accounts…"
            :get-row-id="(r: UsageAccountRow) => r.customer_key"
            :render-limit="25"
            min-width="32rem"
            class="p-3"
            @rows-change="visibleAccounts = $event"
          >
            <template #cell-customer="{ row }">
              <RouterLink
                :to="{ name: 'account', params: { customerKey: row.customer_key } }"
                class="text-ink font-semibold underline underline-offset-2"
              >
                {{ row.customer_name ?? row.customer_key }}
              </RouterLink>
            </template>
            <template #cell-views="{ row }">
              <span class="tabular-nums">{{ count(row.views) }}</span>
            </template>
            <template #cell-users="{ row }">
              <span class="tabular-nums">{{ count(row.users) }}</span>
            </template>
            <template #cell-last_at="{ row }">
              <span class="whitespace-nowrap">{{ daysAgo(row.last_at) }}</span>
            </template>
            <template #card="{ row }">
              <div class="flex items-baseline justify-between gap-3">
                <RouterLink
                  :to="{ name: 'account', params: { customerKey: row.customer_key } }"
                  class="text-ink min-w-0 font-semibold underline underline-offset-2"
                >
                  {{ row.customer_name ?? row.customer_key }}
                </RouterLink>
                <p class="text-ink shrink-0 tabular-nums">{{ count(row.views) }} views</p>
              </div>
              <p class="text-muted mt-0.5 text-[13px]">
                {{ count(row.users) }} {{ row.users === 1 ? 'person' : 'people' }} · last
                {{ daysAgo(row.last_at) }}
              </p>
            </template>
            <template #empty>
              <p class="text-muted py-10 text-center text-[15px]">No account pages opened in this window.</p>
            </template>
          </DataGrid>
        </AppCard>

        <!-- Downloads and other actions -->
        <AppCard :padded="false">
          <template #header>
            <h2 class="u-label text-ink">Downloads and actions</h2>
          </template>
          <DataGrid
            :columns="actionColumns"
            :data="actionRows"
            :initial-sorting="[{ id: 'count', desc: true }]"
            :render-limit="25"
            min-width="40rem"
            class="p-3"
          >
            <template #cell-count="{ row }">
              <span class="tabular-nums">{{ count(row.count) }}</span>
            </template>
            <template #cell-users="{ row }">
              <span class="tabular-nums">{{ count(row.users) }}</span>
            </template>
            <template #cell-last_at="{ row }">
              <span class="whitespace-nowrap">{{ daysAgo(row.last_at) }}</span>
            </template>
            <template #card="{ row }">
              <div class="flex items-baseline justify-between gap-3">
                <p class="text-ink min-w-0 font-semibold">
                  {{ actionWord(row.event) }}<template v-if="row.what"> · {{ row.what }}</template>
                </p>
                <p class="text-ink shrink-0 tabular-nums">{{ count(row.count) }}×</p>
              </div>
              <p class="text-muted mt-0.5 text-[13px]">
                {{ count(row.users) }} {{ row.users === 1 ? 'person' : 'people' }} · last
                {{ daysAgo(row.last_at) }}
              </p>
            </template>
            <template #empty>
              <p class="text-muted py-10 text-center text-[15px]">No downloads in this window.</p>
            </template>
          </DataGrid>
        </AppCard>

        <!-- The trail -->
        <AppCard>
          <template #header>
            <h2 class="u-label text-ink">
              {{ pickedName ? `${pickedName}: latest steps` : 'Latest steps' }}
            </h2>
          </template>
          <p v-if="!recent.length" class="text-muted py-6 text-center text-[15px]">
            Nothing in this window yet.
          </p>
          <ul v-else class="space-y-3">
            <li v-for="e in recent" :key="e.id" class="flex gap-3">
              <span class="bg-line-2 w-0.5 shrink-0 self-stretch" aria-hidden="true" />
              <div class="min-w-0">
                <p class="text-ink text-[15px]">
                  <span v-if="!userId" class="font-semibold">{{ e.full_name ?? 'Someone' }} · </span>
                  {{ trailText(e) }}
                  <template v-if="e.customer_key">
                    ·
                    <RouterLink
                      :to="{ name: 'account', params: { customerKey: e.customer_key } }"
                      class="underline underline-offset-2"
                    >
                      {{ e.customer_name ?? e.customer_key }}
                    </RouterLink>
                  </template>
                </p>
                <p class="text-muted text-[13px]">
                  {{ timeOf(e.at) }}<template v-if="e.device"> · {{ e.device }}</template>
                </p>
              </div>
            </li>
          </ul>
          <button
            v-if="allRecent.length > trailLimit"
            type="button"
            class="btn-ghost mt-3 text-[13px]"
            @click="trailLimit += TRAIL_STEP"
          >
            Show {{ Math.min(TRAIL_STEP, allRecent.length - trailLimit) }} more
          </button>
        </AppCard>
      </div>
    </AsyncState>
  </div>
</template>
