<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { refDebounced } from '@vueuse/core'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import {
  downloadResource,
  useDeleteResource,
  useResources,
  useSaveResource,
} from '@/composables/useResources'
import { useAccountNames, useAccountSearch } from '@/composables/useAccounts'
import { useRepGroupPerformance } from '@/composables/useAdminReports'
import {
  RESOURCE_ACCEPT,
  RESOURCE_CATEGORIES,
  audienceOf,
  audienceTag,
  categoryLabel,
  groupResources,
  validateResourceFile,
  type Audience,
  type ResourceRow,
} from '@/lib/resources'
import { formatBytes } from '@/lib/photos'
import { shortDate } from '@/lib/format'

/**
 * Admin › Resources: publish the documents reps download from Resources.
 * Each file is for everyone, for one agency (its principal and every rep
 * billing through it), or for one account (whoever has the account in their
 * book). RLS enforces the audience on the list AND on the bucket, so picking
 * an audience here is the whole access decision.
 */
const resources = useResources()
const save = useSaveResource()
const remove = useDeleteResource()

const accountKeys = computed(() =>
  (resources.data.value ?? []).flatMap((r) => (r.customer_key ? [r.customer_key] : [])),
)
const groups = computed(() => groupResources(resources.data.value ?? []))

/* ---- agencies: the same list Admin › Agencies picks from ---------------- */
const repGroups = useRepGroupPerformance()
const agencyOptions = computed(() =>
  (repGroups.data.value ?? [])
    .map((g) => g.rep_group_id)
    .filter((id) => id && id !== '(No rep group)' && id !== '—')
    .sort((a, b) => a.localeCompare(b)),
)

/* ---- the form ------------------------------------------------------------ */
type AudienceKind = Audience['kind']

const editing = ref<ResourceRow | null>(null)
const fTitle = ref('')
const fDescription = ref('')
const fCategory = ref<string>('price_list')
const fAudience = ref<AudienceKind>('everyone')
const fAgency = ref('')
const fAccount = ref('')
const fInput = ref<HTMLInputElement | null>(null)
const formError = ref('')
const notice = ref('')

/* Names for the list's account files and the account being picked. */
const accountNames = useAccountNames(
  computed(() => [...accountKeys.value, ...(fAccount.value ? [fAccount.value] : [])]),
)
const names = computed(() => accountNames.data.value ?? {})

/* Account search: server-side over the whole company (an admin's book). */
const accountTerm = ref('')
const accountTermDebounced = refDebounced(accountTerm, 250)
const accountSearch = useAccountSearch(
  accountTermDebounced,
  false,
  computed(() => fAudience.value === 'account' && accountTermDebounced.value.trim().length >= 2),
)
const accountMatches = computed(() =>
  (accountSearch.data.value?.pages[0]?.rows ?? []).slice(0, 8),
)
watch(fAudience, (kind) => {
  if (kind !== 'account') accountTerm.value = ''
})

function pickAccount(key: string) {
  fAccount.value = key
  accountTerm.value = ''
}

function resetForm() {
  editing.value = null
  fTitle.value = ''
  fDescription.value = ''
  fCategory.value = 'price_list'
  fAudience.value = 'everyone'
  fAgency.value = ''
  fAccount.value = ''
  accountTerm.value = ''
  formError.value = ''
  if (fInput.value) fInput.value.value = ''
}

function startEdit(row: ResourceRow) {
  resetForm()
  editing.value = row
  fTitle.value = row.title
  fDescription.value = row.description ?? ''
  fCategory.value = row.category
  const a = audienceOf(row)
  fAudience.value = a.kind
  if (a.kind === 'agency') fAgency.value = a.vendorId
  if (a.kind === 'account') fAccount.value = a.customerKey
  notice.value = ''
  document.getElementById('resource-form')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
}

function chosenAudience(): Audience | string {
  if (fAudience.value === 'agency') {
    return fAgency.value.trim() ? { kind: 'agency', vendorId: fAgency.value.trim() } : 'Pick the agency.'
  }
  if (fAudience.value === 'account') {
    return fAccount.value ? { kind: 'account', customerKey: fAccount.value } : 'Pick the account.'
  }
  return { kind: 'everyone' }
}

