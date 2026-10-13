<script setup lang="ts">
import { computed } from 'vue'
import AccountPicker from '@/components/AccountPicker.vue'
import { useTerritoryAccounts } from '@/composables/useOverview'

/**
 * AccountPicker fed from the caller's whole book (the Overview's cached
 * territory rows), as its own component so the book is only read when a
 * picker is actually on screen. Mount it with v-if: a page that keeps the
 * picker behind a mode toggle (SkuSalesIntel's "By account") then costs no
 * request until the rep picks that mode — useTerritoryAccounts() takes no
 * `enabled`, so mounting is the gate.
 */
defineProps<{ placeholder?: string }>()
const model = defineModel<string>({ required: true })

const book = useTerritoryAccounts()
const accounts = computed(() =>
  [...(book.data.value ?? [])].sort((a, b) =>
    (a.customer_name ?? a.customer_key).localeCompare(b.customer_name ?? b.customer_key),
  ),
)
</script>

<template>
  <AccountPicker v-model="model" :accounts="accounts" :placeholder="placeholder" />
</template>
