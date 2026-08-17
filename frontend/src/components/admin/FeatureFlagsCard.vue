<script setup lang="ts">
import { computed, ref } from 'vue'
import {
  useAppSettings,
  useUpdateAppSetting,
  type AppSettingRow,
} from '@/composables/useAppSettings'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { daysAgo } from '@/lib/format'

/**
 * Feature flags — the "boil the frog slowly" control panel (data-first
 * restructure). Each capture feature can be re-enabled here, one switch at a
 * time, no deploy. Data under a hidden feature is intact; flipping it back
 * on restores everything. Lives on the admin Settings page above the
 * scoring/rules tuning.
 */
const query = useAppSettings()
const update = useUpdateAppSetting()

const rows = computed(() => query.data.value ?? [])
const busyKey = ref('')
const error = ref('')

const LABELS: Record<string, string> = {
  'feature.recommendations': 'Recommendations & missions',
  'feature.visits': 'Visit surveys & photos',
  'feature.tasks': 'Personal tasks',
  'feature.action_logging': 'Action logging & notes',
  'feature.orders': 'Order writer & entry queue',
}

function label(row: AppSettingRow): string {
  return LABELS[row.setting_key] ?? row.setting_key
}

async function toggle(row: AppSettingRow) {
  busyKey.value = row.setting_key
  error.value = ''
  try {
    await update.mutateAsync({
      setting_key: row.setting_key,
      enabled: !row.enabled,
    })
  } catch (e) {
    error.value = (e as Error).message || 'Could not save that.'
  } finally {
    busyKey.value = ''
  }
}
</script>

<template>
  <AppCard title="Features" :padded="false">
    <p class="text-ink-2 border-line border-b px-4 py-3 text-[15px] leading-relaxed">
      Hidden features keep their data — surveys, notes, tasks, and open
      recommendations all come back exactly as they were when you switch a
      feature on. The nightly recommendation generator pauses while
      recommendations are off (signals and scores keep refreshing).
    </p>

    <p v-if="error" role="alert" class="text-danger px-4 pt-3 text-sm font-medium">
      {{ error }}
    </p>

    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && rows.length === 0"
      empty-title="No settings"
      empty-body="Apply supabase/migrations/024_app_settings.sql to seed the feature flags."
      :rows="4"
      @retry="query.refetch()"
    >
      <ul class="divide-line divide-y">
        <li
          v-for="row in rows"
          :key="row.setting_key"
          class="flex items-center justify-between gap-4 px-4 py-3"
        >
          <div class="min-w-0">
            <p class="text-ink text-[15px] font-semibold">{{ label(row) }}</p>
            <p v-if="row.description" class="text-muted mt-0.5 text-xs">
              {{ row.description }}
            </p>
            <p class="text-muted mt-0.5 text-xs">
              Changed {{ daysAgo(row.updated_at) }}
            </p>
          </div>
          <!-- A real switch: 48px hit area, state readable without color. -->
          <button
            type="button"
            role="switch"
            :aria-checked="row.enabled"
            :aria-label="`${label(row)} — ${row.enabled ? 'on' : 'off'}`"
            :disabled="busyKey === row.setting_key"
            class="tap-target font-label flex shrink-0 items-center gap-2 text-[13px] font-semibold tracking-[0.12em] uppercase disabled:opacity-50"
            @click="toggle(row)"
          >
            <span
              class="relative block h-7 w-12 border transition-colors"
              :class="row.enabled ? 'bg-brand border-brand' : 'bg-canvas border-line-2'"
              aria-hidden="true"
            >
              <span
                class="absolute top-0.5 block size-6 bg-surface shadow-sm transition-all"
                :class="row.enabled ? 'left-[22px]' : 'left-0.5'"
              />
            </span>
            {{ row.enabled ? 'On' : 'Off' }}
          </button>
        </li>
      </ul>
    </AsyncState>
  </AppCard>
</template>
