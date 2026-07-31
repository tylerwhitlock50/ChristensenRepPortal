<script setup lang="ts">
import { computed, ref } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ContactForm from '@/components/ContactForm.vue'
import {
  useCanDeleteContacts,
  useContacts,
  useDeleteContact,
  type Contact,
} from '@/composables/useContacts'

const props = defineProps<{ customerKey: string }>()

const key = computed(() => props.customerKey)
const contacts = useContacts(key)
const rows = computed(() => contacts.data.value ?? [])

/* ---- inline add / edit / delete ----------------------------------------
   One panel open at a time, always in place. No modals (TECH_STACK §2.4) —
   a sheet that covers the account is the wrong thing on a phone in a store.
------------------------------------------------------------------------ */
const adding = ref(false)
const editingId = ref<number | null>(null)
const confirmingDeleteId = ref<number | null>(null)
const deleteError = ref('')

const canDelete = useCanDeleteContacts()
const remove = useDeleteContact()

function startAdd() {
  adding.value = true
  editingId.value = null
  confirmingDeleteId.value = null
  deleteError.value = ''
}

function startEdit(contact: Contact) {
  editingId.value = contact.id
  adding.value = false
  confirmingDeleteId.value = null
  deleteError.value = ''
}

function closePanels() {
  adding.value = false
  editingId.value = null
  confirmingDeleteId.value = null
}

function askDelete(contact: Contact) {
  confirmingDeleteId.value = contact.id
  deleteError.value = ''
}

async function confirmDelete(contact: Contact) {
  deleteError.value = ''
  try {
    await remove.mutateAsync({ id: contact.id, customerKey: props.customerKey })
    confirmingDeleteId.value = null
  } catch (e) {
    deleteError.value = (e as Error).message || 'Could not delete that contact.'
  }
}

/** Title · phone · email, minus whatever is missing. */
function subtitle(contact: Contact): string {
  return [contact.title, contact.phone, contact.email].filter(Boolean).join(' · ')
}

function telHref(phone: string): string {
  return `tel:${phone.replace(/[^\d+;,*#]/g, '')}`
}
</script>

<template>
  <AppCard padded>
    <template #header>
      <div>
        <h2 class="text-sm font-semibold tracking-tight text-zinc-900">Contacts</h2>
        <p class="text-xs text-zinc-500">
          {{ rows.length === 1 ? '1 person' : `${rows.length} people` }}
        </p>
      </div>
      <AppButton v-if="!adding" variant="secondary" @click="startAdd">
        Add contact
      </AppButton>
    </template>

    <ContactForm
      v-if="adding"
      :customer-key="customerKey"
      class="mb-4"
      @saved="closePanels"
      @cancel="closePanels"
    />

    <AsyncState
      :loading="contacts.isPending.value"
      :error="contacts.error.value"
      :empty="rows.length === 0 && !adding"
      empty-title="No contacts yet"
      empty-body="Add the buyer's name and number so the next person who calls has it."
      :rows="2"
      @retry="contacts.refetch()"
    >
      <template #empty-action>
        <AppButton @click="startAdd">Add the first contact</AppButton>
      </template>

      <ul class="divide-y divide-zinc-100">
        <li v-for="c in rows" :key="c.id" class="py-3 first:pt-0 last:pb-0">
          <!-- Edit replaces the row, so the rep never loses their place -->
          <ContactForm
            v-if="editingId === c.id"
            :key="`edit-${c.id}`"
            :customer-key="customerKey"
            :contact="c"
            @saved="closePanels"
            @cancel="closePanels"
          />

          <template v-else>
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="flex flex-wrap items-center gap-2 font-medium text-zinc-900">
                  <span class="truncate">{{ c.name }}</span>
                  <AppBadge v-if="c.is_primary" tone="neutral">Primary</AppBadge>
                </p>
                <p v-if="subtitle(c)" class="mt-0.5 text-sm break-words text-zinc-500">
                  {{ subtitle(c) }}
                </p>
                <p v-if="c.notes" class="mt-1 text-sm whitespace-pre-wrap text-zinc-600">
                  {{ c.notes }}
                </p>
              </div>

              <a
                v-if="c.phone"
                :href="telHref(c.phone)"
                class="tap-target inline-flex shrink-0 items-center rounded-lg border border-zinc-300 bg-white px-3 text-sm font-medium text-zinc-900"
              >
                Call
              </a>
            </div>

            <div class="mt-2 flex flex-wrap items-center gap-2">
              <a
                v-if="c.email"
                :href="`mailto:${c.email}`"
                class="tap-target inline-flex items-center px-1 text-sm font-medium text-zinc-700 underline underline-offset-2"
              >
                Email
              </a>
              <button
                type="button"
                class="tap-target inline-flex items-center px-1 text-sm font-medium text-zinc-700 underline underline-offset-2"
                @click="startEdit(c)"
              >
                Edit
              </button>
              <button
                v-if="canDelete && confirmingDeleteId !== c.id"
                type="button"
                class="tap-target inline-flex items-center px-1 text-sm font-medium text-red-700 underline underline-offset-2"
                @click="askDelete(c)"
              >
                Delete
              </button>
            </div>

            <!-- Two-tap confirm, inline. -->
            <div
              v-if="confirmingDeleteId === c.id"
              class="mt-2 rounded-lg border border-red-200 bg-red-50 p-3"
            >
              <p class="text-sm text-red-900">
                Delete {{ c.name }}? This can't be undone.
              </p>
              <p v-if="deleteError" role="alert" class="mt-1 text-sm text-red-800">
                {{ deleteError }}
              </p>
              <div class="mt-2 flex gap-2">
                <AppButton
                  variant="danger"
                  :loading="remove.isPending.value"
                  @click="confirmDelete(c)"
                >
                  Delete
                </AppButton>
                <AppButton variant="ghost" @click="confirmingDeleteId = null">
                  Keep it
                </AppButton>
              </div>
            </div>
          </template>
        </li>
      </ul>
    </AsyncState>
  </AppCard>
</template>
