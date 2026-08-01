<script setup lang="ts">
/**
 * Mission control: create directed work in bulk, then watch it get done.
 *
 * The composer's Preview and Create call the SAME server-side scope
 * resolution (create_mission with/without p_dry_run), so the number the
 * admin approves is the number that lands. Preview is required before
 * Create — a fat-fingered "all accounts" blast should never be one tap.
 */
import { computed, ref, watch } from 'vue'
import { endOfMonth, format } from 'date-fns'
import { refDebounced } from '@vueuse/core'
import type { ColumnDef } from '@tanstack/vue-table'
import {
  friendlyMissionError,
  useCreateMission,
  useMissionBatches,
  useMissionDetail,
  useMissionPreview,
  useSalesReps,
  type MissionBatchProgress,
  type MissionDetail,
  type MissionInput,
} from '@/composables/useMissions'
import { useAccountSearch } from '@/composables/useAccounts'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import {
  MISSION_SCOPE_LABELS,
  MISSION_SCOPES,
  REC_PRIORITIES,
  type MissionScope,
} from '@/types/domain'
import { count, shortDate } from '@/lib/format'
import { exportCsv, type CsvColumn } from '@/lib/csv'

/* ---- composer state ----------------------------------------------------- */
const composing = ref(false)
const scopeType = ref<MissionScope>('rep')
const scopeValue = ref('')
const pickedKeys = ref<string[]>([])
const title = ref('')
const reason = ref('')
const priority = ref('normal')
const dueDate = ref(format(endOfMonth(new Date()), 'yyyy-MM-dd'))
const requiresVisit = ref(true)
const activeOnly = ref(true)

const composeError = ref('')
const createdNotice = ref('')
/** null = not previewed yet; Create stays disabled until a preview ran. */
const previewCount = ref<number | null>(null)

const reps = useSalesReps()
const vendors = computed(() =>
  [...new Set((reps.data.value ?? []).map((r) => r.vendor_id).filter(Boolean))].sort() as string[],
)

/* Account picker for the hand-picked scope — same server-side search as the
   accounts page. */
const accountSearch = ref('')
const accountSearchDebounced = refDebounced(accountSearch, 300)
const accountResults = useAccountSearch(accountSearchDebounced, activeOnly)
const searchRows = computed(
  () => accountResults.data.value?.pages.flatMap((p) => p.rows) ?? [],
)

function togglePicked(key: string) {
  const i = pickedKeys.value.indexOf(key)
  if (i >= 0) pickedKeys.value.splice(i, 1)
  else pickedKeys.value.push(key)
}

/** Any change to what the mission targets voids the previewed count. */
watch([scopeType, scopeValue, pickedKeys, activeOnly], () => {
  previewCount.value = null
}, { deep: true })

const input = computed<MissionInput>(() => ({
  title: title.value,
  reason: reason.value,
  priority: priority.value,
  dueDate: dueDate.value || null,
  requiresVisit: requiresVisit.value,
  scopeType: scopeType.value,
  scopeValue:
    scopeType.value === 'vendor' || scopeType.value === 'rep'
      ? scopeValue.value
      : null,
  customerKeys: scopeType.value === 'custom' ? [...pickedKeys.value] : null,
  activeOnly: activeOnly.value,
}))

const preview = useMissionPreview()
const createMission = useCreateMission()

function validate(): string {
  if (!title.value.trim()) return 'Give the mission a title first.'
  if ((scopeType.value === 'vendor' || scopeType.value === 'rep') && !scopeValue.value)
    return 'Pick which rep or rep group this mission is for.'
  if (scopeType.value === 'custom' && pickedKeys.value.length === 0)
    return 'Pick at least one account.'
  return ''
}

async function runPreview() {
  composeError.value = validate()
  createdNotice.value = ''
  if (composeError.value) return
  try {
    previewCount.value = await preview.mutateAsync(input.value)
    if (previewCount.value === 0) {
      composeError.value = 'That scope matches no accounts. Widen it or check the filter.'
      previewCount.value = null
    }
  } catch (e) {
    composeError.value = friendlyMissionError(e)
  }
}

