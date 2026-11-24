<script setup lang="ts">
import { computed, ref } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import {
  fetchLegalAcceptanceLog,
  useAdminLegalStatus,
  useLegalDocuments,
  type LegalAcceptanceRow,
} from '@/composables/useLegal'
import type { AdminProfile } from '@/composables/useAdminUsers'
import { LEGAL_DOC_LABEL, LEGAL_DOC_ROUTE } from '@/lib/legal'
import { count, humanize, shortDate } from '@/lib/format'
import type { ExportColumn } from '@/lib/xlsx'

/**
 * Admin › Users: who has agreed to the current Terms of Use and Privacy
 * Policy (admin_legal_status(), 20261124090000), who still has to, and the
 * agreement log itself as a file — the evidence: who agreed to which
 * version (with its SHA-256), when, from which address and browser.
 *
 * Nobody can be agreed for from here, and nothing here changes a record:
 * agreements are append-only, and only the person can make one, in the
 * portal.
 */
const props = defineProps<{ profiles: readonly AdminProfile[] }>()

const status = useAdminLegalStatus()
const docs = useLegalDocuments()

interface PendingRow {
  user_id: string
  full_name: string
  email: string
  role: string
  state: string
  last_accepted_at: string | null
}

const byUser = computed(() => new Map((status.data.value ?? []).map((r) => [r.user_id, r])))
const active = computed(() => props.profiles.filter((p) => p.active))
const agreedCount = computed(() => active.value.length - pendingRows.value.length)
/** Nothing in force: admin_legal_status() has a row for the caller whenever something is. */
const nothingPublished = computed(() => status.isSuccess.value && (status.data.value?.length ?? 0) === 0)

/** What is in force, by key: the denominator's documents. */
const currentKeys = computed(() => (docs.data.value ?? []).map((d) => d.doc_key))

/**
 * Everyone active who has not agreed to everything current, including a
 * profile the status has no row for yet (created since it was read): with
 * documents in force, no row means not agreed. Same people as the count.
 */
const pendingRows = computed<PendingRow[]>(() =>
  (status.data.value?.length ?? 0) === 0 && currentKeys.value.length === 0
    ? []
    : active.value
    .filter((p) => !byUser.value.get(p.user_id)?.all_accepted)
    .map((p) => {
      const r = byUser.value.get(p.user_id)
      const keys = r?.pending.length ? r.pending : currentKeys.value
      const outstanding = keys.map((k) => LEGAL_DOC_LABEL[k]).join(' and ') || 'the current documents'
      const last = r?.last_accepted_at ?? null
      return {
        user_id: p.user_id,
        full_name: p.full_name || p.email || 'Unnamed',
        email: p.email ?? '',
        role: humanize(p.role === 'order_entry' ? 'inside sales' : p.role),
        state: last
          ? `Agreed to an earlier version; needs to agree to the current ${outstanding}`
          : `Has not agreed yet (${outstanding})`,
        last_accepted_at: last,
      }
    })
    .sort((a, b) => a.full_name.localeCompare(b.full_name)),
)

const pendingColumns: ExportColumn<PendingRow>[] = [
  { key: 'full_name', header: 'Name' },
  { key: 'email', header: 'Email' },
  { key: 'role', header: 'Role' },
  { key: 'state', header: 'Status' },
  { key: 'last_accepted_at', header: 'Last agreed (any version)', type: 'datetime' },
]

const versionsLine = computed(() =>
  (docs.data.value ?? [])
    .map((d) => `${LEGAL_DOC_LABEL[d.doc_key]} version ${d.version}, effective ${shortDate(d.effective_at)}`)
    .join(' · '),
)

function retryAll() {
  void status.refetch()
  void docs.refetch()
}

/* ---- the agreement log, as a file ---------------------------------------- */
const logBusy = ref(false)
const logError = ref('')

