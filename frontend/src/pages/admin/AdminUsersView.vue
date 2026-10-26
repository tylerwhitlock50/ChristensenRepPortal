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
  generatePassword,
  useAdminUpdateUser,
  useCreateUser,
  useProfiles,
  useUnmappedReps,
  useUpdateProfile,
  type AdminProfile,
  type UnmappedRep,
} from '@/composables/useAdminUsers'
import { useRepActivity } from '@/composables/useActivity'
import DataGrid from '@/components/DataGrid.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ViewAsCard from '@/components/admin/ViewAsCard.vue'
import { ROLES, type Role } from '@/types/domain'
import { count, daysAgo, humanize } from '@/lib/format'

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
  { id: 'last_login', accessorFn: (r) => lastLoginByUser.value[r.user_id] ?? '', header: 'Last active' },
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

function regeneratePassword() {
  cPassword.value = generatePassword()
}

/* ---- reps without an account -------------------------------------------- */
const unmapped = useUnmappedReps()
const showIdleReps = ref(false)

/** Placeholders are never people; reps with no accounts are hidden until asked. */
const unmappedRows = computed(() => {
  const rows = (unmapped.data.value ?? []).filter((r) => !r.is_placeholder)
  return showIdleReps.value ? rows : rows.filter((r) => r.customer_count > 0)
})
const idleRepCount = computed(
  () =>
    (unmapped.data.value ?? []).filter((r) => !r.is_placeholder && r.customer_count === 0)
      .length,
)

/** Why a row's "Create account" is unavailable, or null when it is fine. */
function repBlocker(rep: UnmappedRep): string | null {
  if (rep.email_profile_user_id) {
    return `${rep.email_profile_name || 'An existing user'} already has this email — set the rep code on that user instead.`
  }
  if (!rep.sales_rep_email) return 'No email in the ERP — add one there, or create the user by hand.'
  return null
}

function existingProfileFor(rep: UnmappedRep): AdminProfile | null {
  if (!rep.email_profile_user_id) return null
  return (
    (profiles.data.value ?? []).find((p) => p.user_id === rep.email_profile_user_id) ?? null
  )
}

/** Opens the create panel with everything the ERP already knows filled in. */
function startFromRep(rep: UnmappedRep) {
  cEmail.value = rep.sales_rep_email ?? ''
  cFullName.value = humanize(rep.sales_rep_name) || rep.sales_rep_key
  cRole.value = 'rep'
  cRepKey.value = rep.sales_rep_key
  cVendorId.value = ''
  cPassword.value = generatePassword()
  createError.value = ''
  createdCredentials.value = null
  creating.value = true
}

/* ---- the one-time credentials hand-off ---------------------------------- */
interface IssuedCredentials {
  email: string
  password: string
  fullName: string
}
const createdCredentials = ref<IssuedCredentials | null>(null)
const copiedCredentials = ref(false)

const credentialsText = computed(() => {
  const c = createdCredentials.value
  if (!c) return ''
  return [
    `Sign in: ${window.location.origin}`,
    `Email: ${c.email}`,
    `Temporary password: ${c.password}`,
  ].join('\n')
})

/** A mailto: draft the admin sends from their own mail client — nothing is
 *  emailed by the app (there is no mailer, and Outlook's link scanner would
 *  eat a one-shot link anyway). */
const credentialsMailto = computed(() => {
  const c = createdCredentials.value
  if (!c) return ''
  const firstName = c.fullName.trim().split(/\s+/)[0] || 'there'
  const subject = 'Your Christensen Arms sales portal login'
  const body =
    `Hi ${firstName},\n\n` +
    `Your sales portal account is ready.\n\n` +
    `${credentialsText.value}\n\n` +
    `Please change the password after your first sign-in — it's under Help in the portal.\n`
  return `mailto:${encodeURIComponent(c.email)}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`
})