async function runCreate() {
  composeError.value = validate()
  if (composeError.value || previewCount.value == null) return
  try {
    const result = await createMission.mutateAsync(input.value)
    createdNotice.value = `Created ${count(result.created)} missions.`
    composing.value = false
    title.value = ''
    reason.value = ''
    pickedKeys.value = []
    previewCount.value = null
  } catch (e) {
    composeError.value = friendlyMissionError(e)
  }
}

/* ---- batches grid ------------------------------------------------------- */
const batches = useMissionBatches()
const visibleBatches = ref<MissionBatchProgress[]>([])

function pctDone(row: MissionBatchProgress): number {
  const total = row.total ?? 0
  if (!total) return 0
  return Math.round((((row.closed_count ?? 0) + (row.dismissed_count ?? 0)) / total) * 100)
}

function scopeLabel(row: MissionBatchProgress): string {
  const label = MISSION_SCOPE_LABELS[(row.scope_type as MissionScope) ?? 'custom']
  return row.scope_value ? `${label}: ${row.scope_value}` : label
}

const batchColumns: ColumnDef<MissionBatchProgress, any>[] = [
  { id: 'title', accessorFn: (r) => r.title ?? '', header: 'Mission' },
  { id: 'scope', accessorFn: (r) => scopeLabel(r), header: 'Scope' },
  { id: 'due_date', accessorFn: (r) => r.due_date ?? '', header: 'Due' },
  { id: 'total', accessorFn: (r) => r.total ?? 0, header: 'Accounts' },
  { id: 'done', accessorFn: (r) => pctDone(r), header: 'Done' },
  { id: 'overdue_count', accessorFn: (r) => r.overdue_count ?? 0, header: 'Overdue' },
  { id: 'detail', header: '', enableSorting: false, accessorFn: () => '' },
]

/* ---- drill-down --------------------------------------------------------- */
const openBatchId = ref<number | null>(null)
const openBatch = computed(
  () => (batches.data.value ?? []).find((b) => b.batch_id === openBatchId.value) ?? null,
)
const detail = useMissionDetail(openBatchId)
const visibleDetail = ref<MissionDetail[]>([])

const detailColumns: ColumnDef<MissionDetail, any>[] = [
  { id: 'customer_name', accessorFn: (r) => r.customer_name ?? r.customer_key ?? '', header: 'Account' },
  { id: 'rep_names', accessorFn: (r) => r.rep_names ?? '', header: 'Rep' },
  { id: 'status', accessorFn: (r) => r.status ?? '', header: 'Status' },
  { id: 'due_date', accessorFn: (r) => r.due_date ?? '', header: 'Due' },
  { id: 'outcome', accessorFn: (r) => r.outcome ?? '', header: 'Outcome' },
]

function exportDetail() {
  const columns: CsvColumn<MissionDetail>[] = [
    { key: 'customer_key', header: 'Customer Key' },
    { key: 'customer_name', header: 'Account' },
    { key: 'rep_names', header: 'Rep' },
    { key: 'status', header: 'Status' },
    { key: 'due_date', header: 'Due Date' },
    { key: 'outcome', header: 'Outcome' },
    { key: 'outcome_note', header: 'Outcome Note' },
    { key: 'closed_at', header: 'Closed At' },
  ]
  exportCsv(`mission-${openBatchId.value}`, visibleDetail.value, columns)
}
</script>

