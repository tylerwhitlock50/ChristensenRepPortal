<script setup lang="ts" generic="T">
/**
 * The download button in a report's top-right corner: one tap opens a small
 * menu — Excel (.xlsx) or CSV — and either one exports exactly the rows on
 * screen, in screen order (pages feed it DataGrid's `rowsChange`).
 *
 * The Excel file carries what the screen carried around the grid and a CSV
 * cannot: a title saying what this is, when it was downloaded, and every
 * filter that narrowed it (lib/xlsx.ts metaLines). The CSV stays plain rows
 * with the header on line 1, so it still imports cleanly into other tools.
 *
 * Phone: icon-only (the label is sr-only below `sm`), same 48px target, and
 * the menu opens right-aligned under the button so it never runs off-screen.
 *
 * The writer (lib/xlsx.ts, which also maps column types for the CSV) is
 * imported on the first tap, not with the page: the account page alone
 * carries four of these buttons, and most visits never download anything.
 * The service worker precaches the chunk, so it still works offline.
 *
 * The trigger's accessible name is "Download <title>": an account page with
 * four cards open has four of these, and a screen reader has to be able to
 * tell them apart. It still starts with the visible word.
 */
import { computed, nextTick, ref, useId } from 'vue'
import { onClickOutside, onKeyStroke } from '@vueuse/core'
import { downloadCsv, toCsv } from '@/lib/csv'
import { exportFilename } from '@/lib/download'
import type { ExportColumn } from '@/lib/xlsx'
import { count } from '@/lib/format'

const props = withDefaults(
  defineProps<{
    /** Exactly the rows on screen, in order (DataGrid `@rows-change`). */
    rows: readonly T[]
    columns: readonly ExportColumn<T>[]
    /** Row 1 of the sheet: what this is, in the rep's words. */
    title: string
    /** File name before the time stamp: `in-stock` → in-stock-2026-11-13-1816.xlsx */
    filename: string
    /** One sentence on what the numbers mean. */
    description?: string | null
    /** What narrowed the rows — filters, account, dates, data freshness. Falsy entries dropped. */
    details?: readonly (string | null | undefined | false)[]
    /** Excel tab name (defaults to the title). */
    sheetName?: string
    label?: string
    disabled?: boolean
  }>(),
  { label: 'Download', disabled: false, description: null, details: () => [] },
)

const open = ref(false)
const error = ref('')
const root = ref<HTMLElement | null>(null)
const trigger = ref<HTMLButtonElement | null>(null)
const menu = ref<HTMLElement | null>(null)
const menuId = useId()

const isDisabled = computed(() => props.disabled || props.rows.length === 0)

function close(returnFocus = false) {
  if (!open.value) return
  open.value = false
  if (returnFocus) trigger.value?.focus()
}

async function toggle() {
  if (open.value) return close()
  error.value = ''
  open.value = true
  await nextTick()
  menu.value?.querySelector<HTMLElement>('[role="menuitem"]')?.focus()
}

onClickOutside(root, () => {
  close()
  error.value = ''
})
onKeyStroke('Escape', () => {
  close(true)
  error.value = ''
})

/** Arrow keys walk the two items; Tab leaves the menu and closes it. */
function onMenuKey(event: KeyboardEvent) {
  const items = Array.from(menu.value?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])
  const at = items.indexOf(document.activeElement as HTMLElement)
  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    event.preventDefault()
    const step = event.key === 'ArrowDown' ? 1 : -1
    items[(at + step + items.length) % items.length]?.focus()
  } else if (event.key === 'Tab') {
    close()
  }
}

const busy = ref(false)

async function download(kind: 'xlsx' | 'csv') {
  if (busy.value) return
  const when = new Date()
  busy.value = true
  error.value = ''
  try {
    const { csvColumnsFor, exportXlsx } = await import('@/lib/xlsx')
    // Close first, focus back on the trigger: the download is a synthetic
    // click on a hidden link, which onClickOutside would otherwise take as
    // a click away — closing the menu with focus dropped onto <body>.
    close(true)
    if (kind === 'xlsx') {
      await exportXlsx(props.filename, props.rows, props.columns, {
        title: props.title,
        description: props.description,
        details: props.details,
        sheetName: props.sheetName,
        generatedAt: when,
      })
    } else {
      downloadCsv(
        exportFilename(props.filename, 'csv', when),
        toCsv(props.rows, csvColumnsFor(props.columns)),
      )
    }
  } catch (e) {
    console.error('[export]', e)
    // Never drawn over the open menu: the menu closes, the message sits
    // under the button until the next tap, an outside click or Escape.
    close(true)
    error.value = "Couldn't build the file. Try again."
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div ref="root" class="relative shrink-0">
    <button
      ref="trigger"
      type="button"
      class="btn-ghost min-w-12 gap-1.5 px-3 text-[13px] disabled:pointer-events-none disabled:opacity-50"
      :disabled="isDisabled"
      :aria-label="`${label} ${title}`"
      aria-haspopup="menu"
      :aria-expanded="open"
      :aria-controls="open ? menuId : undefined"
      :title="isDisabled ? 'Nothing to download' : 'Download these rows as Excel or CSV'"
      @click="toggle"
    >
      <svg
        class="size-4"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        stroke-width="2.25"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="M12 4v11" />
        <path d="M7 10l5 5 5-5" />
        <path d="M5 20h14" />
      </svg>
      <span class="sr-only sm:not-sr-only">{{ label }}</span>
    </button>

    <div
      v-if="open"
      :id="menuId"
      ref="menu"
      role="menu"
      :aria-label="`Download ${title}: ${rows.length} ${rows.length === 1 ? 'row' : 'rows'}`"
      class="border-line bg-surface absolute right-0 z-40 mt-1 w-64 max-w-[calc(100vw-2rem)] border shadow-lg"
      @keydown="onMenuKey"
    >
      <button
        type="button"
        role="menuitem"
        class="tap-target hover:bg-canvas focus:bg-canvas flex w-full flex-col items-start justify-center px-4 py-2 text-left focus:outline-none disabled:opacity-50"
        :disabled="busy"
        @click="download('xlsx')"
      >
        <span class="text-ink text-[15px] font-semibold">Excel (.xlsx)</span>
        <span class="text-muted text-xs">With title, time stamp and filters</span>
      </button>
      <button
        type="button"
        role="menuitem"
        class="tap-target hover:bg-canvas focus:bg-canvas border-line flex w-full flex-col items-start justify-center border-t px-4 py-2 text-left focus:outline-none disabled:opacity-50"
        :disabled="busy"
        @click="download('csv')"
      >
        <span class="text-ink text-[15px] font-semibold">CSV (.csv)</span>
        <span class="text-muted text-xs">Plain rows, for other tools</span>
      </button>
      <!-- A menu may only own menuitems, so this line is for the eye; the
           menu's own name carries the count to a screen reader. -->
      <p class="text-muted border-line border-t px-4 py-2 text-xs" aria-hidden="true">
        {{ count(rows.length) }} {{ rows.length === 1 ? 'row' : 'rows' }}, as filtered on screen
      </p>
    </div>

    <p
      v-if="error"
      role="alert"
      class="text-accent bg-surface border-line absolute right-0 z-40 mt-1 w-56 border px-3 py-2 text-xs"
    >
      {{ error }}
    </p>
  </div>
</template>
