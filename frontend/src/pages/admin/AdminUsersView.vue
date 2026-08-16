<script setup lang="ts">
/**
 * User management (PRD §7: admin-created users only). Reads and profile-field
 * edits go straight through RLS; passwords and deactivation go through the
 * admin-* Edge Functions, which re-verify the caller server-side.
 *
 * Everything opens inline — the create panel above the grid, the manage panel
 * below it. Never a modal (TECH_STACK §2.4).
 */
import { computed, ref } from 'vue'
import type { ColumnDef } from '@tanstack/vue-table'
import { useSessionStore } from '@/stores/session'
import {
  useAdminUpdateUser,
  useCreateUser,
  useProfiles,
  useUpdateProfile,
  type AdminProfile,
} from '@/composables/useAdminUsers'
import { useRepActivity } from '@/composables/useActivity'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ViewAsCard from '@/components/admin/ViewAsCard.vue'
import { ROLES, type Role } from '@/types/domain'
import { daysAgo } from '@/lib/format'

const MIN_PASSWORD_LENGTH = 12

const session = useSessionStore()
const profiles = useProfiles()
const activity = useRepActivity()

const lastLoginByUser = computed(() => {
  const map: Record<string, string | null> = {}
  for (const row of activity.data.value ?? []) {
    if (row.user_id) map[row.user_id] = row.last_login_at
  }
  return map
})

/* ---- grid --------------------------------------------------------------- */
const search = ref('')
const visibleRows = ref<AdminProfile[]>([])

const columns: ColumnDef<AdminProfile, any>[] = [
  { id: 'full_name', accessorFn: (r) => r.full_name ?? '', header: 'Name' },
  { id: 'email', accessorFn: (r) => r.email ?? '', header: 'Email' },
  { id: 'role', accessorKey: 'role', header: 'Role' },
  { id: 'sales_rep_key', accessorFn: (r) => r.sales_rep_key ?? '', header: 'Rep code' },
  {
    id: 'rep_group_vendor_id',
    accessorFn: (r) => r.rep_group_vendor_id ?? '',
    header: 'Rep group',
  },
  { id: 'last_login', accessorFn: (r) => lastLoginByUser.value[r.user_id] ?? '', header: 'Last login' },
  { id: 'manage', header: '', enableSorting: false, accessorFn: () => '' },
]

/* ---- create panel ------------------------------------------------------- */
const creating = ref(false)
const cEmail = ref('')
const cPassword = ref('')
const cFullName = ref('')
const cRole = ref<Role>('rep')
const cRepKey = ref('')
const cVendorId = ref('')
const createError = ref('')
const createWarnings = ref<string[]>([])
const createdNotice = ref('')

const create = useCreateUser()

function resetCreate() {
  cEmail.value = ''
  cPassword.value = ''
  cFullName.value = ''
  cRole.value = 'rep'
  cRepKey.value = ''
  cVendorId.value = ''
  createError.value = ''
}

async function submitCreate() {
  createError.value = ''
  createWarnings.value = []
  createdNotice.value = ''
  if (!cEmail.value.trim() || !cEmail.value.includes('@')) {
    createError.value = 'A valid email is required.'
    return
  }
  if (cPassword.value.length < MIN_PASSWORD_LENGTH) {
    createError.value = `Password needs at least ${MIN_PASSWORD_LENGTH} characters.`
    return
  }
  if (!cFullName.value.trim()) {
    createError.value = 'Full name is required.'
    return
  }
  try {
    const result = await create.mutateAsync({
      email: cEmail.value.trim(),
      password: cPassword.value,
      fullName: cFullName.value,
      role: cRole.value,
      salesRepKey: cRepKey.value || null,
      repGroupVendorId: cVendorId.value || null,
    })
    createWarnings.value = result.warnings ?? []
    createdNotice.value = `${result.email} can sign in now.`
    resetCreate()
    creating.value = false
  } catch (e) {
    createError.value = (e as Error).message
  }
}

/* ---- manage panel ------------------------------------------------------- */
const selectedId = ref<string | null>(null)
const selected = computed(
  () => (profiles.data.value ?? []).find((p) => p.user_id === selectedId.value) ?? null,
)
const isSelf = computed(() => selectedId.value === session.user?.id)