async function submit() {
  formError.value = ''
  notice.value = ''
  const file = fInput.value?.files?.[0] ?? null
  if (!fTitle.value.trim()) {
    formError.value = 'A title is required.'
    return
  }
  if (!editing.value && !file) {
    formError.value = 'Choose a file to publish.'
    return
  }
  if (file) {
    const problem = validateResourceFile(file)
    if (problem) {
      formError.value = problem
      return
    }
  }
  const audience = chosenAudience()
  if (typeof audience === 'string') {
    formError.value = audience
    return
  }
  const wasEditing = !!editing.value
  try {
    const row = await save.mutateAsync({
      existing: editing.value,
      title: fTitle.value,
      description: fDescription.value,
      category: fCategory.value,
      audience,
      file,
    })
    notice.value = wasEditing ? `Saved “${row.title}”.` : `Published “${row.title}”.`
    resetForm()
  } catch (err) {
    formError.value = (err as { message?: string }).message || 'That did not save.'
  }
}

async function takeDown(row: ResourceRow) {
  if (!window.confirm(`Take down “${row.title}”? Reps will no longer see it.`)) return
  notice.value = ''
  try {
    await remove.mutateAsync(row)
    if (editing.value?.id === row.id) resetForm()
    notice.value = `Took down “${row.title}”.`
  } catch (err) {
    formError.value = (err as { message?: string }).message || 'That did not come down.'
  }
}

const downloadError = ref('')
async function preview(row: ResourceRow) {
  downloadError.value = ''
  try {
    await downloadResource(row)
  } catch (err) {
    downloadError.value = (err as { message?: string }).message || 'The download could not start.'
  }
}
</script>

