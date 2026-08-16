<script setup lang="ts">
/**
 * What a rep can DO on this account, at the top of the page.
 *
 * The account view is one long scroll — numbers, chart, AI summary, open
 * recommendations, and only then the six things a rep actually came here to
 * do. On a phone that is several thumb-flicks before the first button. This
 * strip puts all of them one tap away without breaking the scroll-through
 * story the page is built around (tabs would hide four fifths of it behind a
 * tap, on the one screen a rep reads in a parking lot before walking in).
 *
 * It only ROUTES. Every panel still opens inline, in place, further down the
 * page — the no-modals-for-writes rule is untouched, and the survey remains
 * the thing the page is for.
 *
 * No `variant="primary"` here: the page's one green button is still "Log a
 * visit" in its own section. These are outlines on the ink header.
 */
import { computed } from 'vue'
import type { QuickAction } from '@/types/domain'

/**
 * `include` lets the page hide the chips whose target panels are behind a
 * disabled feature flag (data-first restructure). Omitted = all six.
 */
const props = defineProps<{ include?: QuickAction[] }>()

defineEmits<{ select: [action: QuickAction] }>()

const actions: { id: QuickAction; label: string; path: string }[] = [
  // Rounded-cap strokes at 20px; the same drawing language as the nav icons.
  { id: 'visit', label: 'Log visit', path: 'M3 21h18M5 21V8l7-5 7 5v13M10 21v-5h4v5' },
  { id: 'contact', label: 'Log contact', path: 'M4 5h16v11H8l-4 4V5Z' },
  { id: 'note', label: 'Note', path: 'M5 3h9l5 5v13H5V3ZM14 3v5h5M8 13h8M8 17h5' },
  { id: 'photo', label: 'Photo', path: 'M3 7h4l2-2h6l2 2h4v12H3V7Zm9 3a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Z' },
  { id: 'task', label: 'Follow-up', path: 'M4 6h9M4 12h9M4 18h6M16 16l2.2 2.2L22 14' },
  { id: 'summary', label: 'Summary', path: 'M4 5h16M4 10h16M4 15h10M4 20h7' },
]

const visible = computed(() =>
  props.include ? actions.filter((a) => props.include!.includes(a.id)) : actions,
)
</script>

<template>
  <!-- Scrolls horizontally on a narrow phone rather than wrapping to two rows
       and pushing the account numbers below the fold. -->
  <div
    v-if="visible.length"
    class="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    role="group"
    aria-label="Account actions"
  >
    <button
      v-for="a in visible"
      :key="a.id"
      type="button"
      class="tap-target font-label text-canvas flex shrink-0 items-center gap-2 rounded-[2px] border border-[#4A4D44] px-3 text-[13px] font-semibold tracking-[0.1em] uppercase hover:border-canvas"
      @click="$emit('select', a.id)"
    >
      <svg
        class="size-5 shrink-0"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path :d="a.path" />
      </svg>
      {{ a.label }}
    </button>
  </div>
</template>
