<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import { useProfiles } from '@/composables/useAdminUsers'
import {
  useAddMcpOrderUser,
  useMcpOrderUsers,
  useRemoveMcpOrderUser,
} from '@/composables/useMcpOrderUsers'
import { daysAgo } from '@/lib/format'

/**
 * Who may have Claude draft orders: the public.mcp_order_users table, one
 * row per person, no "everyone". Admin only — rendered from FeatureFlagsCard
 * under the feature.mcp_orders switch. Adds and removes apply immediately
 * (no Save); the server re-checks the table on every MCP request, so a
 * removal takes effect on that person's next call. The switch and this list
 * are separate on purpose: the flag on with nobody listed means nobody drafts.
 */
const list = useMcpOrderUsers()
const profiles = useProfiles()
const add = useAddMcpOrderUser()
const remove = useRemoveMcpOrderUser()

const pick = ref('')
const note = ref('')
const error = ref('')
const removingId = ref('')

const rows = computed(() => list.data.value ?? [])

/** Active people not already on the list, by name. */
const candidates = computed(() => {
  const listed = new Set(rows.value.map((r) => r.user_id))
  return (profiles.data.value ?? [])
    .filter((p) => p.active && !listed.has(p.user_id))
    .map((p) => ({
      id: p.user_id,
      label: [p.full_name || p.email || p.user_id, p.role].filter(Boolean).join(' · '),
    }))
})

async function addPerson() {
  if (!pick.value) return
  error.value = ''
  try {
    await add.mutateAsync({ userId: pick.value, note: note.value })
    pick.value = ''
    note.value = ''
  } catch (e) {
    error.value = (e as Error).message || 'Could not add that person.'
  }
}

async function removePerson(userId: string) {
  error.value = ''
  removingId.value = userId
  try {
    await remove.mutateAsync(userId)
  } catch (e) {
    error.value = (e as Error).message || 'Could not remove that person.'
  } finally {
    removingId.value = ''
  }
}
</script>

<template>
  <div class="bg-canvas border-line space-y-3 border-t px-4 py-3">
    <div>
      <p class="u-label text-ink">Who can have Claude draft orders</p>
      <p class="text-muted pt-1 text-xs">
        Nobody drafts until they are added here. Changes apply straight away.
        Drafts are never submitted by Claude — a person reviews and submits
        each one in the portal.
      </p>
    </div>

    <p v-if="list.isLoading.value" class="text-muted text-sm">Loading the list…</p>
    <p v-else-if="list.isError.value" role="alert" class="text-danger text-sm">
      Couldn't load the list.
      <button type="button" class="underline" @click="list.refetch()">Try again</button>
    </p>
    <p v-else-if="rows.length === 0" class="text-muted text-sm">Nobody is on the list.</p>
    <ul v-else class="divide-line border-line bg-surface divide-y border">
      <li
        v-for="r in rows"
        :key="r.user_id"
        class="flex min-h-11 items-center justify-between gap-3 px-3 py-2"
      >
        <span class="min-w-0">
          <span class="text-ink block truncate text-[15px]">
            {{ r.full_name || r.email || r.user_id }}
            <span v-if="!r.active" class="text-danger text-xs font-semibold">
              (inactive — refused)
            </span>
          </span>
          <span class="text-muted block truncate text-xs">
            {{
              [
                r.email,
                `Added ${daysAgo(r.added_at)}${r.added_by_name ? ` by ${r.added_by_name}` : ''}`,
                r.note,
              ]
                .filter(Boolean)
                .join(' · ')
            }}
          </span>
        </span>
        <AppButton
          variant="ghost"
          :loading="removingId === r.user_id"
          :disabled="!!removingId"
          :aria-label="`Remove ${r.full_name || r.email || r.user_id} from order drafting`"
          @click="removePerson(r.user_id)"
        >
          Remove
        </AppButton>
      </li>
    </ul>

    <div class="flex flex-wrap items-end gap-2">
      <label class="block min-w-56 flex-1">
        <span class="u-label mb-1.5 block">Add a person</span>
        <select v-model="pick" class="field" :disabled="profiles.isLoading.value">
          <option value="" disabled>
            {{ profiles.isLoading.value ? 'Loading users…' : 'Pick a person…' }}
          </option>
          <option v-for="c in candidates" :key="c.id" :value="c.id">{{ c.label }}</option>
        </select>
      </label>
      <label class="block min-w-40 flex-1">
        <span class="u-label mb-1.5 block">Note (optional)</span>
        <input v-model="note" type="text" maxlength="200" class="field" />
      </label>
      <AppButton :loading="add.isPending.value" :disabled="!pick" @click="addPerson">
        Add
      </AppButton>
    </div>
    <p v-if="profiles.isError.value" role="alert" class="text-danger text-sm">
      Couldn't load users.
      <button type="button" class="underline" @click="profiles.refetch()">Try again</button>
    </p>
    <p v-if="error" role="alert" class="text-danger text-sm font-medium">{{ error }}</p>
  </div>
</template>
