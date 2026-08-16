<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { onClickOutside } from '@vueuse/core'

/**
 * Pick one account out of the rep's book.
 *
 * Replaces a bare <select> over the whole book. A native menulist with a few
 * hundred options is close to unusable on a phone — no typeahead beyond
 * first-letter jumping, and a scroll wheel the length of the territory — and
 * this control is the gate in front of a whole report.
 *
 * A text input that filters an inline list, rather than <datalist>: datalist
 * renders inconsistently across mobile browsers and silently degrades to a
 * plain text box in some, which would let a rep type a name that matches no
 * account and see nothing happen.
 *
 * Filtering is client-side on purpose — the caller already holds the book in
 * memory (the Overview's territory query, cached), so this costs no request.
 */

const props = withDefaults(
  defineProps<{
    accounts: { customer_key: string; customer_name?: string | null }[]
    /** Selected customer_key; '' means nothing chosen. */
    modelValue: string
    label?: string
    placeholder?: string
    /** Longest list rendered at once — a filter that matches everything
     *  should not paint 400 rows on an LTE phone. */
    limit?: number
  }>(),
  {
    label: 'Account',
    placeholder: 'Search your accounts…',
    limit: 40,
  },
)

const emit = defineEmits<{ 'update:modelValue': [string] }>()

const query = ref('')
const open = ref(false)
const root = ref<HTMLElement | null>(null)
onClickOutside(root, () => (open.value = false))

function nameOf(a: { customer_key: string; customer_name?: string | null }) {
  return a.customer_name || a.customer_key
}

const selected = computed(() =>
  props.accounts.find((a) => a.customer_key === props.modelValue) ?? null,
)

/** Keep the box showing the chosen account when the value changes elsewhere
 *  (deep link, parent reset) rather than stranding a stale search term. */
watch(
  () => props.modelValue,
  () => {
    if (!open.value) query.value = ''
  },
)

const matches = computed(() => {
  const term = query.value.trim().toLowerCase()
  const pool = props.accounts
  if (!term) return pool.slice(0, props.limit)
  // Key as well as name: reps identify look-alike shops by customer number,
  // the same reason AccountsView prints it next to every name.
  return pool
    .filter(
      (a) =>
        nameOf(a).toLowerCase().includes(term) ||
        a.customer_key.toLowerCase().includes(term),
    )
    .slice(0, props.limit)
})

const total = computed(() => {
  const term = query.value.trim().toLowerCase()
  if (!term) return props.accounts.length
  return props.accounts.filter(
    (a) =>
      nameOf(a).toLowerCase().includes(term) ||
      a.customer_key.toLowerCase().includes(term),
  ).length
})

function choose(key: string) {
  emit('update:modelValue', key)
  query.value = ''
  open.value = false
}

function clear() {
  emit('update:modelValue', '')
  query.value = ''
  open.value = false
}
</script>

<template>
  <div ref="root" class="relative">
    <label class="block">
      <span class="sr-only">{{ label }}</span>
      <input
        :value="open ? query : selected ? nameOf(selected) : ''"
        type="search"
        :placeholder="placeholder"
        autocapitalize="none"
        spellcheck="false"
        class="field"
        role="combobox"
        aria-autocomplete="list"
        :aria-expanded="open"
        @focus="
          open = true;
          query = ''
        "
        @input="
          open = true;
          query = ($event.target as HTMLInputElement).value
        "
      />
    </label>

    <button
      v-if="selected && !open"
      type="button"
      class="text-muted hover:text-ink absolute top-0 right-0 flex h-12 w-12 items-center justify-center text-lg"
      aria-label="Clear selected account"
      @click="clear"
    >
      ×
    </button>

    <div
      v-if="open"
      class="border-line bg-surface absolute inset-x-0 top-full z-20 mt-1 max-h-72 overflow-y-auto border shadow-lg"
    >
      <p v-if="matches.length === 0" class="text-muted px-4 py-3 text-sm">
        No account matches that.
      </p>
      <ul v-else role="listbox">
        <li v-for="a in matches" :key="a.customer_key">
          <button
            type="button"
            role="option"
            :aria-selected="a.customer_key === modelValue"
            class="tap-target hover:bg-canvas flex w-full flex-col justify-center px-4 py-2 text-left"
            :class="a.customer_key === modelValue ? 'bg-canvas' : ''"
            @click="choose(a.customer_key)"
          >
            <span class="text-ink truncate text-[15px] font-semibold">
              {{ nameOf(a) }}
            </span>
            <span v-if="a.customer_name" class="text-muted text-xs">
              {{ a.customer_key }}
            </span>
          </button>
        </li>
      </ul>
      <!-- A list that just stops is indistinguishable from a complete one —
           same rule AccountsView's "Showing N of M" follows. -->
      <p
        v-if="total > matches.length"
        class="border-line text-muted border-t px-4 py-2 text-xs"
      >
        Showing {{ matches.length }} of {{ total }} — keep typing to narrow.
      </p>
    </div>
  </div>
</template>