const eFullName = ref('')
const eRole = ref<Role>('rep')
const eRepKey = ref('')
const eVendorId = ref('')
const ePassword = ref('')
const manageError = ref('')
const manageNotice = ref('')
const manageWarnings = ref<string[]>([])
const confirmingDeactivate = ref(false)

const updateProfile = useUpdateProfile()
const updateUser = useAdminUpdateUser()

function manage(row: AdminProfile) {
  selectedId.value = row.user_id
  eFullName.value = row.full_name
  eRole.value = (row.role as Role) ?? 'rep'
  eRepKey.value = row.sales_rep_key ?? ''
  eVendorId.value = row.rep_group_vendor_id ?? ''
  ePassword.value = ''
  manageError.value = ''
  manageNotice.value = ''
  manageWarnings.value = []
  confirmingDeactivate.value = false
}

function closeManage() {
  selectedId.value = null
}

async function saveProfile() {
  if (!selected.value) return
  manageError.value = ''
  manageNotice.value = ''
  try {
    await updateProfile.mutateAsync({
      userId: selected.value.user_id,
      fullName: eFullName.value,
      role: eRole.value,
      salesRepKey: eRepKey.value || null,
      repGroupVendorId: eVendorId.value || null,
    })
    manageNotice.value = 'Profile saved.'
  } catch (e) {
    manageError.value = (e as Error).message
  }
}

async function savePassword() {
  if (!selected.value) return
  manageError.value = ''
  manageNotice.value = ''
  if (ePassword.value.length < MIN_PASSWORD_LENGTH) {
    manageError.value = `Password needs at least ${MIN_PASSWORD_LENGTH} characters.`
    return
  }
  try {
    await updateUser.mutateAsync({
      userId: selected.value.user_id,
      password: ePassword.value,
    })
    ePassword.value = ''
    manageNotice.value = 'Password updated.'
  } catch (e) {
    manageError.value = (e as Error).message
  }
}

async function setActive(active: boolean) {
  if (!selected.value) return
  manageError.value = ''
  manageNotice.value = ''
  manageWarnings.value = []
  try {
    const result = await updateUser.mutateAsync({
      userId: selected.value.user_id,
      active,
    })
    manageWarnings.value = result.warnings ?? []
    manageNotice.value = active ? 'Account reactivated.' : 'Account deactivated.'
    confirmingDeactivate.value = false
  } catch (e) {
    manageError.value = (e as Error).message
  }
}
</script>

