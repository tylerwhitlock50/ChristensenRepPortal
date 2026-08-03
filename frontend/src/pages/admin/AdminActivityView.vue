<script setup lang="ts">
/**
 * Activity by rep group (vendor) and by rep — is the field actually working
 * the portal? The rollup is grouped client-side from v_rep_activity (tens of
 * rows); the raw stream underneath answers "what happened this week."
 */
import { computed, ref } from 'vue'
import type { ColumnDef, Row } from '@tanstack/vue-table'
import {
  rollupByVendor,
  useRecentActions,
  useRecentLogins,
  useRepActivity,
  type RepActivity,
} from '@/composables/useActivity'
import { useProfiles } from '@/composables/useAdminUsers'
import { useAccountNames } from '@/composables/useAccounts'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { ACTION_LABELS, type ActionType } from '@/types/domain'
import { count, daysAgo, shortDate } from '@/lib/format'
import { exportCsv, type CsvColumn } from '@/lib/csv'

const activity = useRepActivity()
const rows = computed(() => activity.data.value ?? [])

/* ---- headline ----------------------------------------------------------- */
const activeLast30 = computed(
  () =>
    rows.value.filter(
      (r) =>
        r.last_login_at &&
        Date.now() - new Date(r.last_login_at).getTime() < 30 * 86_400_000,
    ).length,
)
const totalOverdue = computed(() =>
  rows.value.reduce((n, r) => n + (r.overdue_missions ?? 0), 0),
)
const tilesReady = computed(() => !activity.error.value && !activity.isPending.value)
const dash = '—'

/* ---- vendor rollup ------------------------------------------------------ */
const rollups = computed(() => rollupByVendor(rows.value))

/* ---- per-rep grid ------------------------------------------------------- */
const vendorFilter = ref('')
const vendorOptions = computed(() => rollups.value.map((r) => r.vendorId))
const filteredRows = computed(() =>
  vendorFilter.value
    ? rows.value.filter((r) => (r.vendor_id ?? '(no rep group)') === vendorFilter.value)
    : rows.value,
)
const visibleRows = ref<RepActivity[]>([])

function byDateNullsFirst(a: Row<RepActivity>, b: Row<RepActivity>, columnId: string) {
  const av = a.getValue<string | null>(columnId)
  const bv = b.getValue<string | null>(columnId)
  if (av === bv) return 0
  if (!av) return -1
  if (!bv) return 1
  return av < bv ? -1 : 1
}

const columns: ColumnDef<RepActivity, any>[] = [
  { id: 'full_name', accessorFn: (r) => r.full_name ?? '', header: 'Rep' },
  { id: 'vendor_id', accessorFn: (r) => r.vendor_id ?? '', header: 'Rep group' },
  { id: 'last_login_at', accessorKey: 'last_login_at', header: 'Last login', sortingFn: byDateNullsFirst },
  { id: 'logins_30d', accessorFn: (r) => r.logins_30d ?? 0, header: 'Logins 30d' },
  { id: 'actions_30d', accessorFn: (r) => r.actions_30d ?? 0, header: 'Actions 30d' },
  { id: 'open_missions', accessorFn: (r) => r.open_missions ?? 0, header: 'Open missions' },
  { id: 'overdue_missions', accessorFn: (r) => r.overdue_missions ?? 0, header: 'Overdue' },
]

function onExport() {
  const csvColumns: CsvColumn<RepActivity>[] = [
    { key: 'full_name', header: 'Rep' },
    { key: 'email', header: 'Email' },
    { key: 'vendor_id', header: 'Rep Group (Vendor)' },
    { key: 'sales_rep_key', header: 'Rep Code' },
    { key: 'last_login_at', header: 'Last Login' },
    { key: 'logins_30d', header: 'Logins Last 30 Days' },
    { key: 'actions_30d', header: 'Actions Last 30 Days' },
    { key: 'last_action_date', header: 'Last Action Date' },
    { key: 'open_missions', header: 'Open Missions' },
    { key: 'overdue_missions', header: 'Overdue Missions' },
    { key: 'active', header: 'Active', format: (row) => (row.active ? 'Yes' : 'No') },
  ]
  exportCsv('rep-activity', visibleRows.value, csvColumns)
}

/* ---- recent stream ------------------------------------------------------ */
const WINDOWS = [7, 30, 90] as const
const window = ref<number>(7)
const logins = useRecentLogins(window)
const actions = useRecentActions(window)

