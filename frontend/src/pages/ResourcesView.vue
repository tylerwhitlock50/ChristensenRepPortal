<script setup lang="ts">
import { computed, ref } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { downloadResource, useResources } from '@/composables/useResources'
import { useAccountNames } from '@/composables/useAccounts'
import { audienceTag, groupResources, resourceMatches, type ResourceRow } from '@/lib/resources'
import { formatBytes } from '@/lib/photos'
import { shortDate } from '@/lib/format'

/**
 * Resources: the documents the office publishes to reps — price lists,
 * program flyers, training. Always on, no feature flag, like the rest of the
 * read-only reference pages. RLS decides what is in the list: the files for
 * everyone, the ones for the rep's agency, and the ones for an account in
 * their book (an account's own price list). Downloads run through
 * short-lived signed URLs; the bucket is private.
 */
const resources = useResources()

/* An account's file is tagged with the account's name. The rep can read
   dim_customer for their own book, which is exactly the accounts they can
   see files for. */
const accountKeys = computed(() =>
  (resources.data.value ?? []).flatMap((r) => (r.customer_key ? [r.customer_key] : [])),
)
const accountNames = useAccountNames(accountKeys)
const names = computed(() => accountNames.data.value ?? {})

const search = ref('')
const groups = computed(() =>
  groupResources(
    (resources.data.value ?? []).filter((r) => resourceMatches(r, search.value, names.value)),
  ),
)
const total = computed(() => (resources.data.value ?? []).length)

const downloadingId = ref<number | null>(null)
const downloadError = ref('')

async function download(row: ResourceRow) {
  downloadingId.value = row.id
  downloadError.value = ''
  try {
    await downloadResource(row)
  } catch (err) {
    downloadError.value =
      (err as { message?: string }).message || 'The download could not start.'
  } finally {
    downloadingId.value = null
  }
}
</script>

<template>
  <div class="space-y-5">
    <header>
      <h1 class="u-display text-[34px]">Resources</h1>
      <p class="text-muted mt-1 max-w-2xl text-[15px]">
        Price lists, program flyers and other documents from the office. Files
        made for your agency or one of your accounts are marked. The approved
        sheet for each customer type is under
        <RouterLink :to="{ name: 'intel-price-lists' }" class="text-ink font-semibold underline">
          Intel › Price Lists</RouterLink
        >.
      </p>
    </header>

    <label v-if="total > 6" class="block max-w-md">
      <span class="sr-only">Search resources</span>
      <input
        v-model="search"
        type="search"
        class="border-line bg-surface text-ink min-h-12 w-full border px-3 text-[15px]"
        placeholder="Search by title, file or account…"
      />
    </label>

    <p v-if="downloadError" role="alert" class="text-danger text-sm font-medium">
      {{ downloadError }}
    </p>

    <AsyncState
      :loading="resources.isLoading.value"
      :error="resources.error.value"
      :has-data="resources.data.value !== undefined"
      :updated-at="resources.dataUpdatedAt.value"
      :empty="total === 0"
      empty-title="Nothing published yet"
      empty-body="When the office publishes a price list or program document, it shows up here."
      :rows="3"
      @retry="resources.refetch()"
    >
      <p v-if="groups.length === 0" class="text-muted text-[15px]">
        Nothing matches “{{ search }}”.
      </p>
      <div class="space-y-4">
        <AppCard v-for="group in groups" :key="group.category" :title="group.label">
          <ul class="divide-line divide-y">
            <li
              v-for="row in group.files"
              :key="row.id"
              class="flex flex-wrap items-center justify-between gap-3 py-3 first:pt-0 last:pb-0"
            >
              <div class="min-w-0 flex-1">
                <p class="text-ink flex flex-wrap items-center gap-2 text-[15px] font-semibold">
                  <span class="min-w-0 break-words">{{ row.title }}</span>
                  <AppBadge v-if="audienceTag(row, names)" tone="high">
                    {{ audienceTag(row, names) }}
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
              <AppButton
                variant="secondary"
                :loading="downloadingId === row.id"
                :aria-label="`Download ${row.title}`"
                @click="download(row)"
              >
                Download
              </AppButton>
            </li>
          </ul>
        </AppCard>
      </div>
    </AsyncState>
  </div>
</template>
