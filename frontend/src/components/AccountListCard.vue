<script setup lang="ts">
import { computed } from 'vue'
import { daysAgo, money } from '@/lib/format'
import { YTD_TONE, ytdChange } from '@/lib/scoreReasons'

/**
 * One account on the phone Accounts list: who and where, this year's money
 * against the same time last year, the one thing the numbers say about it
 * (the Overview's classifier, useOverview.ts observeAccount), and a star for
 * "My plan".
 *
 * The star is a sibling of the link, not inside it — a button inside an <a>
 * is invalid and, on iOS, a tap on it would also navigate.
 */
const props = defineProps<{
  customerKey: string
  name: string | null
  /** "Bozeman, MT", or '' */
  place: string
  /** Leave out (undefined) to drop the "Last order" line part altogether. */
  lastOrderDate?: string | null
  /** Rep write-off or ERP inactive; the write-off wins (it explains more). */
  status?: 'deactivated' | 'inactive' | null
  /** Null when this account is not in the territory rows (inactive). */
  revenueYtd?: number | null
  revenuePriorYtd?: number | null
  /** One plain-English reason, or null when nothing stands out. */
  reason?: string | null
  starred: boolean
  /** Hide the star (e.g. the plan is full and this one is not on it). */
  starDisabled?: boolean
}>()

defineEmits<{ toggleStar: [] }>()

const label = computed(() => props.name || props.customerKey)

const delta = computed(() => ytdChange(props.revenueYtd, props.revenuePriorYtd, money))
</script>

<template>
  <li class="flex items-stretch">
    <RouterLink
      :to="{ name: 'account', params: { customerKey } }"
      class="tap-target hover:bg-canvas flex min-w-0 flex-1 flex-col justify-center gap-1 py-3.5 pr-1 pl-4"
    >
      <span class="flex items-baseline justify-between gap-3">
        <!-- The ID is the disambiguator — a book has many "GUN SHOP"s.
             It sits outside the truncating name span so a long name clips
             itself rather than the one field that tells two look-alike
             accounts apart. -->
        <span class="flex min-w-0 items-baseline gap-1.5">
          <span class="text-ink truncate text-[17px] font-semibold">{{ label }}</span>
          <span v-if="name" class="text-muted shrink-0 text-[13px] font-medium">
            ({{ customerKey }})
          </span>
        </span>
        <span
          v-if="status"
          class="border-line text-muted font-label shrink-0 border px-1.5 py-0.5 text-[11px] font-semibold tracking-[0.1em] uppercase"
        >
          {{ status === 'deactivated' ? 'Deactivated' : 'Inactive' }}
        </span>
      </span>

      <span v-if="place || lastOrderDate !== undefined" class="text-muted truncate text-sm">
        {{ place }}<template v-if="place && lastOrderDate !== undefined"> · </template>
        <template v-if="lastOrderDate !== undefined">Last order {{ daysAgo(lastOrderDate) }}</template>
      </span>

      <span
        v-if="revenueYtd != null"
        class="flex flex-wrap items-baseline gap-x-1.5 text-sm tabular-nums"
      >
        <span class="text-ink-2">{{ money(revenueYtd) }} this year</span>
        <span v-if="delta" class="font-semibold" :class="YTD_TONE[delta.direction]">
          <span aria-hidden="true">{{ delta.text }}</span>
          <span class="sr-only">{{ delta.sr }}</span>
        </span>
      </span>

      <span v-if="reason" class="self-start">
        <span class="border-line bg-canvas text-ink-2 inline-block border px-2 py-0.5 text-[13px] leading-snug">
          {{ reason }}
        </span>
      </span>

      <slot />
    </RouterLink>

    <button
      type="button"
      class="tap-target flex w-12 shrink-0 items-start justify-center pt-3 text-2xl leading-none disabled:opacity-40"
      :class="starred ? 'text-ink' : 'text-muted hover:text-ink'"
      :aria-pressed="starred"
      :aria-label="starred ? `Remove ${label} from my plan` : `Add ${label} to my plan`"
      :disabled="starDisabled && !starred"
      @click="$emit('toggleStar')"
    >
      <span aria-hidden="true">{{ starred ? '★' : '☆' }}</span>
    </button>
  </li>
</template>
