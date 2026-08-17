<script setup lang="ts">
/**
 * Where an admin enters "view as rep". Leaving is handled by the banner in
 * the shell, which is the only control reachable once you are in — this page
 * is admin-only and `isAdmin` goes false the moment the RPC lands.
 *
 * The picker lists people, not rep codes, even though the underlying scope is
 * derived from `sales_rep_key` / `rep_group_vendor_id`. Those two keys plus
 * the grant/revoke override rows are what actually resolve a book, so a rep
 * code alone would be a lie for anyone carrying overrides or a group
 * rollup — the code is shown next to the name as context, not as the choice.
 */
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useSessionStore } from '@/stores/session'
import { repLabel, useImpersonatableProfiles } from '@/composables/useViewAs'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'

const session = useSessionStore()
const router = useRouter()
const options = useImpersonatableProfiles()

const selected = ref('')
const busy = ref(false)
const error = ref<string | null>(null)

const chosen = computed(() =>
  (options.data.value ?? []).find((p) => p.user_id === selected.value) ?? null,
)

async function start() {
  if (!selected.value) return
  busy.value = true
  error.value = null
  try {
    await session.setViewAs(selected.value)
    await router.push({ name: 'overview' })
  } catch (e) {
    error.value = (e as Error)?.message ?? 'Could not start. Try again.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <AppCard title="View as rep" hint="Read-only">
    <AsyncState
      :loading="options.isPending.value"
      :error="options.error.value"
      :empty="(options.data.value ?? []).length === 0"
      empty-body="No other active users to view as."
    >
      <div class="space-y-3">
        <p class="text-muted text-sm">
          See the Overview, Accounts and Intel exactly as this person sees
          them — their book, their goals, their follow-ups. Nothing can be
          written while you are in it.
        </p>

        <div class="flex flex-wrap items-end gap-2">
          <div class="min-w-56 flex-1">
            <label class="u-label text-muted mb-1 block" for="view-as-target">
              Person
            </label>
            <select
              id="view-as-target"
              v-model="selected"
              class="border-line bg-surface text-ink min-h-12 w-full border px-3 text-[15px]"
            >
              <option value="">Choose someone…</option>
              <option v-for="p in options.data.value ?? []" :key="p.user_id" :value="p.user_id">
                {{ repLabel(p) }}{{ p.role === 'admin' ? ' (admin)' : '' }}
              </option>
            </select>
          </div>
          <AppButton
            variant="primary"
            :disabled="!selected"
            :loading="busy"
            @click="start"
          >
            View as
          </AppButton>
        </div>

        <!-- An admin target keeps admin scope (public.is_admin() answers for
             the effective user), so say so rather than letting it look broken. -->
        <p v-if="chosen?.role === 'admin'" class="text-muted text-sm">
          {{ chosen.full_name || 'This user' }} is an admin, so this will still
          show every account — it is their view, and their view is everything.
        </p>
        <p v-else-if="chosen && !chosen.sales_rep_key && !chosen.rep_group_vendor_id"
           class="text-muted text-sm">
          {{ chosen.full_name || 'This user' }} has no rep code or rep group, so
          they resolve only accounts granted to them explicitly — often none.
        </p>

        <p v-if="error" class="text-danger text-sm">{{ error }}</p>
      </div>
    </AsyncState>
  </AppCard>
</template>