const logColumns: ExportColumn<LegalAcceptanceRow>[] = [
  { key: 'accepted_at', header: 'Agreed at', type: 'datetime' },
  { key: 'full_name', header: 'Name (when agreed)' },
  { key: 'email', header: 'Email (when agreed)' },
  { key: 'role', header: 'Role (when agreed)' },
  { key: 'doc_key', header: 'Document', format: (r) => LEGAL_DOC_LABEL[r.doc_key] ?? r.doc_key },
  { key: 'version', header: 'Version', type: 'text' },
  { key: 'content_sha256', header: 'Document SHA-256', type: 'text' },
  { key: 'ip_address', header: 'IP address', type: 'text' },
  { key: 'user_agent', header: 'Browser (user agent)' },
  { key: 'user_id', header: 'User id', format: (r) => r.user_id ?? '(login deleted)' },
  { key: 'id', header: 'Record id', type: 'integer' },
]

async function downloadLog() {
  if (logBusy.value) return
  logBusy.value = true
  logError.value = ''
  try {
    const [rows, { exportXlsx }] = await Promise.all([fetchLegalAcceptanceLog(), import('@/lib/xlsx')])
    await exportXlsx('legal-agreement-log', rows, logColumns, {
      title: 'Terms of Use and Privacy Policy agreements',
      description:
        'Every agreement on record, newest first. Name, email and role are as they were when the person agreed. ' +
        'IP address and browser are as the API gateway reported them.',
    })
  } catch (e) {
    console.error('[legal log]', e)
    logError.value = "Couldn't build the file. Try again."
  } finally {
    logBusy.value = false
  }
}
</script>

<template>
  <AppCard title="Terms & privacy">
    <template #actions>
      <ExportMenu
        :rows="pendingRows"
        :columns="pendingColumns"
        title="Users who still need to agree to the Terms of Use and Privacy Policy"
        filename="legal-not-agreed"
        :details="[versionsLine, 'Active users only']"
      />
    </template>

    <AsyncState
      :loading="status.isPending.value"
      :error="status.error.value"
      :has-data="status.data.value !== undefined"
      :empty="nothingPublished"
      empty-title="Nothing published"
      empty-body="No Terms of Use or Privacy Policy is in force, so nobody is asked to agree."
      @retry="retryAll"
    >
      <p v-if="docs.error.value && !docs.data.value" role="alert" class="text-danger mb-2 text-sm">
        Couldn’t load which versions are in force.
        <button type="button" class="underline underline-offset-2" @click="docs.refetch()">Try again</button>
      </p>
      <p class="text-ink-2 text-[15px] leading-relaxed">
        Everyone must agree to the current
        <RouterLink :to="{ name: LEGAL_DOC_ROUTE.terms }" target="_blank" class="underline underline-offset-2">Terms of Use</RouterLink>
        and
        <RouterLink :to="{ name: LEGAL_DOC_ROUTE.privacy }" target="_blank" class="underline underline-offset-2">Privacy Policy</RouterLink>
        before they can use the portal, and again whenever a new version is
        published. They are asked when they next open it.
      </p>
      <p v-if="versionsLine" class="text-muted mt-1 text-xs">{{ versionsLine }}</p>

      <p class="text-ink mt-3 text-sm font-semibold">
        {{ count(agreedCount) }} of {{ count(active.length) }} active users have agreed.
      </p>

      <ul v-if="pendingRows.length" class="divide-line border-line mt-3 divide-y border">
        <li v-for="row in pendingRows" :key="row.user_id" class="flex flex-wrap items-baseline gap-x-3 gap-y-1 px-3 py-2">
          <span class="text-ink text-sm font-semibold">{{ row.full_name }}</span>
          <span class="text-muted text-xs">{{ row.email }} · {{ row.role }}</span>
          <AppBadge :tone="row.last_accepted_at ? 'neutral' : 'late'" class="ml-auto">
            {{ row.last_accepted_at ? 'Needs to re-agree' : 'Not agreed' }}
          </AppBadge>
        </li>
      </ul>

      <div class="mt-4 flex flex-wrap items-center gap-3">
        <AppButton variant="secondary" :loading="logBusy" @click="downloadLog">
          Download agreement log
        </AppButton>
        <span class="text-muted text-xs">
          Who agreed to which version, when, and from which address and browser (Excel).
        </span>
      </div>
      <p v-if="logError" role="alert" class="text-danger mt-2 text-sm">{{ logError }}</p>
    </AsyncState>
  </AppCard>
</template>