<template>
  <div class="space-y-5">
    <header class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
          Missions
        </p>
        <h1 class="u-display mt-1 text-4xl">Direct the work</h1>
        <p class="text-muted mt-2 text-[15px]">
          Assign follow-ups — to one account or the whole book — and see
          whether they actually happened.
        </p>
      </div>
      <AppButton v-if="!composing" variant="primary" @click="composing = true">
        New mission
      </AppButton>
    </header>

    <p v-if="createdNotice" role="status" class="text-ink text-sm font-medium">
      {{ createdNotice }}
    </p>

    <!-- Composer -->
    <AppCard v-if="composing" title="New mission">
      <div class="space-y-4">
        <fieldset>
          <legend class="u-label mb-2">Who is this for?</legend>
          <div class="flex flex-wrap gap-2">
            <button
              v-for="s in MISSION_SCOPES"
              :key="s"
              type="button"
              class="inline-flex min-h-11 items-center rounded-[2px] px-4 text-[15px] font-semibold"
              :class="
                scopeType === s
                  ? 'bg-ink text-canvas'
                  : 'border-line-2 text-ink-2 border bg-transparent'
              "
              :aria-pressed="scopeType === s"
              @click="scopeType = s; scopeValue = ''"
            >
              {{ MISSION_SCOPE_LABELS[s] }}
            </button>
          </div>
        </fieldset>

        <label v-if="scopeType === 'vendor'" class="block max-w-md">
          <span class="u-label mb-1.5 block">Rep group</span>
          <select v-model="scopeValue" class="field">
            <option value="" disabled>Pick a rep group…</option>
            <option v-for="v in vendors" :key="v" :value="v">{{ v }}</option>
          </select>
        </label>

        <label v-else-if="scopeType === 'rep'" class="block max-w-md">
          <span class="u-label mb-1.5 block">Rep</span>
          <select v-model="scopeValue" class="field">
            <option value="" disabled>Pick a rep…</option>
            <option
              v-for="r in reps.data.value ?? []"
              :key="r.sales_rep_key"
              :value="r.sales_rep_key"
            >
              {{ r.sales_rep_name || r.sales_rep_key }}
            </option>
          </select>
        </label>

        <!-- Hand-picked accounts: search + tap to add -->
        <div v-else-if="scopeType === 'custom'" class="space-y-2">
          <label class="block max-w-md">
            <span class="u-label mb-1.5 block">Find accounts</span>
            <input
              v-model="accountSearch"
              type="search"
              class="field"
              placeholder="Name, key, or city…"
            />
          </label>
          <ul
            v-if="accountSearch && searchRows.length"
            class="divide-line border-line max-h-64 divide-y overflow-y-auto border"
          >
            <li v-for="a in searchRows" :key="a.customer_key">
              <button
                type="button"
                class="tap-target flex w-full items-center justify-between gap-3 px-3 text-left"
                :aria-pressed="pickedKeys.includes(a.customer_key)"
                @click="togglePicked(a.customer_key)"
              >
                <span class="min-w-0 truncate">
                  <span class="text-ink font-semibold">{{ a.customer_name }}</span>
                  <span class="text-muted"> · {{ a.customer_key }}</span>
                </span>
                <span
                  class="font-label shrink-0 text-xs font-semibold tracking-[0.1em] uppercase"
                  :class="pickedKeys.includes(a.customer_key) ? 'text-ink' : 'text-muted'"
                >
                  {{ pickedKeys.includes(a.customer_key) ? 'Added' : 'Add' }}
                </span>
              </button>
            </li>
          </ul>
          <p class="text-muted text-sm">
            {{ pickedKeys.length }} account{{ pickedKeys.length === 1 ? '' : 's' }} picked
            <button
              v-if="pickedKeys.length"
              type="button"
              class="text-ink ml-2 font-medium underline underline-offset-2"
              @click="pickedKeys = []"
            >
              Clear
            </button>
          </p>
        </div>

        <div class="grid gap-3 sm:grid-cols-2">
          <label class="block sm:col-span-2">
            <span class="u-label mb-1.5 block">Title</span>
            <input
              v-model="title"
              type="text"
              class="field"
              placeholder="e.g. Pre-season follow-up visit"
            />
          </label>
          <label class="block sm:col-span-2">
            <span class="u-label mb-1.5 block">
              Why <span class="normal-case">(shown to the rep — optional)</span>
            </span>
            <textarea
              v-model="reason"
              rows="2"
              class="field h-auto p-3.5"
              placeholder="What should they accomplish?"
            />
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Priority</span>
            <select v-model="priority" class="field">
              <option v-for="p in REC_PRIORITIES" :key="p" :value="p">{{ p }}</option>
            </select>
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Due date</span>
            <input v-model="dueDate" type="date" class="field" />
          </label>
        </div>

        <div class="flex flex-wrap gap-4">
          <label class="flex items-center gap-2.5">
            <input
              v-model="requiresVisit"
              type="checkbox"
              class="border-line-2 size-5 rounded-[2px]"
            />
            <span class="text-ink text-[15px] font-medium">
              Require the visit survey to clear it
            </span>
          </label>
          <label class="flex items-center gap-2.5">
            <input
              v-model="activeOnly"
              type="checkbox"
              class="border-line-2 size-5 rounded-[2px]"
            />
            <span class="text-ink text-[15px] font-medium">Active accounts only</span>
          </label>
        </div>

        <p v-if="composeError" role="alert" class="text-danger text-sm font-medium">
          {{ composeError }}
        </p>
        <p v-if="previewCount != null" role="status" class="text-ink text-sm font-semibold">
          This will create {{ count(previewCount) }} mission{{ previewCount === 1 ? '' : 's' }} —
          one per account.
        </p>

        <div class="flex flex-wrap gap-2">
          <AppButton
            variant="secondary"
            :loading="preview.isPending.value"
            @click="runPreview"
          >
            Preview
          </AppButton>
          <AppButton
            variant="primary"
            :disabled="previewCount == null"
            :loading="createMission.isPending.value"
            @click="runCreate"
          >
            Create missions
          </AppButton>
          <AppButton variant="ghost" @click="composing = false">Cancel</AppButton>
        </div>
      </div>
    </AppCard>

    <!-- Batches -->
    <AppCard>
      <template #header>
        <div>
          <h2 class="u-label text-ink">Mission progress</h2>
          <p class="text-muted mt-1 text-[13px]">
            {{ visibleBatches.length }}
            {{ visibleBatches.length === 1 ? 'batch' : 'batches' }}
          </p>
        </div>
      </template>

      <AsyncState
        :loading="batches.isPending.value"
        :error="batches.error.value"
        :empty="(batches.data.value?.length ?? 0) === 0"
        empty-title="No missions yet"
        empty-body="Create the first one above — it lands on every targeted rep's Today page."
        @retry="batches.refetch()"
      >
        <DataGrid
          :columns="batchColumns"
          :data="batches.data.value ?? []"
          :initial-sorting="[{ id: 'overdue_count', desc: true }]"
          :get-row-id="(row: MissionBatchProgress) => String(row.batch_id)"
          min-width="48rem"
          @rows-change="visibleBatches = $event"
        >
          <template #cell-title="{ row }">
            <span class="text-ink font-semibold">{{ row.title }}</span>
            <AppBadge v-if="row.requires_visit" tone="neutral" class="ml-2">
              Visit
            </AppBadge>
          </template>
          <template #cell-scope="{ row }">
            <span class="text-ink-2">{{ scopeLabel(row) }}</span>
          </template>
          <template #cell-due_date="{ row }">
            <span class="whitespace-nowrap">{{ shortDate(row.due_date) }}</span>
          </template>
          <template #cell-total="{ row }">
            <span class="tabular-nums">{{ count(row.total) }}</span>
          </template>
          <template #cell-done="{ row }">
            <span class="text-ink font-semibold tabular-nums">{{ pctDone(row) }}%</span>
            <span class="text-muted ml-1 text-[13px] tabular-nums">
              {{ count((row.closed_count ?? 0) + (row.dismissed_count ?? 0)) }}/{{ count(row.total) }}
            </span>
          </template>
          <template #cell-overdue_count="{ row }">
            <AppBadge v-if="(row.overdue_count ?? 0) > 0" tone="late">
              {{ count(row.overdue_count) }}
            </AppBadge>
            <span v-else class="text-muted tabular-nums">0</span>
          </template>
          <template #cell-detail="{ row }">
            <AppButton
              variant="ghost"
              @click="openBatchId = openBatchId === row.batch_id ? null : row.batch_id"
            >
              {{ openBatchId === row.batch_id ? 'Hide' : 'Details' }}
            </AppButton>
          </template>

          <!-- Phone layout -->
          <template #card="{ row }">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="text-ink truncate font-semibold">{{ row.title }}</p>
                <p class="text-muted mt-0.5 text-[15px]">
                  {{ scopeLabel(row) }} · {{ pctDone(row) }}% of {{ count(row.total) }}
                </p>
                <p class="text-muted mt-0.5 text-[13px]">
                  Due {{ shortDate(row.due_date) }}
                </p>
                <AppButton
                  variant="ghost"
                  class="mt-1"
                  @click="openBatchId = openBatchId === row.batch_id ? null : row.batch_id"
                >
                  {{ openBatchId === row.batch_id ? 'Hide details' : 'Details' }}
                </AppButton>
              </div>
              <AppBadge v-if="(row.overdue_count ?? 0) > 0" tone="late">
                {{ count(row.overdue_count) }} late
              </AppBadge>
            </div>
          </template>

          <template #empty>
            <p class="text-muted py-10 text-center text-[15px]">
              No batches match that search.
            </p>
          </template>
        </DataGrid>
      </AsyncState>
    </AppCard>

    <!-- Drill-down: every account in the batch, who owns it, where it stands -->
    <AppCard v-if="openBatchId != null">
      <template #header>
        <div>
          <h2 class="u-label text-ink">{{ openBatch?.title ?? 'Batch detail' }}</h2>
          <p class="text-muted mt-1 text-[13px]">
            {{ visibleDetail.length }}
            {{ visibleDetail.length === 1 ? 'account' : 'accounts' }}
          </p>
        </div>
        <AppButton variant="ghost" :disabled="!visibleDetail.length" @click="exportDetail">
          Export CSV
        </AppButton>
      </template>

      <AsyncState
        :loading="detail.isPending.value"
        :error="detail.error.value"
        :empty="(detail.data.value?.length ?? 0) === 0"
        empty-title="Nothing in this batch"
        @retry="detail.refetch()"
      >
        <DataGrid
          :columns="detailColumns"
          :data="detail.data.value ?? []"
          :initial-sorting="[{ id: 'status', desc: false }]"
          searchable
          search-label="Search accounts"
          search-placeholder="Search accounts…"
          :get-row-id="(row: MissionDetail) => String(row.id)"
          min-width="44rem"
          @rows-change="visibleDetail = $event"
        >
          <template #cell-customer_name="{ row }">
            <RouterLink
              :to="{ name: 'account', params: { customerKey: row.customer_key ?? '' } }"
              class="text-ink font-semibold underline underline-offset-2"
            >
              {{ row.customer_name ?? row.customer_key }}
            </RouterLink>
          </template>
          <template #cell-rep_names="{ row }">
            <span class="text-ink-2">{{ row.rep_names || '—' }}</span>
          </template>
          <template #cell-status="{ row }">
            <AppBadge v-if="row.status === 'closed'" tone="good">Closed</AppBadge>
            <AppBadge v-else-if="row.status === 'dismissed'" tone="neutral">
              Dismissed
            </AppBadge>
            <AppBadge v-else-if="row.status === 'acted'" tone="high">Acted</AppBadge>
            <AppBadge v-else tone="neutral">Open</AppBadge>
          </template>
          <template #cell-due_date="{ row }">
            <span class="whitespace-nowrap">{{ shortDate(row.due_date) }}</span>
          </template>
          <template #cell-outcome="{ row }">
            <span class="text-ink-2">{{ row.outcome || '—' }}</span>
          </template>

          <template #card="{ row }">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <RouterLink
                  :to="{ name: 'account', params: { customerKey: row.customer_key ?? '' } }"
                  class="text-ink truncate font-semibold underline underline-offset-2"
                >
                  {{ row.customer_name ?? row.customer_key }}
                </RouterLink>
                <p class="text-muted mt-0.5 text-[15px]">
                  {{ row.rep_names || 'Unassigned' }}
                </p>
              </div>
              <AppBadge v-if="row.status === 'closed'" tone="good">Closed</AppBadge>
              <AppBadge v-else-if="row.status === 'dismissed'" tone="neutral">
                Dismissed
              </AppBadge>
              <AppBadge v-else-if="row.status === 'acted'" tone="high">Acted</AppBadge>
              <AppBadge v-else tone="neutral">Open</AppBadge>
            </div>
          </template>

          <template #empty>
            <p class="text-muted py-10 text-center text-[15px]">
              No accounts match that search.
            </p>
          </template>
        </DataGrid>
      </AsyncState>
    </AppCard>
  </div>
</template>
