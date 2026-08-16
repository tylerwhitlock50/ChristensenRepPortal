<script setup lang="ts">
import { computed, ref, toRef } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCollapsibleCard from '@/components/ui/AppCollapsibleCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { cardHintState } from '@/components/ui/cardHint'
import { gapPitch, useAccountSkuGaps } from '@/composables/useAccountGaps'
import { count, shortDate } from '@/lib/format'

/**
 * "Ready to ship, and they don't carry it."
 *
 * The one card on this page that suggests something to SELL rather than
 * reporting what already happened. Every number in it existed before, on
 * three separate screens — the ATS list, this account's SKU history, and
 * global best-sellers — and the rep was expected to cross-reference them
 * mentally while standing in the shop.
 *
 * The framing is deliberately the same as the Overview's "Worth
 * investigating": an observation with the evidence attached, never an
 * instruction. "Stocked by 61 dealers, never carried here" is an argument the
 * rep can choose to make. "You should sell them a Ridgeline" is a task, and
 * this product does not assign reps tasks (the AI voice rules in
 * ai-brief/prompts.ts say the same thing for the same reason).
 *
 * Collapsed on arrival like the rest of the history below the fold, and
 * silent when there is nothing available — an empty card is worse than no
 * card on a screen a rep opens every day.
 */
const props = defineProps<{ customerKey: string }>()

const query = useAccountSkuGaps(toRef(props, 'customerKey'))
const rows = computed(() => query.data.value ?? [])

/** Never-carried first; the RPC already ranks them that way. */
const fresh = computed(() => rows.value.filter((r) => !r.bought_before))
const lapsed = computed(() => rows.value.filter((r) => r.bought_before))

const PREVIEW = 6
const expanded = ref(false)
const shown = computed(() =>
  expanded.value ? rows.value : rows.value.slice(0, PREVIEW),
)

const hint = computed(() => {
  const state = cardHintState(query, rows.value.length)
  if (state) return state
  if (fresh.value.length && lapsed.value.length) {
    return `${fresh.value.length} new · ${lapsed.value.length} lapsed`
  }
  if (fresh.value.length) return `${fresh.value.length} not carried`
  return `${lapsed.value.length} lapsed`
})
</script>

<template>
  <!-- Nothing available to suggest → no card at all. -->
  <AppCollapsibleCard
    v-if="rows.length > 0 || query.isPending.value"
    title="Ready to ship"
    :hint="hint"
    :padded="false"
  >
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :empty="!query.isPending.value && rows.length === 0"
      empty-title="Nothing to suggest"
      empty-body="Everything we can ship today, this dealer already buys."
      :rows="2"
      @retry="query.refetch()"
    >
      <p class="text-muted border-line border-b px-4 py-2.5 text-[13px]">
        In stock today, ranked by how many other dealers stock it.
      </p>

      <ul class="divide-line divide-y">
        <li v-for="r in shown" :key="r.part_key" class="px-4 py-2.5">
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

      <div v-if="rows.length > PREVIEW" class="border-line border-t p-3">
        <AppButton variant="ghost" block @click="expanded = !expanded">
          {{ expanded ? 'Show fewer' : `Show all ${rows.length}` }}
        </AppButton>
      </div>
    </AsyncState>
  </AppCollapsibleCard>
</template>