const profiles = useProfiles()
const nameByUser = computed(() => {
  const map: Record<string, string> = {}
  for (const p of profiles.data.value ?? []) {
    map[p.user_id] = p.full_name || p.email || p.user_id
  }
  return map
})

const { data: accountNames } = useAccountNames(
  computed(() => (actions.data.value ?? []).map((a) => a.customer_key)),
)

/** Logins and actions merged newest-first, capped for render sanity. */
const stream = computed(() => {
  const entries: {
    key: string
    at: string
    who: string
    what: string
    account?: string
    accountKey?: string
  }[] = []
  for (const l of logins.data.value ?? []) {
    entries.push({
      key: `login-${l.id}`,
      at: l.logged_at,
      who: nameByUser.value[l.user_id] ?? l.user_id,
      what: 'Signed in',
    })
  }
  for (const a of actions.data.value ?? []) {
    entries.push({
      key: `action-${a.id}`,
      at: `${a.action_date}T12:00:00Z`,
      who: nameByUser.value[a.user_id] ?? a.user_id,
      what: ACTION_LABELS[a.action_type as ActionType] ?? a.action_type,
      account: accountNames.value?.[a.customer_key] ?? a.customer_key,
      accountKey: a.customer_key,
    })
  }
  return entries.sort((a, b) => (a.at < b.at ? 1 : -1)).slice(0, 200)
})
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Activity
      </p>
      <h1 class="u-display mt-1 text-4xl">Is the field on the portal?</h1>
      <p class="text-muted mt-2 text-[15px]">
        Logins, logged work, and mission follow-through — by rep group and by rep.
      </p>
    </header>

    <div class="bg-line border-line grid grid-cols-3 gap-px border">
      <StatTile
        label="Reps"
        :value="tilesReady ? rows.length : dash"
        sub="field users"
      />
      <StatTile
        label="Active 30d"
        :value="tilesReady ? activeLast30 : dash"
        sub="signed in"
      />
      <StatTile
        label="Overdue missions"
        :value="tilesReady ? totalOverdue : dash"
        :tone="tilesReady && totalOverdue > 0 ? 'alert' : 'default'"
      />
    </div>

    <!-- Rep-group rollup -->
    <AppCard>
      <template #header>
        <h2 class="u-label text-ink">By rep group</h2>
      </template>
      <AsyncState
        :loading="activity.isPending.value"
        :error="activity.error.value"
        :empty="rollups.length === 0"
        empty-title="No reps yet"
        empty-body="Create users and stamp their rep codes on the Users tab."
        @retry="activity.refetch()"
      >
        <ul class="divide-line -m-4 divide-y">
          <li
            v-for="group in rollups"
            :key="group.vendorId"
            class="flex flex-wrap items-center justify-between gap-3 p-4"
          >
            <div class="min-w-0">
              <p class="text-ink font-semibold">{{ group.vendorId }}</p>
              <p class="text-muted mt-0.5 text-[15px]">
                {{ group.reps.length }} rep{{ group.reps.length === 1 ? '' : 's' }} ·
                {{ count(group.actions30d) }} actions 30d ·
                last login {{ daysAgo(group.lastLoginAt) }}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <span class="text-muted text-sm tabular-nums">
                {{ count(group.openMissions) }} open
              </span>
              <AppBadge v-if="group.overdueMissions > 0" tone="late">
                {{ count(group.overdueMissions) }} overdue
              </AppBadge>
            </div>
          </li>
        </ul>
      </AsyncState>
    </AppCard>

    <!-- Per-rep grid -->
    <AppCard>
      <template #header>
        <div>
          <h2 class="u-label text-ink">By rep</h2>
          <p class="text-muted mt-1 text-[13px]">
            {{ visibleRows.length }} {{ visibleRows.length === 1 ? 'rep' : 'reps' }}
          </p>
        </div>
        <div class="flex items-center gap-2">
          <label class="sr-only" for="vendor-filter">Filter by rep group</label>
          <select id="vendor-filter" v-model="vendorFilter" class="field max-w-48">
            <option value="">All rep groups</option>
            <option v-for="v in vendorOptions" :key="v" :value="v">{{ v }}</option>
          </select>
          <AppButton variant="ghost" :disabled="!visibleRows.length" @click="onExport">
            Export CSV
          </AppButton>
        </div>
      </template>

      <AsyncState
        :loading="activity.isPending.value"
        :error="activity.error.value"
        :empty="filteredRows.length === 0"
        empty-title="No reps"
        @retry="activity.refetch()"
      >
        <DataGrid
          :columns="columns"
          :data="filteredRows"
          :initial-sorting="[{ id: 'overdue_missions', desc: true }]"
          searchable
          search-label="Search reps"
          search-placeholder="Search reps…"
          :get-row-id="(row: RepActivity) => row.user_id ?? ''"
          min-width="52rem"
          @rows-change="visibleRows = $event"
        >
          <template #cell-full_name="{ row }">
            <span class="text-ink font-semibold">{{ row.full_name ?? '—' }}</span>
            <span v-if="!row.active" class="text-muted ml-1 text-[13px]">(inactive)</span>
          </template>
          <template #cell-vendor_id="{ row }">
            <span class="text-ink-2">{{ row.vendor_id || '—' }}</span>
          </template>
          <template #cell-last_login_at="{ row }">
            <span class="text-ink block whitespace-nowrap">
              {{ daysAgo(row.last_login_at) }}
            </span>
            <span v-if="row.last_login_at" class="text-muted block text-[13px]">
              {{ shortDate(row.last_login_at) }}
            </span>
          </template>
          <template #cell-logins_30d="{ row }">
            <span class="tabular-nums">{{ count(row.logins_30d) }}</span>
          </template>
          <template #cell-actions_30d="{ row }">
            <span class="tabular-nums">{{ count(row.actions_30d) }}</span>
          </template>
          <template #cell-open_missions="{ row }">
            <span class="tabular-nums">{{ count(row.open_missions) }}</span>
          </template>
          <template #cell-overdue_missions="{ row }">
            <AppBadge v-if="(row.overdue_missions ?? 0) > 0" tone="late">
              {{ count(row.overdue_missions) }}
            </AppBadge>
            <span v-else class="text-muted tabular-nums">0</span>
          </template>

          <!-- Phone layout -->
          <template #card="{ row }">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="text-ink truncate font-semibold">
                  {{ row.full_name ?? '—' }}
                  <span v-if="!row.active" class="text-muted text-[13px] font-normal">
                    (inactive)
                  </span>
                </p>
                <p class="text-muted mt-0.5 text-[15px]">
                  {{ row.vendor_id || 'No rep group' }} ·
                  {{ count(row.actions_30d) }} actions ·
                  {{ count(row.open_missions) }} open
                </p>
                <p class="text-muted mt-0.5 text-[13px]">
                  Last login {{ daysAgo(row.last_login_at) }}
                </p>
              </div>
              <AppBadge v-if="(row.overdue_missions ?? 0) > 0" tone="late">
                {{ count(row.overdue_missions) }} late
              </AppBadge>
            </div>
          </template>

          <template #empty>
            <p class="text-muted py-10 text-center text-[15px]">
              No reps match that search.
            </p>
          </template>
        </DataGrid>
      </AsyncState>
    </AppCard>

    <!-- Raw stream -->
    <AppCard>
      <template #header>
        <h2 class="u-label text-ink">Recent activity</h2>
        <div class="flex gap-1">
          <button
            v-for="w in WINDOWS"
            :key="w"
            type="button"
            class="tap-target font-label min-w-12 rounded-[2px] px-3 text-[13px] font-semibold tracking-[0.1em] uppercase"
            :class="window === w ? 'bg-ink text-canvas' : 'text-muted'"
            :aria-pressed="window === w"
            @click="window = w"
          >
            {{ w }}d
          </button>
        </div>
      </template>

      <AsyncState
        :loading="logins.isPending.value || actions.isPending.value"
        :error="logins.error.value || actions.error.value"
        :empty="stream.length === 0"
        empty-title="Nothing in this window"
        empty-body="Sign-ins and logged actions show up here."
        :rows="3"
        @retry="logins.refetch(); actions.refetch()"
      >
        <ul class="space-y-3">
          <li v-for="entry in stream" :key="entry.key" class="flex gap-3">
            <span class="bg-line-2 w-0.5 shrink-0 self-stretch" aria-hidden="true" />
            <div class="min-w-0">
              <p class="text-ink text-[15px]">
                <span class="font-semibold">{{ entry.who }}</span>
                · {{ entry.what }}
                <template v-if="entry.account">
                  ·
                  <RouterLink
                    :to="{ name: 'account', params: { customerKey: entry.accountKey ?? '' } }"
                    class="underline underline-offset-2"
                  >
                    {{ entry.account }}
                  </RouterLink>
                </template>
              </p>
              <p class="text-muted text-[13px]">{{ daysAgo(entry.at) }}</p>
            </div>
          </li>
        </ul>
      </AsyncState>
    </AppCard>
  </div>
</template>
