<script lang="ts">
import type { RouteLocationRaw } from 'vue-router'

/**
 * A chip that GOES somewhere rather than routing to a panel on this page:
 * a map, the phone's mail app, the order writer. `href` renders an <a>
 * (external ones open in a new tab), `to` a RouterLink.
 */
export interface QuickLink {
  id: string
  label: string
  icon: 'directions' | 'email' | 'order'
  href?: string
  to?: RouteLocationRaw
  /** Opens in a new tab — a maps link should not unload the account. */
  external?: boolean
}
</script>

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
 * Two kinds of chip. `links` leave the page — Directions, Email, New order —
 * and come first, because they are what a rep reaches for before a call or
 * a drive; none of them writes anything, so the page keeps them for an
 * admin viewing as a rep. `include` chips only ROUTE: every panel still
 * opens inline, in place, further down the page — the no-modals-for-writes
 * rule is untouched, and the survey remains the thing the page is for.
 *
 * No `variant="primary"` here: the page's one green button is still "Log a
 * visit" in its own section. These are outlines on the ink header.
 */
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import type { QuickAction } from '@/types/domain'

/**
 * `include` lets the page hide the chips whose target panels are behind a
 * disabled feature flag (data-first restructure). Omitted = all six.
 */
const props = defineProps<{ include?: QuickAction[]; links?: QuickLink[] }>()

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

const LINK_ICONS: Record<QuickLink['icon'], string> = {
  directions: 'M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21Zm0-9a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5Z',
  email: 'M3 6h18v12H3V6Zm0 0 9 7 9-7',
  order: 'M3 4h2l2.4 11h11.2L21 7H7M9.5 20a1 1 0 1 0 0-2 1 1 0 0 0 0 2Zm8 0a1 1 0 1 0 0-2 1 1 0 0 0 0 2Z',
}

const visible = computed(() =>
  props.include ? actions.filter((a) => props.include!.includes(a.id)) : actions,
)
const linkChips = computed(() => props.links ?? [])

/* The strip hides its scrollbar, and at 390px with the three link chips
   first the next chip started a pixel past the edge: nothing said Log
   visit, Note or Photo were there. While more chips sit off to the right
   the strip's right edge fades out, so the cut-off chip reads as "more". */
const strip = ref<HTMLElement | null>(null)
const moreToTheRight = ref(false)
function measure() {
  const el = strip.value
  moreToTheRight.value = !!el && el.scrollLeft + el.clientWidth < el.scrollWidth - 4
}
const FADE = 'linear-gradient(to right, #000 calc(100% - 3rem), transparent)'
const fadeStyle = computed(() =>
  moreToTheRight.value ? { maskImage: FADE, WebkitMaskImage: FADE } : undefined,
)
onMounted(() => {
  measure()
  // The chips' width settles once the condensed face has loaded.
  void document.fonts?.ready.then(measure)
  window.addEventListener('resize', measure)
})
onBeforeUnmount(() => window.removeEventListener('resize', measure))
watch(
  () => [props.include?.length, props.links?.length],
  () => requestAnimationFrame(measure),
)

const chipClass =
  'tap-target font-label text-canvas flex shrink-0 items-center gap-2 rounded-[2px] border border-[#4A4D44] px-3 text-[13px] font-semibold tracking-[0.1em] uppercase hover:border-canvas'
</script>

<template>
  <!-- Scrolls horizontally on a narrow phone rather than wrapping to two rows
       and pushing the account numbers below the fold. -->
  <div
    v-if="visible.length || linkChips.length"
    ref="strip"
    class="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    :style="fadeStyle"
    role="group"
    aria-label="Account actions"
    @scroll.passive="measure"
  >
    <template v-for="l in linkChips" :key="l.id">
      <RouterLink v-if="l.to" :to="l.to" :class="chipClass">
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
          <path :d="LINK_ICONS[l.icon]" />
        </svg>
        {{ l.label }}
      </RouterLink>
      <a
        v-else
        :href="l.href"
        :class="chipClass"
        :target="l.external ? '_blank' : undefined"
        :rel="l.external ? 'noopener noreferrer' : undefined"
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
          <path :d="LINK_ICONS[l.icon]" />
        </svg>
        {{ l.label }}
      </a>
    </template>
    <button
      v-for="a in visible"
      :key="a.id"
      type="button"
      :class="chipClass"
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
