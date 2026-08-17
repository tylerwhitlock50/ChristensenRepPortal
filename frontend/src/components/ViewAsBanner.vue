<script setup lang="ts">
/**
 * The "you are not seeing your own data" bar.
 *
 * Deliberately loud and deliberately always mounted in the shell. The whole
 * point of view-as is that every number on every page changes meaning, and
 * an admin who forgets they are in it will read a rep's territory as the
 * company's. The accent stripe is the same one the wordmark uses, so it
 * reads as part of the chrome rather than as an error state — this is a mode,
 * not a failure.
 *
 * It also carries the picker, because switching targets is the common case
 * and the admin routes are (correctly) unreachable while a rep is being
 * viewed: `isAdmin` is false, so the guard turns /admin away.
 */
import { computed, ref } from 'vue'
import { useRouter } from 'vue-router'
import { useSessionStore } from '@/stores/session'
import { repLabel, useImpersonatableProfiles } from '@/composables/useViewAs'

const session = useSessionStore()
const router = useRouter()
// Only while the bar is actually up — this component is mounted on every
// page so the shell can react instantly, but it renders nothing most of the
// time and should not be fetching then either.
const options = useImpersonatableProfiles(computed(() => session.isViewingAs))

const busy = ref(false)
const error = ref<string | null>(null)

const label = computed(() => {
  const a = session.acting
  if (!a) return ''
  return repLabel({
    full_name: a.target_full_name,
    sales_rep_key: a.target_sales_rep_key,
    rep_group_vendor_id: a.target_rep_group_vendor_id,
  })
})

async function switchTo(event: Event) {
  const next = (event.target as HTMLSelectElement).value
  if (!next || next === session.acting?.target_user_id) return
  await run(() => session.setViewAs(next))
}

async function exit() {
  await run(async () => {
    await session.setViewAs(null)
    // Land somewhere that exists for an admin rather than leaving them on a
    // rep-scoped account page that their own book may not contain.
    await router.push({ name: 'overview' })
  })
}

async function run(fn: () => Promise<unknown>) {
  busy.value = true
  error.value = null
  try {
    await fn()
  } catch (e) {
    error.value = (e as Error)?.message ?? 'That did not work. Try again.'
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div
    v-if="session.isViewingAs"
    class="bg-ink-2 text-canvas border-accent border-b-2"
    role="status"
  >
    <div class="mx-auto flex max-w-7xl flex-wrap items-center gap-x-3 gap-y-2 px-4 py-2">
      <span class="bg-accent block h-4 w-[3px] shrink-0" aria-hidden="true" />
      <p class="font-label text-[13px] font-semibold tracking-[0.1em] uppercase">
        Viewing as {{ label }}
      </p>
      <span class="text-[13px] text-[#C9C5BB]">Read-only</span>

      <div class="ml-auto flex items-center gap-2">
        <label class="sr-only" for="view-as-switch">Switch to another rep</label>
        <select
          id="view-as-switch"
          class="border-line/40 bg-ink text-canvas min-h-9 max-w-52 truncate border px-2 text-[13px]"
          :disabled="busy"
          :value="session.acting?.target_user_id ?? ''"
          @change="switchTo"
        >
          <option
            v-for="p in options.data.value ?? []"
            :key="p.user_id"
            :value="p.user_id"
          >
            {{ repLabel(p) }}
          </option>
        </select>
        <button
          type="button"
          class="font-label border-canvas hover:bg-canvas hover:text-ink min-h-9 border px-3 text-[13px] font-semibold tracking-[0.1em] uppercase disabled:opacity-50"
          :disabled="busy"
          @click="exit"
        >
          Exit
        </button>
      </div>

      <p v-if="error" class="text-accent w-full text-[13px]">{{ error }}</p>
    </div>
  </div>
</template>
