<script setup lang="ts">
import { computed } from 'vue'
import { useCoverage, useRepExecution } from '@/composables/useAdmin'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import StatTile from '@/components/ui/StatTile.vue'
import { daysAgo } from '@/lib/format'

const reps = useRepExecution()
const coverage = useCoverage()

const rows = computed(() => coverage.data.value ?? [])
const contacted = computed(() => rows.value.filter((r) => r.contacted_last_30d).length)
const coveragePct = computed(() =>
  rows.value.length ? Math.round((contacted.value / rows.value.length) * 100) : 0,
)
const untouched = computed(() => rows.value.filter((r) => !r.contacted_last_30d))
</script>

<template>
  <div class="space-y-6">
    <header>
      <h1 class="text-2xl font-semibold tracking-tight text-zinc-900">
        Execution
      </h1>
      <p class="mt-1 text-sm text-zinc-500">
        Coverage and follow-through across the field, rolling 30 days.
      </p>
    </header>

    <div class="grid grid-cols-3 gap-3">
      <StatTile
        label="Coverage"
        :value="`${coveragePct}%`"
        sub="contacted in 30d"
      />
      <StatTile label="Accounts" :value="rows.length" />
      <StatTile
        label="Untouched"
        :value="untouched.length"
        :tone="untouched.length > 0 ? 'alert' : 'default'"
      />
    </div>

    <AppCard title="By rep">
      <AsyncState
        :loading="reps.isPending.value"
        :error="reps.error.value"
        :empty="(reps.data.value?.length ?? 0) === 0"
        empty-title="No reps yet"
        empty-body="Create users in Supabase Auth, then set their sales_rep_key on the profile."
        @retry="reps.refetch()"
      >
        <div class="-mx-4 overflow-x-auto px-4">
          <table class="w-full min-w-lg text-sm">
            <thead>
              <tr class="border-b border-zinc-200 text-left text-xs text-zinc-500 uppercase">
                <th class="py-2 pr-3 font-medium">Rep</th>
                <th class="py-2 pr-3 font-medium">Accounts</th>
                <th class="py-2 pr-3 font-medium">Open</th>
                <th class="py-2 pr-3 font-medium">Overdue</th>
                <th class="py-2 pr-3 font-medium">Actions 30d</th>
                <th class="py-2 pr-3 font-medium">Last login</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-100">
              <tr v-for="r in reps.data.value" :key="r.user_id ?? r.full_name!">
                <td class="py-2.5 pr-3 font-medium text-zinc-900">
                  {{ r.full_name }}
                  <span v-if="!r.active" class="text-xs text-zinc-400">
                    (inactive)
                  </span>
                </td>
                <td class="py-2.5 pr-3 tabular-nums">{{ r.assigned_accounts }}</td>
                <td class="py-2.5 pr-3 tabular-nums">{{ r.open_recommendations }}</td>
                <td
                  class="py-2.5 pr-3 tabular-nums"
                  :class="(r.overdue_recommendations ?? 0) > 0 ? 'text-red-600 font-medium' : ''"
                >
                  {{ r.overdue_recommendations }}
                </td>
                <td class="py-2.5 pr-3 tabular-nums">{{ r.actions_last_30d }}</td>
                <td class="py-2.5 pr-3 text-zinc-500">
                  {{ daysAgo(r.last_login_at) }}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </AsyncState>
    </AppCard>

    <AppCard
      title="Untouched accounts"
      :hint="`${untouched.length} not contacted in 30 days`"
    >
      <AsyncState
        :loading="coverage.isPending.value"
        :error="coverage.error.value"
        :empty="untouched.length === 0"
        empty-title="Every account has been contacted"
        empty-body="Nothing has gone 30 days without a logged contact."
        @retry="coverage.refetch()"
      >
        <ul class="divide-y divide-zinc-100">
          <li
            v-for="row in untouched.slice(0, 200)"
            :key="`${row.customer_key}-${row.user_id}`"
            class="py-2.5 first:pt-0"
          >
            <RouterLink
              :to="{ name: 'account', params: { customerKey: row.customer_key! } }"
              class="flex items-center justify-between gap-3"
            >
              <span class="min-w-0">
                <span class="block truncate font-medium text-zinc-900">
                  {{ row.customer_key }}
                </span>
                <span class="block truncate text-sm text-zinc-500">
                  {{ row.rep_name }}
                </span>
              </span>
              <span class="shrink-0 text-sm text-zinc-500">
                {{ daysAgo(row.last_contact_date) }}
              </span>
            </RouterLink>
          </li>
        </ul>
        <p
          v-if="untouched.length > 200"
          class="pt-3 text-xs text-zinc-500"
        >
          Showing the 200 longest-untouched of {{ untouched.length }}. CSV export
          is on the P1 list.
        </p>
      </AsyncState>
    </AppCard>
  </div>
</template>