<template>
  <div class="space-y-5">
    <header class="flex flex-wrap items-end justify-between gap-3">
      <div>
        <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
          Users
        </p>
        <h1 class="u-display mt-1 text-4xl">Who can sign in</h1>
        <p class="text-muted mt-2 text-[15px]">
          There is no self-signup — every account starts here.
        </p>
      </div>
      <AppButton v-if="!creating" variant="primary" @click="creating = true">
        New user
      </AppButton>
    </header>

    <!-- Directly under the user list on purpose: "who can sign in" and "what
         do they see when they do" are the same question, asked twice. -->
    <ViewAsCard />

    <!-- Create panel — inline, above the grid -->
    <AppCard v-if="creating" title="New user">
      <form class="grid gap-3 sm:grid-cols-2" @submit.prevent="submitCreate">
        <label class="block">
          <span class="u-label mb-1.5 block">Email</span>
          <input v-model="cEmail" type="email" autocomplete="off" class="field" />
        </label>
        <label class="block">
          <span class="u-label mb-1.5 block">Password</span>
          <input
            v-model="cPassword"
            type="text"
            autocomplete="new-password"
            class="field"
            :placeholder="`At least ${MIN_PASSWORD_LENGTH} characters`"
          />
        </label>
        <label class="block">
          <span class="u-label mb-1.5 block">Full name</span>
          <input v-model="cFullName" type="text" class="field" />
        </label>
        <label class="block">
          <span class="u-label mb-1.5 block">Role</span>
          <select v-model="cRole" class="field">
            <option v-for="r in ROLES" :key="r" :value="r">{{ r }}</option>
          </select>
        </label>
        <label class="block">
          <span class="u-label mb-1.5 block">
            Rep code <span class="normal-case">(their book — optional)</span>
          </span>
          <input v-model="cRepKey" type="text" class="field" placeholder="e.g. TANY MCDO" />
        </label>
        <label class="block">
          <span class="u-label mb-1.5 block">
            Rep group vendor <span class="normal-case">(principals only)</span>
          </span>
          <input v-model="cVendorId" type="text" class="field" />
        </label>

        <p
          v-if="createError"
          role="alert"
          class="text-danger text-sm font-medium sm:col-span-2"
        >
          {{ createError }}
        </p>

        <div class="flex gap-2 sm:col-span-2">
          <AppButton
            type="submit"
            variant="primary"
            :loading="create.isPending.value"
          >
            Create user
          </AppButton>
          <AppButton variant="ghost" @click="creating = false">Cancel</AppButton>
        </div>
      </form>
    </AppCard>

    <p v-if="createdNotice" role="status" class="text-ink text-sm font-medium">
      {{ createdNotice }}
    </p>
    <ul v-if="createWarnings.length" class="space-y-1">
      <li
        v-for="(w, i) in createWarnings"
        :key="i"
        class="border-l-accent text-ink-2 border-l-[3px] pl-3 text-sm"
      >
        {{ w }}
      </li>
    </ul>

    <!-- The grid -->
    <AppCard>
      <template #header>
        <div>
          <h2 class="u-label text-ink">All users</h2>
          <p class="text-muted mt-1 text-[13px]">
            {{ visibleRows.length }} {{ visibleRows.length === 1 ? 'user' : 'users' }}
          </p>
        </div>
      </template>

      <AsyncState
        :loading="profiles.isPending.value"
        :error="profiles.error.value"
        :empty="(profiles.data.value?.length ?? 0) === 0"
        empty-title="No users yet"
        empty-body="Create the first one above."
        @retry="profiles.refetch()"
      >
        <DataGrid
          v-model:globalFilter="search"
          :columns="columns"
          :data="profiles.data.value ?? []"
          :initial-sorting="[{ id: 'full_name', desc: false }]"
          searchable
          search-label="Search users"
          search-placeholder="Search users…"
          :get-row-id="(row: AdminProfile) => row.user_id"
          min-width="52rem"
          @rows-change="visibleRows = $event"
        >
          <template #cell-full_name="{ row }">
            <span class="text-ink font-semibold">{{ row.full_name || '—' }}</span>
            <AppBadge v-if="!row.active" tone="neutral" class="ml-2">Inactive</AppBadge>
          </template>
          <template #cell-email="{ row }">
            <span class="text-ink-2">{{ row.email || '—' }}</span>
          </template>
          <template #cell-role="{ row }">
            <span class="capitalize">{{ row.role }}</span>
          </template>
          <template #cell-sales_rep_key="{ row }">
            <span class="text-ink-2">{{ row.sales_rep_key || '—' }}</span>
          </template>
          <template #cell-rep_group_vendor_id="{ row }">
            <span class="text-ink-2">{{ row.rep_group_vendor_id || '—' }}</span>
          </template>
          <template #cell-last_login="{ row }">
            <span class="whitespace-nowrap">
              {{ daysAgo(lastLoginByUser[row.user_id] ?? null) }}
            </span>
          </template>
          <template #cell-manage="{ row }">
            <AppButton variant="ghost" @click="manage(row)">Manage</AppButton>
          </template>

          <!-- Phone layout -->
          <template #card="{ row }">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="text-ink truncate font-semibold">
                  {{ row.full_name || row.email || '—' }}
                  <span v-if="!row.active" class="text-muted text-[13px] font-normal">
                    (inactive)
                  </span>
                </p>
                <p class="text-muted mt-0.5 truncate text-[15px]">
                  {{ row.email || '—' }} · {{ row.role }}
                </p>
                <p class="text-muted mt-0.5 text-[13px]">
                  {{ row.sales_rep_key || 'No rep code' }} · Last login
                  {{ daysAgo(lastLoginByUser[row.user_id] ?? null) }}
                </p>
              </div>
              <AppButton variant="ghost" @click="manage(row)">Manage</AppButton>
            </div>
          </template>

          <template #empty>
            <p class="text-muted py-10 text-center text-[15px]">
              No users match that search.
            </p>
          </template>
        </DataGrid>
      </AsyncState>
    </AppCard>

    <!-- Manage panel — inline, below the grid -->
    <AppCard v-if="selected">
      <template #header>
        <div>
          <h2 class="u-label text-ink">{{ selected.full_name || selected.email }}</h2>
          <p class="text-muted mt-1 text-[13px]">{{ selected.email }}</p>
        </div>
        <AppButton variant="ghost" @click="closeManage">Close</AppButton>
      </template>

      <div class="space-y-5">
        <!-- Profile fields: plain RLS update -->
        <form class="grid gap-3 sm:grid-cols-2" @submit.prevent="saveProfile">
          <label class="block">
            <span class="u-label mb-1.5 block">Full name</span>
            <input v-model="eFullName" type="text" class="field" />
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Role</span>
            <select v-model="eRole" class="field" :disabled="isSelf">
              <option v-for="r in ROLES" :key="r" :value="r">{{ r }}</option>
            </select>
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Rep code</span>
            <input v-model="eRepKey" type="text" class="field" />
          </label>
          <label class="block">
            <span class="u-label mb-1.5 block">Rep group vendor</span>
            <input v-model="eVendorId" type="text" class="field" />
          </label>
          <div class="sm:col-span-2">
            <AppButton
              type="submit"
              variant="secondary"
              :loading="updateProfile.isPending.value"
            >
              Save profile
            </AppButton>
          </div>
        </form>

        <!-- Password: service_role path -->
        <div class="border-line border-t pt-4">
          <form
            class="flex flex-wrap items-end gap-2"
            @submit.prevent="savePassword"
          >
            <label class="block min-w-64 flex-1">
              <span class="u-label mb-1.5 block">Set a new password</span>
              <input
                v-model="ePassword"
                type="text"
                autocomplete="new-password"
                class="field"
                :placeholder="`At least ${MIN_PASSWORD_LENGTH} characters`"
              />
            </label>
            <AppButton
              type="submit"
              variant="secondary"
              :disabled="!ePassword"
              :loading="updateUser.isPending.value"
            >
              Update password
            </AppButton>
          </form>
          <p class="text-muted mt-1.5 text-[13px]">
            Tell them the new password yourself — nothing is emailed.
          </p>
        </div>

        <!-- Deactivate / reactivate, inline confirm -->
        <div class="border-line border-t pt-4">
          <template v-if="selected.active">
            <div v-if="!confirmingDeactivate">
              <AppButton
                variant="danger"
                :disabled="isSelf"
                @click="confirmingDeactivate = true"
              >
                Deactivate account
              </AppButton>
              <p v-if="isSelf" class="text-muted mt-1.5 text-[13px]">
                You can't deactivate your own account.
              </p>
            </div>
            <div v-else class="flex flex-wrap items-center gap-2">
              <p class="text-ink text-sm font-medium">
                They won't be able to sign in again until reactivated. Sure?
              </p>
              <AppButton
                variant="danger"
                :loading="updateUser.isPending.value"
                @click="setActive(false)"
              >
                Yes, deactivate
              </AppButton>
              <AppButton variant="ghost" @click="confirmingDeactivate = false">
                Keep active
              </AppButton>
            </div>
          </template>
          <AppButton
            v-else
            variant="secondary"
            :loading="updateUser.isPending.value"
            @click="setActive(true)"
          >
            Reactivate account
          </AppButton>
        </div>

        <p v-if="manageError" role="alert" class="text-danger text-sm font-medium">
          {{ manageError }}
        </p>
        <p v-if="manageNotice" role="status" class="text-ink text-sm font-medium">
          {{ manageNotice }}
        </p>
        <ul v-if="manageWarnings.length" class="space-y-1">
          <li
            v-for="(w, i) in manageWarnings"
            :key="i"
            class="border-l-accent text-ink-2 border-l-[3px] pl-3 text-sm"
          >
            {{ w }}
          </li>
        </ul>
      </div>
    </AppCard>
  </div>
</template>
