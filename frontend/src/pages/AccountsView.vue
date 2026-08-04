<script setup lang="ts">
import { computed, ref } from 'vue'
import { refDebounced } from '@vueuse/core'
import { useAccountSearch } from '@/composables/useAccounts'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { count as fmtCount, daysAgo, humanize } from '@/lib/format'

const search = ref('')
// Every keystroke would otherwise be a round trip over LTE.
const debouncedSearch = refDebounced(search, 300)
const activeOnly = ref(true)

const {
  data,
  isPending,
  error,
  refetch,
  fetchNextPage,
  hasNextPage,
  isFetchingNextPage,
} = useAccountSearch(debouncedSearch, activeOnly)

const rows = computed(() => data.value?.pages.flatMap((p) => p.rows) ?? [])
const total = computed(() => data.value?.pages[0]?.total ?? 0)

function place(a: { sold_to_city: string | null; sold_to_state: string | null }) {
  return [humanize(a.sold_to_city), a.sold_to_state]
    .filter((v) => v && v !== '—')
    .join(', ')
}
</script>

<template>
  <div class="space-y-4">
    <header class="flex items-baseline justify-between gap-3">
      <h1 class="u-display text-[34px]">Accounts</h1>
      <span
        v-if="total"
        class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase tabular-nums"
      >
        {{ fmtCount(total) }} in book
      </span>
    </header>

    <div class="space-y-2.5">
      <label class="block">
        <span class="sr-only">Search accounts</span>
        <input
          v-model="search"
          type="search"
          placeholder="Name, city, or customer #"
          autocapitalize="none"
          spellcheck="false"
          class="field"
        />
      </label>

      <!-- Filter chip, not a checkbox — thumb-sized, glove-proof. -->
      <button
        type="button"
        class="tap-target font-label inline-flex items-center px-4 text-[13px] font-semibold tracking-[0.1em] uppercase"
        :class="
          activeOnly
            ? 'bg-ink text-canvas'
            : 'border-line-2 text-ink-2 border bg-transparent'
        "
        :aria-pressed="activeOnly"
        @click="activeOnly = !activeOnly"
      >
        Active only
      </button>
    </div>

    <AsyncState
      :loading="isPending"
      :error="error"
      :empty="rows.length === 0"
      :empty-title="search ? 'No matches' : 'No accounts assigned yet'"
      :empty-body="
        search
          ? 'Try a shorter search, or turn off the active-only filter.'
          : 'Your book comes from the ERP. If this is empty, ask your admin to check your rep code.'
      "
      :rows="6"
      @retry="refetch()"
    >
      <ul class="divide-line border-line bg-surface divide-y border">
        <li v-for="a in rows" :key="a.customer_key">
          <RouterLink
            :to="{ name: 'account', params: { customerKey: a.customer_key } }"
            class="tap-target hover:bg-canvas flex flex-col justify-center gap-1 px-4 py-3.5"
          >
            <span class="flex items-baseline justify-between gap-3">
              <!-- The ID is the disambiguator — a book has many "GUN SHOP"s.
                   It sits outside the truncating name span so a long name
                   clips itself rather than the one field that tells two
                   look-alike accounts apart. -->
              <span class="flex min-w-0 items-baseline gap-1.5">
                <span class="text-ink truncate text-[17px] font-semibold">
                  {{ a.customer_name || a.customer_key }}
                </span>
                <span
                  v-if="a.customer_name"
                  class="text-muted shrink-0 text-[13px] font-medium"
                >
                  ({{ a.customer_key }})
                </span>
              </span>
              <!-- The rep's own write-off outranks the ERP flag: an account
                   can be both, and "you deactivated this" is the label that
                   explains why it's off the default list. -->
              <span
                v-if="a.deactivated_at"
                class="border-line text-muted font-label shrink-0 border px-1.5 py-0.5 text-[11px] font-semibold tracking-[0.1em] uppercase"
              >
                Deactivated
              </span>
              <span
                v-else-if="a.active_flag !== 'Y'"
                class="border-line text-muted font-label shrink-0 border px-1.5 py-0.5 text-[11px] font-semibold tracking-[0.1em] uppercase"
              >
                Inactive
              </span>
            </span>
            <span class="text-muted truncate text-sm">
              <template v-if="place(a)">{{ place(a) }} · </template>
              Last order {{ daysAgo(a.last_order_date) }}
            </span>
          </RouterLink>
        </li>
      </ul>

      <!-- Always says how much of the result set is on screen; a paged list
           that just stops is indistinguishable from a complete one. -->
      <div class="mt-4 text-center">
        <p class="font-label text-muted text-xs font-semibold tracking-[0.12em] uppercase tabular-nums">
          Showing {{ fmtCount(rows.length) }} of {{ fmtCount(total) }}
        </p>
        <AppButton
          v-if="hasNextPage"
          variant="secondary"
          class="mt-2"
          :loading="isFetchingNextPage"
          @click="fetchNextPage()"
        >
          Load more
        </AppButton>
      </div>
    </AsyncState>
  </div>
</template>
