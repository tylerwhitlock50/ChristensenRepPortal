<script setup lang="ts">
/**
 * The sign-in notification (PRD follow-up): if sales ops has directed work at
 * this rep, it is the first thing on the Today page — above the stat tiles,
 * above everything. The missions themselves are in the feed right below, so
 * the "link" is a scroll, not a route.
 *
 * Ember is reserved for lateness (style.css contract), so the banner is ink
 * unless something is overdue.
 */
const props = defineProps<{
  open: number
  overdue: number
}>()

const emit = defineEmits<{ show: [] }>()

function label(): string {
  const missions = `${props.open} open mission${props.open === 1 ? '' : 's'}`
  if (props.overdue > 0) {
    return `${missions} · ${props.overdue} overdue`
  }
  return missions
}
</script>

<template>
  <button
    v-if="open > 0"
    type="button"
    class="bg-ink text-canvas tap-target flex w-full items-center justify-between gap-3 border px-4 py-3 text-left"
    :class="overdue > 0 ? 'border-accent' : 'border-ink'"
    @click="emit('show')"
  >
    <span class="flex min-w-0 items-center gap-3">
      <span
        class="block h-8 w-[3px] shrink-0"
        :class="overdue > 0 ? 'bg-accent' : 'bg-canvas'"
        aria-hidden="true"
      />
      <span class="min-w-0">
        <span class="font-label block text-xs font-semibold tracking-[0.16em] text-[#8E8A80] uppercase">
          From sales ops
        </span>
        <span class="text-[15px] font-semibold">
          You have {{ label() }}
        </span>
      </span>
    </span>
    <span
      class="font-label shrink-0 text-[13px] font-semibold tracking-[0.12em] uppercase underline underline-offset-4"
    >
      See them
    </span>
  </button>
</template>
