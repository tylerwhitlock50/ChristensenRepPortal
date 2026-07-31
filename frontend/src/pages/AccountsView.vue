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
      <h1 class="text-2xl font-semibold tracking-tight text-zinc-900">
        Accounts
      </h1>
      <span v-if="total" class="text-sm text-zinc-500 tabular-nums">
        {{ fmtCount(total) }}
      </span>
    </header>

    <div class="space-y-2">
      <label class="block">
        <span class="sr-only">Search accounts</span>
        <input
          v-model="search"
          type="search"
          placeholder="Search by name, city, or number"
          autocapitalize="none"
          spellcheck="false"
          class="tap-target w-full rounded-lg border border-zinc-300 bg-white px-3 outline-none focus:border-zinc-900"
        />
      </label>

      <label class="tap-target flex items-center gap-2 text-sm text-zinc-600">
        <input
          v-model="activeOnly"
          type="checkbox"
          class="size-4 rounded border-zinc-300"
        />
        Active accounts only
      </label>
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
      <ul
        class="divide-y divide-zinc-100 overflow-hidden rounded-xl border border-zinc-200 bg-white"
      >
        <li v-for="a in rows" :key="a.customer_key">
          <RouterLink
            :to="{ name: 'account', params: { customerKey: a.customer_key } }"
            class="tap-target flex items-center gap-3 px-4 py-3 hover:bg-zinc-50"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate font-medium text-zinc-900">
                {{ a.customer_name || a.customer_key }}
              </p>
              <p class="truncate text-sm text-zinc-500">
                <template v-if="place(a)">{{ place(a) }} · </template>
                Last order {{ daysAgo(a.last_order_date) }}
              </p>
            </div>
            <svg
              class="size-4 shrink-0 text-zinc-400"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              aria-hidden="true"
            >
              <path d="M9 18l6-6-6-6" />
            </svg>
          </RouterLink>
        </li>
      </ul>

      <!-- Always says how much of the result set is on screen; a paged list
           that just stops is indistinguishable from a complete one. -->
      <div class="mt-4 text-center">
        <p class="text-sm text-zinc-500 tabular-nums">
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