async function copyCredentials() {
  if (!credentialsText.value) return
  try {
    await navigator.clipboard.writeText(credentialsText.value)
    copiedCredentials.value = true
    window.setTimeout(() => (copiedCredentials.value = false), 2000)
  } catch {
    copiedCredentials.value = false
  }
}

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
    // order_entry owns no book (constraint order_entry_empty_book) — never
    // send scope fields for one, whatever the (hidden) inputs still hold.
    const isEntry = cRole.value === 'order_entry'
    const result = await create.mutateAsync({
      email: cEmail.value.trim(),
      password: cPassword.value,
      fullName: cFullName.value,
      role: cRole.value,
      salesRepKey: isEntry ? null : cRepKey.value || null,
      repGroupVendorId: isEntry ? null : cVendorId.value || null,
    })
    createWarnings.value = result.warnings ?? []
    createdNotice.value = `${result.email} can sign in now.`
    // Shown once, here, and nowhere else: the password is not stored
    // anywhere readable after this.
    createdCredentials.value = {
      email: result.email,
      password: cPassword.value,
      fullName: cFullName.value,
    }
    copiedCredentials.value = false
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
    // Switching someone to order_entry clears their book — leaving the old
    // rep code on the row would trip order_entry_empty_book (and, before
    // that constraint, would have silently kept their account access alive).
    const isEntry = eRole.value === 'order_entry'
    await updateProfile.mutateAsync({
      userId: selected.value.user_id,
      fullName: eFullName.value,
      role: eRole.value,
      salesRepKey: isEntry ? null : eRepKey.value || null,
      repGroupVendorId: isEntry ? null : eVendorId.value || null,
    })
    if (isEntry) {
      eRepKey.value = ''
      eVendorId.value = ''
    }
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
          <span class="flex gap-2">
            <input
              v-model="cPassword"
              type="text"
              autocomplete="new-password"
              class="field min-w-0 flex-1 font-mono"
              :placeholder="`At least ${MIN_PASSWORD_LENGTH} characters`"
            />
            <AppButton variant="secondary" @click="regeneratePassword">Generate</AppButton>
          </span>
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
        <template v-if="cRole !== 'order_entry'">
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
        </template>
        <p v-else class="text-muted text-[13px] sm:col-span-2">
          Order entry users have no account book — they see the entry queue,
          not accounts, so there is no rep code to set.
        </p>

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

    <!-- The password, exactly once. Closing this is the only way it goes away. -->
    <AppCard v-if="createdCredentials">
      <template #header>
        <div>
          <h2 class="u-label text-ink">Send them their login</h2>
          <p class="text-muted mt-1 text-[13px]">
            {{ createdCredentials.fullName }} · shown once — it is not stored anywhere
            you can read it back from.
          </p>
        </div>
        <AppButton variant="ghost" @click="createdCredentials = null">Done</AppButton>
      </template>
      <dl class="grid gap-x-6 gap-y-2 text-[15px] sm:grid-cols-[auto_1fr]">
        <dt class="u-label">Email</dt>
        <dd class="text-ink break-all">{{ createdCredentials.email }}</dd>
        <dt class="u-label">Password</dt>
        <dd class="text-ink font-mono break-all select-all">{{ createdCredentials.password }}</dd>
      </dl>
      <div class="mt-4 flex flex-wrap items-center gap-2">
        <AppButton variant="primary" @click="copyCredentials">
          {{ copiedCredentials ? 'Copied' : 'Copy login details' }}
        </AppButton>
        <a
          :href="credentialsMailto"
          class="tap-target font-label text-ink border-ink hover:bg-ink hover:text-canvas inline-flex min-h-12 items-center rounded-[2px] border-[1.5px] px-4 text-[15px] font-semibold tracking-[0.12em] uppercase transition-colors"
        >
          Draft the email
        </a>
        <p class="text-muted text-[13px]">
          Opens in your own mail client — the portal sends nothing.
        </p>
      </div>
    </AppCard>

    <!-- Reps the ERP knows that the portal doesn't -->
    <AppCard>
      <template #header>
        <div>
          <h2 class="u-label text-ink">Reps without an account</h2>
          <p class="text-muted mt-1 text-[13px]">
            Rep codes in the ERP that no user carries. Create the account from
            the row and the email, name and rep code are filled in for you.
          </p>
        </div>
        <AppButton
          v-if="idleRepCount > 0"
          variant="ghost"
          @click="showIdleReps = !showIdleReps"
        >
          {{ showIdleReps ? 'Hide' : 'Show' }} {{ idleRepCount }} with no accounts
        </AppButton>
      </template>

      <AsyncState
        :loading="unmapped.isPending.value"
        :error="unmapped.error.value"
        :has-data="unmapped.data.value !== undefined"
        :updated-at="unmapped.dataUpdatedAt.value"
        :empty="unmappedRows.length === 0"
        empty-title="Everyone is mapped"
        :empty-body="
          idleRepCount > 0
            ? 'Every rep with accounts has a user. The rest have no accounts in the ERP.'
            : 'Every rep code in the ERP is on a user.'
        "
        @retry="unmapped.refetch()"
      >
        <ul class="divide-line -mx-1 divide-y">
          <li
            v-for="rep in unmappedRows"
            :key="rep.sales_rep_key"
            class="flex flex-wrap items-center gap-x-4 gap-y-2 px-1 py-3"
          >
            <div class="min-w-0 flex-1 basis-56">
              <p class="text-ink truncate font-semibold">
                {{ humanize(rep.sales_rep_name) || rep.sales_rep_key }}
              </p>
              <p class="text-muted mt-0.5 text-[13px]">
                {{ rep.sales_rep_key }}
                <template v-if="rep.sales_rep_type"> · {{ rep.sales_rep_type }}</template>
                · {{ count(rep.customer_count) }}
                {{ rep.customer_count === 1 ? 'account' : 'accounts' }}
              </p>
            </div>
            <div class="min-w-0 flex-1 basis-56">
              <p v-if="rep.sales_rep_email" class="text-ink-2 truncate text-[15px]">
                {{ rep.sales_rep_email }}
              </p>
              <p v-else class="text-muted text-[15px]">No email in the ERP</p>
              <p v-if="repBlocker(rep)" class="text-muted mt-0.5 text-[13px]">
                {{ repBlocker(rep) }}
              </p>
            </div>
            <div class="shrink-0">
              <AppButton
                v-if="rep.email_profile_user_id && existingProfileFor(rep)"
                variant="ghost"
                @click="manage(existingProfileFor(rep)!)"
              >
                Open that user
              </AppButton>
              <AppButton
                v-else
                variant="secondary"
                :disabled="repBlocker(rep) !== null"
                @click="startFromRep(rep)"
              >
                Create account
              </AppButton>
            </div>
          </li>
        </ul>
      </AsyncState>
    </AppCard>

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
        :has-data="profiles.data.value !== undefined"
        :updated-at="profiles.dataUpdatedAt.value"
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
                  {{ row.sales_rep_key || 'No rep code' }} · Last active
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
          <template v-if="eRole !== 'order_entry'">
            <label class="block">
              <span class="u-label mb-1.5 block">Rep code</span>
              <input v-model="eRepKey" type="text" class="field" />
            </label>
            <label class="block">
              <span class="u-label mb-1.5 block">Rep group vendor</span>
              <input v-model="eVendorId" type="text" class="field" />
            </label>
          </template>
          <p v-else class="text-muted text-[13px] sm:col-span-2">
            Order entry users have no account book — saving clears any rep
            code or rep group this profile carried.
          </p>
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
