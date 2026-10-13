<script setup lang="ts">
import { computed, ref, toRef, watch } from 'vue'
import { format, parseISO } from 'date-fns'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCollapsibleCard from '@/components/ui/AppCollapsibleCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { cardHintState } from '@/components/ui/cardHint'
import { gapPitch, isLapsedGap, useAccountSkuGaps } from '@/composables/useAccountGaps'
import { useReorderCandidates, type ReorderCandidate } from '@/composables/useReorderCandidates'
import { count, shortDate } from '@/lib/format'

/**
 * "Ready to ship" — the one card on this page that suggests something to
 * SELL rather than reporting what already happened. Two lists, best
 * conversation first:
 *
 *   1. Bought before · in stock now (report_reorder_candidates): this
 *      dealer's own repeat buys that we can ship today, "Due" when their
 *      usual gap since the last buy has passed. "You took six of these in
 *      October and we have forty" is the easiest call a rep makes all day.
 *   2. Stocked by other dealers (report_account_sku_gaps): in stock, carried
 *      by 4+ dealers, and new to this one or not bought in a year. Every
 *      number in it existed before, on three screens the rep used to
 *      cross-reference in their head while standing in the shop.
 *
 * A part in the first list is not repeated in the second.
 *
 * The framing is deliberately the same as the Overview's "Worth
 * investigating": an observation with the evidence attached, never an
 * instruction. "Stocked by 61 dealers, never carried here" is an argument the
 * rep can choose to make. "You should sell them a Ridgeline" is a task, and
 * this product does not assign reps tasks (the AI voice rules in
 * ai-brief/prompts.ts say the same thing for the same reason).
 *
 * Fetched when first opened, not on page load: two RPCs most account visits
 * never look at. That means the card cannot know it is empty until opened,
 * so it always shows its header and says so inside. The queries are keyed
 * off '' until then (disabled), and the loading state reads isPending only
 * once the card is open — a disabled TanStack v5 query sits in 'pending'
 * forever, which used to be the "hide me unless rows || isPending" bug.
 */
const props = defineProps<{ customerKey: string }>()

const card = ref<InstanceType<typeof AppCollapsibleCard> | null>(null)
const opened = ref(false)
watch(
  () => card.value?.isOpen,
  (open) => {
    if (open) opened.value = true
  },
)

const customerKey = toRef(props, 'customerKey')
const activeKey = computed(() => (opened.value ? customerKey.value : ''))

const gaps = useAccountSkuGaps(activeKey)
const reorders = useReorderCandidates(activeKey, 10)

/** Hidden, not an error, on a database without report_reorder_candidates. */
const reorderRows = computed<ReorderCandidate[]>(() =>
  reorders.unavailable.value ? [] : reorders.rows.value,
)
const reorderKeys = computed(() => new Set(reorderRows.value.map((r) => r.part_key)))
const gapRows = computed(() =>
  (gaps.data.value ?? []).filter((r) => !reorderKeys.value.has(r.part_key)),
)

const fresh = computed(() => gapRows.value.filter((r) => !r.bought_before))
const lapsed = computed(() => gapRows.value.filter((r) => isLapsedGap(r)))
const due = computed(() => reorderRows.value.filter((r) => r.is_due))
const total = computed(() => reorderRows.value.length + gapRows.value.length)

const loading = computed(
  () =>
    opened.value &&
    (gaps.isPending.value || (!reorders.unavailable.value && reorders.isPending.value)),
)
const error = computed(
  () => gaps.error.value ?? (reorders.unavailable.value ? null : reorders.error.value),
)
const hasData = computed(
  () =>
    gaps.data.value !== undefined &&
    (reorders.data.value !== undefined || reorders.unavailable.value),
)
const updatedAt = computed(() =>
  reorders.unavailable.value
    ? gaps.dataUpdatedAt.value
    : Math.min(gaps.dataUpdatedAt.value, reorders.dataUpdatedAt.value),
)

function retry() {
  void gaps.refetch()
  if (!reorders.unavailable.value) void reorders.refetch()
}

const PREVIEW_REORDERS = 4
const PREVIEW_GAPS = 6
const expanded = ref(false)
const shownReorders = computed(() =>
  expanded.value ? reorderRows.value : reorderRows.value.slice(0, PREVIEW_REORDERS),
)
const shownGaps = computed(() =>
  expanded.value ? gapRows.value : gapRows.value.slice(0, PREVIEW_GAPS),
)
const hasMore = computed(
  () => reorderRows.value.length > PREVIEW_REORDERS || gapRows.value.length > PREVIEW_GAPS,
)

