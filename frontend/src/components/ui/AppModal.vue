<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref, watch } from 'vue'

/**
 * A flat, line-bordered modal in the house style: no radius, no shadow
 * theatrics, a labelled header with an explicit Close button.
 *
 * Kept deliberately small — open/close state lives with the caller
 * (`v-model:open`), the body is a slot. Escape and a backdrop tap both
 * close; focus moves into the dialog on open and back to the previously
 * focused element on close, so a keyboard user tapping through the orders
 * table doesn't get stranded.
 *
 * Note this does NOT contradict the "no modal" rule in VisitSurvey — that
 * rule is about never interrupting a WRITE flow with one. This is a
 * read-only drill-in the rep asked for by tapping a row.
 */
const props = defineProps<{
  open: boolean
  title: string
  /** Smaller line under the title — a date, a status. */
  subtitle?: string
}>()

const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const panel = ref<HTMLElement | null>(null)
let lastFocused: Element | null = null

function close() {
  emit('update:open', false)
}

function onKeydown(e: KeyboardEvent) {
  if (e.key === 'Escape') close()
}

watch(
  () => props.open,
  async (open) => {
    if (open) {
      lastFocused = document.activeElement
      document.addEventListener('keydown', onKeydown)
      document.body.style.overflow = 'hidden'
      await nextTick()
      panel.value?.focus()
    } else {
      document.removeEventListener('keydown', onKeydown)
      document.body.style.overflow = ''
      if (lastFocused instanceof HTMLElement) lastFocused.focus()
    }
  },
)

onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKeydown)
  document.body.style.overflow = ''
})
</script>

<template>
  <Teleport to="body">
    <div
      v-if="open"
      class="fixed inset-0 z-40 flex items-end justify-center sm:items-center sm:p-4"
      @click.self="close"
    >
      <!-- Backdrop -->
      <div class="bg-ink/40 absolute inset-0" aria-hidden="true" @click="close" />

      <!-- Bottom sheet on a phone, centered panel on anything wider -->
      <div
        ref="panel"
        role="dialog"
        aria-modal="true"
        :aria-label="title"
        tabindex="-1"
        class="border-line bg-surface relative flex max-h-[85vh] w-full flex-col border outline-none sm:max-w-2xl"
      >
        <header
          class="border-line flex items-start justify-between gap-3 border-b px-4 py-3"
        >
          <div class="min-w-0">
            <h2 class="u-label text-ink">{{ title }}</h2>
            <p v-if="subtitle" class="text-muted mt-0.5 text-sm">{{ subtitle }}</p>
          </div>
          <button
            type="button"
            class="text-muted hover:text-ink -m-2 p-2 text-2xl leading-none"
            aria-label="Close"
            @click="close"
          >
            &times;
          </button>
        </header>
        <div class="overflow-y-auto p-4">
          <slot />
        </div>
      </div>
    </div>
  </Teleport>
</template>
