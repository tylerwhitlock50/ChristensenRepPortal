<script setup lang="ts">
/**
 * "Email a group" on Admin › Users: choose everyone, every principal, one
 * rep group or one rep, and open a blank draft in your own mail client with
 * them on Bcc (lib/broadcast.ts). Saves copying addresses out of the grid.
 * The portal sends nothing.
 *
 * Rep group membership for a rep comes from their rep code's vendor in
 * dim_sales_rep (the same read the Missions composer makes); a principal is
 * in the group they run.
 */
import { computed, ref, watch } from 'vue'
import { useSessionStore } from '@/stores/session'
import { useProfiles } from '@/composables/useAdminUsers'
import { useSalesReps } from '@/composables/useMissions'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { emailList } from '@/lib/adoption'
import {
  bccMailto,
  isPrincipal,
  MAILTO_SAFE_LENGTH,
  recipients,
  repGroups,
  type BroadcastAudience,
} from '@/lib/broadcast'
import { count } from '@/lib/format'

const session = useSessionStore()
const profiles = useProfiles()
const salesReps = useSalesReps()

const audience = ref<BroadcastAudience>('everyone')
const groupValue = ref('')
const repValue = ref('')
const showList = ref(false)
const copied = ref(false)

const AUDIENCES: { value: BroadcastAudience; label: string }[] = [
  { value: 'everyone', label: 'Everyone' },
  { value: 'principals', label: 'Principals' },
  { value: 'group', label: 'Rep group' },
  { value: 'rep', label: 'One rep' },
]

const vendorByRepKey = computed(() => {
  const map: Record<string, string | null> = {}
  for (const r of salesReps.data.value ?? []) map[r.sales_rep_key] = r.vendor_id
  return map
})

const groups = computed(() => repGroups(profiles.data.value ?? [], vendorByRepKey.value))

/** Reps (principals included) who can be drafted at all. */
const repOptions = computed(() =>
  recipients(profiles.data.value ?? [], 'everyone', '', vendorByRepKey.value).filter(
    (p) => p.role === 'rep',
  ),
)

const rows = computed(() =>
  recipients(
    profiles.data.value ?? [],
    audience.value,
    audience.value === 'group' ? groupValue.value : repValue.value,
    vendorByRepKey.value,
  ),
)

const senderEmail = computed(() => session.user?.email ?? '')
const mailto = computed(() => bccMailto(rows.value, senderEmail.value))
const tooLong = computed(() => mailto.value.length > MAILTO_SAFE_LENGTH)

watch(audience, () => {
  showList.value = false
})

async function copy() {
  const text = emailList(rows.value)
  if (!text) return
  try {
    await navigator.clipboard.writeText(text)
    copied.value = true
    window.setTimeout(() => (copied.value = false), 2000)
  } catch {
    copied.value = false
  }
}
</script>

<template>
  <AppCard>
    <template #header>
      <div>
        <h2 class="u-label text-ink">Email a group</h2>
        <p class="text-muted mt-1 text-[13px]">
          Opens a blank draft in your own mail client with everyone on Bcc —
          you're on To. The portal sends nothing.
        </p>
      </div>
    </template>

    <AsyncState
      :loading="profiles.isPending.value || salesReps.isPending.value"
      :error="profiles.error.value ?? salesReps.error.value"
      :has-data="profiles.data.value !== undefined && salesReps.data.value !== undefined"
      @retry="profiles.refetch(); salesReps.refetch()"
    >
      <div class="space-y-4">
        <div class="flex flex-wrap items-end gap-3">
          <div class="border-line flex border" role="group" aria-label="Who to email">
            <button
              v-for="a in AUDIENCES"
              :key="a.value"
              type="button"
              class="tap-target font-label px-3 text-[13px] font-semibold tracking-[0.12em] uppercase"
              :class="audience === a.value ? 'bg-ink text-canvas' : 'text-muted'"
              :aria-pressed="audience === a.value"
              @click="audience = a.value"
            >
              {{ a.label }}
            </button>
          </div>

          <label v-if="audience === 'group'" class="block min-w-56">
            <span class="u-label mb-1.5 block">Rep group</span>
            <select v-model="groupValue" class="field">
              <option value="" disabled>Pick a group…</option>
              <option v-for="g in groups" :key="g.vendor_id" :value="g.vendor_id">
                {{ g.vendor_id }} · {{ count(g.count) }} {{ g.count === 1 ? 'person' : 'people' }}
              </option>
            </select>
          </label>

          <label v-if="audience === 'rep'" class="block min-w-56">
            <span class="u-label mb-1.5 block">Rep</span>
            <select v-model="repValue" class="field">
              <option value="" disabled>Pick a rep…</option>
              <option v-for="r in repOptions" :key="r.user_id" :value="r.user_id">
                {{ r.full_name || r.email }}{{ isPrincipal(r) ? ` (principal, ${r.rep_group_vendor_id})` : '' }}
              </option>
            </select>
          </label>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <a
            v-if="rows.length > 0"
            :href="mailto"
            class="tap-target font-label text-ink border-ink hover:bg-ink hover:text-canvas inline-flex min-h-12 items-center rounded-[2px] border-[1.5px] px-4 text-[15px] font-semibold tracking-[0.12em] uppercase transition-colors"
          >
            Draft the email
          </a>
          <AppButton variant="ghost" :disabled="rows.length === 0" @click="copy">
            {{ copied ? 'Copied' : 'Copy emails' }}
          </AppButton>
          <button
            v-if="rows.length > 0"
            type="button"
            class="text-ink-2 text-[13px] underline underline-offset-2"
            @click="showList = !showList"
          >
            {{ showList ? 'Hide' : 'Show' }} {{ count(rows.length) }}
            {{ rows.length === 1 ? 'recipient' : 'recipients' }}
          </button>
          <p v-else class="text-muted text-[13px]">
            {{ audience === 'group' || audience === 'rep' ? 'Pick one above.' : 'Nobody active with an email.' }}
          </p>
        </div>

        <p
          v-if="tooLong"
          class="border-l-accent text-ink-2 border-l-[3px] pl-3 text-sm"
        >
          That's a long list — some mail clients cut a draft link this size
          short. If Bcc comes up incomplete, use "Copy emails" and paste into Bcc.
        </p>

        <ul v-if="showList" class="divide-line -mx-1 divide-y">
          <li
            v-for="r in rows"
            :key="r.user_id"
            class="flex flex-wrap items-baseline gap-x-3 px-1 py-2 text-[15px]"
          >
            <span class="text-ink font-semibold">{{ r.full_name || '—' }}</span>
            <span class="text-ink-2 break-all">{{ r.email }}</span>
            <span class="text-muted text-[13px] capitalize">
              {{ isPrincipal(r) ? 'principal' : r.role?.replace('_', ' ') }}
            </span>
          </li>
        </ul>
      </div>
    </AsyncState>
  </AppCard>
</template>
