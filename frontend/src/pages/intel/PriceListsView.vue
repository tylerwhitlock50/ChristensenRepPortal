<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import {
  downloadPriceListFile,
  usePriceListFiles,
  type PriceListFileRow,
} from '@/composables/usePriceListFiles'
import { formatBytes } from '@/lib/photos'
import { shortDate } from '@/lib/format'

/**
 * The approved price sheets, one per customer type — always on, no feature
 * flag: this is a read-only reference surface, the same reason the rest of
 * Sales Intel is. Downloads run through short-lived signed URLs; the
 * bucket is private.
 */
const filesQuery = usePriceListFiles()

const groups = computed(() => {
  const byType = new Map<string, PriceListFileRow[]>()
  for (const file of filesQuery.data.value ?? []) {
    const list = byType.get(file.customer_type) ?? []
    list.push(file)
    byType.set(file.customer_type, list)
  }
  return [...byType.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([customerType, files]) => ({ customerType, files }))
})

const downloadingId = ref<number | null>(null)
const downloadError = ref('')

async function download(file: PriceListFileRow) {
  downloadingId.value = file.id
  downloadError.value = ''
  try {
    await downloadPriceListFile(file)
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
    <p class="text-ink-2 max-w-2xl text-[15px] leading-relaxed">
      The approved price sheet for each customer type. Download the one that
      matches the account you're quoting — pricing questions beyond these
      sheets go to the office.
    </p>

    <p v-if="downloadError" role="alert" class="text-danger text-sm font-medium">
      {{ downloadError }}
    </p>

    <AsyncState
      :loading="filesQuery.isLoading.value"
      :error="filesQuery.error.value"
      :empty="groups.length === 0"
      empty-title="No price lists yet"
      empty-body="An admin publishes the approved sheets from Admin → Price Lists."
      :rows="3"
      @retry="filesQuery.refetch()"
    >
      <div class="grid gap-4 md:grid-cols-2">
        <AppCard
          v-for="group in groups"
          :key="group.customerType"
          :title="group.customerType"
        >
          <ul class="space-y-3">
            <li
              v-for="file in group.files"
              :key="file.id"
              class="flex flex-wrap items-center justify-between gap-3"
            >
              <div class="min-w-0">
                <p class="text-ink truncate text-[15px] font-semibold">
                  {{ file.title }}
                </p>
                <p class="text-muted text-[13px]">
                  {{ file.file_name }} · {{ formatBytes(file.file_size) }} ·
                  updated {{ shortDate(file.uploaded_at) }}
                </p>
              </div>
              <AppButton
                variant="secondary"
                :loading="downloadingId === file.id"
                @click="download(file)"
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