const hint = computed(() => {
  // Not opened yet: nothing fetched, nothing honest to summarise.
  if (!opened.value) return undefined
  const state = cardHintState({ isPending: loading, error }, total.value)
  if (state) return state
  const parts: string[] = []
  if (due.value.length) parts.push(`${due.value.length} due`)
  else if (reorderRows.value.length) {
    const n = reorderRows.value.length
    parts.push(`${n} reorder${n === 1 ? '' : 's'}`)
  }
  if (fresh.value.length) parts.push(`${fresh.value.length} new`)
  if (lapsed.value.length) parts.push(`${lapsed.value.length} lapsed`)
  return parts.join(' · ') || `${gapRows.value.length} in stock`
})

function monthYear(isoDate: string): string {
  const d = parseISO(isoDate)
  return Number.isNaN(d.getTime()) ? isoDate : format(d, 'MMM yyyy')
}

/** "Bought 6 in Oct 2025 · 40 available", plus their rhythm when it is due. */
function reorderLine(r: ReorderCandidate): string {
  const parts = [
    `Bought ${count(r.last_qty)} in ${monthYear(r.last_bought_month)}`,
    `${count(r.ats_qty)} available`,
  ]
  const gap = r.median_months_between_buys
  if (r.is_due && gap != null && gap >= 1) {
    const months = Math.round(gap)
    parts.push(months === 1 ? 'buys about monthly' : `buys about every ${months} months`)
  }
  return parts.join(' · ')
}
</script>

<template>
  <AppCollapsibleCard ref="card" title="Ready to ship" :hint="hint" :padded="false">
    <AsyncState
      :loading="loading"
      :error="error"
      :has-data="hasData"
      :updated-at="updatedAt"
      :empty="!loading && total === 0"
      empty-title="Nothing to suggest"
      empty-body="Nothing in stock today that this dealer reorders, or that other dealers carry and they don't."
      :rows="2"
      @retry="retry"
    >
      <section v-if="reorderRows.length">
        <h3 class="u-label bg-canvas border-line border-b px-4 py-2">
          Bought before · in stock now
        </h3>
        <ul class="divide-line divide-y">
          <li v-for="r in shownReorders" :key="r.part_key" class="px-4 py-2.5">
            <div class="flex items-start justify-between gap-3">
              <p class="text-ink min-w-0 text-[15px] font-semibold">
                {{ r.part_id }}
                <span class="text-ink-2 font-normal"> · {{ r.part_description }}</span>
              </p>
              <AppBadge v-if="r.is_due" tone="good" class="shrink-0">Due</AppBadge>
            </div>
            <p class="text-muted mt-0.5 text-xs tabular-nums">{{ reorderLine(r) }}</p>
          </li>
        </ul>
      </section>

      <section v-if="gapRows.length" :class="reorderRows.length ? 'border-line border-t' : ''">
        <h3 class="u-label bg-canvas border-line border-b px-4 py-2">
          Stocked by other dealers
        </h3>
        <p class="text-muted border-line border-b px-4 py-2.5 text-[13px]">
          In stock today, ranked by how many other dealers stock it.
        </p>
        <ul class="divide-line divide-y">
          <li v-for="r in shownGaps" :key="r.part_key" class="px-4 py-2.5">
            <p class="text-ink text-[15px] font-semibold">
              {{ r.part_id }}
              <span class="text-ink-2 font-normal"> · {{ r.part_description }}</span>
            </p>
            <p class="text-muted mt-0.5 text-xs tabular-nums">
              {{ count(r.ats_qty) }} available · {{ gapPitch(r) }}
              <template v-if="r.bought_before && r.last_bought_date">
                (last {{ shortDate(r.last_bought_date) }})
              </template>
            </p>
          </li>
        </ul>
      </section>

      <div v-if="hasMore" class="border-line border-t p-3">
        <AppButton variant="ghost" block @click="expanded = !expanded">
          {{ expanded ? 'Show fewer' : `Show all ${total}` }}
        </AppButton>
      </div>
    </AsyncState>
  </AppCollapsibleCard>
</template>
