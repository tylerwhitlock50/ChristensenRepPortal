<script setup lang="ts">
import { MIX_OTHER_SLOT, type MixBar, type MixSegment } from '@/composables/useIntel'
import { mixColor } from '@/lib/mixColors'
import { money, share } from '@/lib/format'

/**
 * Product mix as segmented bars — one bar per year, each the whole of that
 * year's revenue cut into families.
 *
 * Bars, not a pie: the question on this card is "did the mix move?", and
 * that is two wholes side by side. Two bars on one scale show a family
 * growing or shrinking as a width change in the same place; two pies make
 * the reader compare angles across a gap. A bar is also one thumb tall, so
 * the families' names and dollars — the list under it — stay on a phone's
 * first screen.
 *
 * Thin and wordless on purpose: every figure is in the list below, where each
 * row wears its segment's colour as a swatch, so the list is the legend and
 * the table view at once. Nothing is readable only by hovering.
 *
 * Plain HTML and CSS — no chart.js. The account page is opened on LTE in a
 * store, and a second chart type would add to the one chunk it already waits
 * for. Segments are real buttons: tap one to open that family in the list.
 *
 * Colours are slots, not ranks (mixSlots): a family is the same colour in
 * both bars and in the list. A 2px gap in the card's own white separates
 * neighbours, never a border.
 */
defineProps<{
  bars: readonly { label: string; bar: MixBar }[]
  /** The family the pointer or the list is on; its segments stay lit. */
  active?: string | null
}>()

const emit = defineEmits<{
  /** A segment was tapped. '' = "Other" standing for several families. */
  select: [key: string]
  hover: [key: string | null]
}>()

function segmentName(s: MixSegment): string {
  const what =
    s.slot === MIX_OTHER_SLOT && s.families > 1 ? `Other (${s.families} families)` : s.label
  return `${what}: ${money(s.revenue)}, ${share(s.share)}`
}

function barSummary(label: string, bar: MixBar): string {
  if (!bar.segments.length) return `${label}: nothing invoiced`
  return `${label}: ${money(bar.total)}. ` + bar.segments.map(segmentName).join('; ')
}
</script>

<template>
  <div class="space-y-3">
    <div v-for="{ label, bar } in bars" :key="label">
      <div class="flex items-baseline justify-between gap-3">
        <span class="font-label text-muted text-xs font-semibold tracking-[0.1em] uppercase">
          {{ label }}
        </span>
        <span class="text-ink text-sm font-semibold tabular-nums">
          {{ bar.segments.length ? money(bar.total) : 'Nothing invoiced' }}
        </span>
      </div>

      <!-- The group's name carries every segment's figure, so a screen
           reader gets the bar in one line; the buttons then repeat them one
           at a time for anyone stepping through. -->
      <div
        v-if="bar.segments.length"
        role="group"
        :aria-label="barSummary(label, bar)"
        class="flex gap-0.5"
      >
        <!-- The hit area is the padded button (24px tall), not the 8px
             mark; the 3px floor keeps a 0.3% sliver findable. -->
        <button
          v-for="s in bar.segments"
          :key="s.key || 'other'"
          type="button"
          class="group min-w-[3px] py-2 focus-visible:outline-offset-0"
          :style="{ flexGrow: s.share, flexBasis: 0 }"
          :title="segmentName(s)"
          :aria-label="segmentName(s)"
          @click="emit('select', s.key)"
          @pointerenter="emit('hover', s.key || null)"
          @pointerleave="emit('hover', null)"
          @focus="emit('hover', s.key || null)"
          @blur="emit('hover', null)"
        >
          <span
            class="block h-2 rounded-[2px] transition-opacity group-hover:opacity-100"
            :class="active && active !== s.key ? 'opacity-35' : ''"
            :style="{ backgroundColor: mixColor(s.slot) }"
          />
        </button>
      </div>
      <!-- An empty year still draws its track, so the two bars line up and
           "nothing" reads as nothing rather than as a missing chart. -->
      <div v-else class="py-2" aria-hidden="true">
        <span class="bg-line block h-2 rounded-[2px]" />
      </div>
    </div>
  </div>
</template>
