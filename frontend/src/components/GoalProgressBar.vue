<script setup lang="ts">
import { computed } from 'vue'

/**
 * Attainment against a goal, with a pace marker.
 *
 * Two facts on one line: how far along the account is, and where it should be
 * by today. The marker is the whole point — 58% means nothing on its own, and
 * "58% with the marker at 52%" is a rep going "good" without doing arithmetic
 * in a parking lot.
 *
 * Square, 1px-bordered, no radius: it is structure, not a control. Ember is
 * reserved for late (style.css), so it appears only when the account is
 * actually behind its pace; ahead and on-pace are plain ink.
 */
const props = withDefaults(
  defineProps<{
    /** Percent of the goal earned. May exceed 100 — the bar clamps, the label doesn't. */
    attainmentPct: number
    /** Percent that should be in by today. Drives the marker. */
    expectedPct?: number
    /** Null before the period starts: no marker, no verdict. */
    onTrack?: boolean | null
    /** Screen-reader name — "Goal progress for 2026". */
    label?: string
    height?: 'sm' | 'md'
  }>(),
  { expectedPct: 0, onTrack: null, label: 'Goal progress', height: 'md' },
)

const clamp = (n: number) => Math.max(0, Math.min(100, Number.isFinite(n) ? n : 0))

const fillWidth = computed(() => `${clamp(props.attainmentPct)}%`)
const markerLeft = computed(() => `${clamp(props.expectedPct)}%`)
const showMarker = computed(() => props.onTrack != null && props.expectedPct > 0)
const behind = computed(() => props.onTrack === false)
</script>

<template>
  <div
    class="border-line bg-canvas relative w-full border"
    :class="height === 'sm' ? 'h-2' : 'h-3'"
    role="progressbar"
    :aria-label="label"
    :aria-valuenow="Math.round(attainmentPct)"
    aria-valuemin="0"
    aria-valuemax="100"
    :aria-valuetext="`${Math.round(attainmentPct)} percent of goal`"
  >
    <div
      class="absolute inset-y-0 left-0"
      :class="behind ? 'bg-accent' : 'bg-ink'"
      :style="{ width: fillWidth }"
    />
    <!-- Where the account should be today. Sits above the fill so it stays
         visible when the fill has passed it. -->
    <div
      v-if="showMarker"
      class="bg-ink-2 absolute -top-1 -bottom-1 w-0.5"
      :style="{ left: markerLeft }"
      aria-hidden="true"
    />
  </div>
</template>