<template>
  <div class="space-y-6">
    <AppCard title="Published resources" hint="what reps see under Resources">
      <p v-if="notice" role="status" class="text-ink mb-3 text-sm font-medium">{{ notice }}</p>
      <p v-if="downloadError" role="alert" class="text-danger mb-3 text-sm">{{ downloadError }}</p>
      <AsyncState
        :loading="resources.isLoading.value"
        :error="resources.error.value"
        :has-data="resources.data.value !== undefined"
        :updated-at="resources.dataUpdatedAt.value"
        :empty="(resources.data.value ?? []).length === 0"
        empty-title="Nothing published yet"
        empty-body="Publish the first file below: a price list, a program flyer, anything reps ask the office for."
        :rows="3"
        @retry="resources.refetch()"
      >
        <div class="space-y-5">
          <section v-for="group in groups" :key="group.category">
            <h3 class="u-label text-muted pb-1">{{ group.label }}</h3>
            <ul class="divide-line divide-y">
              <li
                v-for="row in group.files"
                :key="row.id"
                class="flex flex-wrap items-center justify-between gap-3 py-3"
              >
                <div class="min-w-0 flex-1">
                  <p class="text-ink flex flex-wrap items-center gap-2 text-[15px] font-semibold">
                    <span class="min-w-0 break-words">{{ row.title }}</span>
                    <AppBadge :tone="row.customer_key || row.rep_group_vendor_id ? 'high' : 'neutral'">
                      {{ audienceTag(row, names, true) }}
                    </AppBadge>
                  </p>
                  <p v-if="row.description" class="text-ink-2 mt-0.5 text-[14px] leading-snug">
                    {{ row.description }}
                  </p>
                  <p class="text-muted mt-0.5 truncate text-[13px]">
                    {{ row.file_name }} · {{ formatBytes(row.file_size) }} ·
                    updated {{ shortDate(row.updated_at) }}
                  </p>
                </div>
                <div class="flex gap-1">
                  <AppButton variant="ghost" @click="preview(row)">Download</AppButton>
                  <AppButton variant="ghost" @click="startEdit(row)">Edit</AppButton>
                  <AppButton
                    variant="ghost"
                    :loading="remove.isPending.value && remove.variables.value?.id === row.id"
                    @click="takeDown(row)"
                  >
                    Take down
                  </AppButton>
                </div>
              </li>
            </ul>
          </section>
        </div>
      </AsyncState>
    </AppCard>

    <AppCard
      id="resource-form"
      :title="editing ? `Edit “${editing.title}”` : 'Publish a file'"
      :hint="editing ? categoryLabel(editing.category) : 'PDF, Excel, Word, PowerPoint, CSV, images, zip · 50 MB'"
    >
      <div class="grid gap-3 md:grid-cols-2">
        <label class="block">
          <span class="u-label text-ink block pb-2">Title</span>
          <input
            v-model="fTitle"
            maxlength="200"
            class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
            placeholder="2027 Dealer Price List"
          />
        </label>
        <label class="block">
          <span class="u-label text-ink block pb-2">Category</span>
          <select
            v-model="fCategory"
            class="border-line text-ink bg-surface min-h-12 w-full border px-3 text-[15px]"
          >
            <option v-for="c in RESOURCE_CATEGORIES" :key="c.key" :value="c.key">{{ c.label }}</option>
          </select>
        </label>
        <label class="block md:col-span-2">
          <span class="u-label text-ink block pb-2">Description (optional)</span>
          <input
            v-model="fDescription"
            class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
            placeholder="What it is and when to use it"
          />
        </label>

        <fieldset class="md:col-span-2">
          <legend class="u-label text-ink pb-2">Who sees it</legend>
          <div class="flex flex-wrap gap-x-5">
            <label class="flex min-h-12 items-center gap-2 text-[15px]">
              <input v-model="fAudience" type="radio" value="everyone" class="size-5" />
              Everyone
            </label>
            <label class="flex min-h-12 items-center gap-2 text-[15px]">
              <input v-model="fAudience" type="radio" value="agency" class="size-5" />
              One agency
            </label>
            <label class="flex min-h-12 items-center gap-2 text-[15px]">
              <input v-model="fAudience" type="radio" value="account" class="size-5" />
              One account
            </label>
          </div>
        </fieldset>

        <label v-if="fAudience === 'agency'" class="block md:col-span-2">
          <span class="u-label text-ink block pb-2">Agency</span>
          <select
            v-model="fAgency"
            class="border-line text-ink bg-surface min-h-12 w-full border px-3 text-[15px]"
          >
            <option value="" disabled>Pick an agency…</option>
            <!-- An agency no longer in the list still shows as picked. -->
            <option v-if="fAgency && !agencyOptions.includes(fAgency)" :value="fAgency">
              {{ fAgency }}
            </option>
            <option v-for="id in agencyOptions" :key="id" :value="id">{{ id }}</option>
          </select>
          <span class="text-muted mt-1 block text-[13px]">
            Its principal and every rep billing through it.
          </span>
        </label>

        <div v-if="fAudience === 'account'" class="md:col-span-2">
          <p v-if="fAccount" class="text-ink mb-2 flex flex-wrap items-center gap-2 text-[15px]">
            <span class="font-semibold">{{ names[fAccount] ?? fAccount }}</span>
            <span class="text-muted text-[13px]">{{ fAccount }}</span>
            <AppButton variant="ghost" @click="fAccount = ''">Change</AppButton>
          </p>
          <label v-else class="block">
            <span class="u-label text-ink block pb-2">Account</span>
            <input
              v-model="accountTerm"
              type="search"
              class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              placeholder="Search by name or customer ID…"
            />
            <ul v-if="accountMatches.length" class="border-line mt-1 divide-y border">
              <li v-for="a in accountMatches" :key="a.customer_key">
                <button
                  type="button"
                  class="tap-target hover:bg-canvas w-full px-3 text-left text-[15px]"
                  @click="pickAccount(a.customer_key)"
                >
                  {{ a.customer_name || a.customer_key }}
                  <span class="text-muted text-[13px]">· {{ a.customer_key }}</span>
                </button>
              </li>
            </ul>
          </label>
          <span class="text-muted mt-1 block text-[13px]">
            Whoever has the account in their book: its rep, their principal, and anyone granted it.
          </span>
        </div>

        <label class="block md:col-span-2">
          <span class="u-label text-ink block pb-2">
            {{ editing ? 'Replace the file (optional)' : 'File' }}
          </span>
          <input
            ref="fInput"
            type="file"
            :accept="RESOURCE_ACCEPT"
            class="border-line text-ink block w-full border p-2 text-[15px] file:mr-3 file:border-0 file:bg-transparent file:font-semibold"
          />
          <span v-if="editing" class="text-muted mt-1 block text-[13px]">
            Now: {{ editing.file_name }} · {{ formatBytes(editing.file_size) }}
          </span>
        </label>

        <p v-if="formError" role="alert" class="text-danger text-sm md:col-span-2">
          {{ formError }}
        </p>
        <div class="flex gap-2 md:col-span-2">
          <AppButton variant="primary" :loading="save.isPending.value" @click="submit">
            {{ editing ? 'Save changes' : 'Publish' }}
          </AppButton>
          <AppButton v-if="editing" variant="ghost" @click="resetForm">Cancel</AppButton>
        </div>
      </div>
    </AppCard>
  </div>
</template>
