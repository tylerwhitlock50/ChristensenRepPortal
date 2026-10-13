<script setup lang="ts">
import { computed, defineAsyncComponent, ref, watch } from 'vue'
import { useSessionStore } from '@/stores/session'
import AppBadge from '@/components/ui/AppBadge.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import LazyLoadFailed from '@/components/ui/LazyLoadFailed.vue'
import { telHref } from '@/lib/format'
import { rankContacts, type ContactKind, type RankedContact } from '@/lib/contacts'
import { useAccount } from '@/composables/useAccounts'
import {
  useCanDeleteContacts,
  useContacts,
  useDeleteContact,
  useSetGoToContact,
  type AccountContact,
} from '@/composables/useContacts'

/**
 * Everyone on file for the account, best to call first.
 *
 * The order is lib/contacts.ts rankContacts(), the same ranking that picks
 * the "Who to call" contact in the account header, so the top row here is
 * always the person up there. Billing desks, our own staff and orders
 * mailboxes with no number to dial sit in a collapsed "Billing & other
 * contacts" group at the bottom — kept, because the rep sometimes does need
 * accounts payable, but out of the way of the buyer. A dialable orders line
 * stays in the main list: a number at the dealer beats no number.
 *
 * Names come from contactDisplayName(): the ERP sometimes has only a bare
 * contact id ("0027284") in the name column, and first + last name or the
 * email says far more.
 */

/* vee-validate and zod come with the form; most account opens never add or
   edit a contact, so they load on first use. */
const ContactForm = defineAsyncComponent({
  loader: () => import('@/components/ContactForm.vue'),
  errorComponent: LazyLoadFailed,
})

const props = defineProps<{ customerKey: string }>()

const session = useSessionStore()
const key = computed(() => props.customerKey)
const contacts = useContacts(key)
/* Same query as the page header (vue-query dedupes it): invoice_email and
   statement_email are the exact billing signal for ranking. */
const account = useAccount(key)
const rows = computed(() => contacts.data.value ?? [])

const ranked = computed(() =>
  rankContacts(rows.value, {
    invoiceEmail: account.data.value?.invoice_email,
    statementEmail: account.data.value?.statement_email,
  }),
)

/** Collapsed into "Billing & other contacts". */
const OTHER_KINDS = new Set<ContactKind>(['billing', 'internal', 'orders'])
const mainRows = computed(() => ranked.value.filter((c) => !OTHER_KINDS.has(c.kind)))
const otherRows = computed(() => ranked.value.filter((c) => OTHER_KINDS.has(c.kind)))
const showOthers = ref(false)

type ListItem =
  | { type: 'contact'; contact: RankedContact<AccountContact> }
  | { type: 'others' }

/** One list, so the row markup exists once: the group toggle is an item. */
const items = computed<ListItem[]>(() => {
  const list: ListItem[] = mainRows.value.map((contact) => ({ type: 'contact', contact }))
  if (otherRows.value.length) {
    list.push({ type: 'others' })
    if (showOthers.value) {
      for (const contact of otherRows.value) list.push({ type: 'contact', contact })
    }
  }
  return list
})

const KIND_BADGE: Partial<Record<ContactKind, string>> = {
  'rep-primary': 'Go-to',
  billing: 'Billing',
  internal: 'Christensen',
  orders: 'Orders line',
  'orders-callable': 'Orders line',
}

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

/* ERP rows come from the nightly customer-contact load and have no id;
   only rep-entered rows (source === 'rep') can be edited or deleted. The
   null-guards below matter: with no panel open editingId is null, and an
   ERP row's id is null too — bare `editingId === c.id` would match. */
function startEdit(contact: AccountContact) {
  if (contact.source !== 'rep' || contact.id === null) return
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

function askDelete(contact: AccountContact) {
  if (contact.source !== 'rep' || contact.id === null) return
  confirmingDeleteId.value = contact.id
  deleteError.value = ''
}

function isEditing(contact: AccountContact): boolean {
  return contact.source === 'rep' && contact.id !== null && editingId.value === contact.id
}

function isConfirmingDelete(contact: AccountContact): boolean {
  return (
    contact.source === 'rep' &&
    contact.id !== null &&
    confirmingDeleteId.value === contact.id
  )
}

/** ContactForm needs a non-null id; isEditing() has already guaranteed it. */
function editSeed(contact: AccountContact) {
  return { ...contact, id: contact.id as number }
}

async function confirmDelete(contact: RankedContact<AccountContact>) {
  if (contact.id === null) return
  deleteError.value = ''
  try {
    await remove.mutateAsync({ id: contact.id, customerKey: props.customerKey })
    confirmingDeleteId.value = null
  } catch (e) {
    deleteError.value = (e as Error).message || 'Could not delete that contact.'
  }
}

/* ---- make go-to ---------------------------------------------------------
   Rep-entered rows only; the header follows at once (same contacts query).
------------------------------------------------------------------------- */
const setGoTo = useSetGoToContact()
const goToPendingId = ref<number | null>(null)
const goToError = ref<{ id: number; message: string } | null>(null)

async function makeGoTo(contact: AccountContact) {
  if (contact.source !== 'rep' || contact.id === null) return
  goToError.value = null
  goToPendingId.value = contact.id
  try {
    await setGoTo.mutateAsync({ id: contact.id, customerKey: props.customerKey })
  } catch (e) {
    goToError.value = {
      id: contact.id,
      message: (e as Error).message || 'Could not make that the go-to contact.',
    }
  } finally {
    goToPendingId.value = null
  }
}

/** Title · phone · email, minus whatever is missing. */
function subtitle(contact: AccountContact): string {
  return [contact.title, contact.phone, contact.email].filter(Boolean).join(' · ')
}

// The router reuses the account page: a panel opened on account A must not
// be one tap from saving against account B.
watch(key, () => {
  closePanels()
  showOthers.value = false
  deleteError.value = ''
  goToError.value = null
})

/* The account header's "Add contact" (no number on file) opens this form. */
defineExpose({ startAdd })
</script>

<template>
  <AppCard padded>
    <template #header>
      <div>
        <h2 class="text-sm font-semibold tracking-tight text-ink">Contacts</h2>
        <p class="text-xs text-muted">
          {{ rows.length === 1 ? '1 person' : `${rows.length} people` }}
        </p>
      </div>
      <AppButton v-if="!adding && session.canWrite" variant="secondary" @click="startAdd">
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
      :has-data="contacts.data.value !== undefined"
      :updated-at="contacts.dataUpdatedAt.value"
      :empty="rows.length === 0 && !adding"
      empty-title="No contacts yet"
      empty-body="Add the buyer's name and number so the next person who calls has it."
      :rows="2"
      @retry="contacts.refetch()"
    >
      <template #empty-action>
        <AppButton v-if="session.canWrite" @click="startAdd">Add the first contact</AppButton>
      </template>

      <ul class="divide-y divide-line">
        <template v-for="item in items" :key="item.type === 'contact' ? item.contact.contact_key : 'others'">
          <!-- The billing / other group's toggle, between the people and
               the desks. -->
          <li v-if="item.type === 'others'" class="py-1">
            <button
              type="button"
              class="tap-target flex w-full items-center justify-between gap-3 text-left text-sm font-medium text-ink-2"
              :aria-expanded="showOthers"
              @click="showOthers = !showOthers"
            >
              <span>Billing &amp; other contacts ({{ otherRows.length }})</span>
              <svg
                class="size-4 shrink-0 text-muted transition-transform"
                :class="showOthers ? 'rotate-180' : ''"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                stroke-linecap="round"
                stroke-linejoin="round"
                aria-hidden="true"
              >
                <path d="M6 9l6 6 6-6" />
              </svg>
            </button>
          </li>

          <li v-else class="py-3 first:pt-0 last:pb-0">
            <!-- Edit replaces the row, so the rep never loses their place -->
            <ContactForm
              v-if="isEditing(item.contact)"
              :key="`edit-${item.contact.contact_key}`"
              :customer-key="customerKey"
              :contact="editSeed(item.contact)"
              @saved="closePanels"
              @cancel="closePanels"
            />

            <template v-else>
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="flex flex-wrap items-center gap-2 font-medium text-ink">
                    <span class="break-words">{{ item.contact.label }}</span>
                    <AppBadge
                      v-if="KIND_BADGE[item.contact.kind]"
                      :tone="item.contact.kind === 'rep-primary' ? 'good' : 'neutral'"
                    >
                      {{ KIND_BADGE[item.contact.kind] }}
                    </AppBadge>
                    <AppBadge v-if="item.contact.source === 'erp'" tone="neutral">ERP</AppBadge>
                    <!-- The ERP's contact-preference flags (migration 034).
                         High tone: this is an instruction, not a detail. -->
                    <AppBadge v-if="item.contact.do_not_call" tone="high">Do not call</AppBadge>
                    <AppBadge v-if="item.contact.do_not_email" tone="high">Do not email</AppBadge>
                  </p>
                  <p v-if="subtitle(item.contact)" class="mt-0.5 text-sm break-words text-muted">
                    {{ subtitle(item.contact) }}
                  </p>
                  <p v-if="item.contact.notes" class="mt-1 text-sm whitespace-pre-wrap text-ink-2">
                    {{ item.contact.notes }}
                  </p>
                </div>

                <!-- A flagged number keeps its digits visible (the rep may still
                     need them for a different, permitted reason) but loses the
                     one-tap action, so dialling can never be an accident. -->
                <a
                  v-if="item.contact.phone && !item.contact.do_not_call"
                  :href="telHref(item.contact.phone)"
                  class="tap-target inline-flex shrink-0 items-center rounded-[2px] border border-line-2 bg-surface px-3 text-sm font-medium text-ink"
                >
                  Call
                </a>
              </div>

              <div class="mt-2 flex flex-wrap items-center gap-2">
                <a
                  v-if="item.contact.email && !item.contact.do_not_email"
                  :href="`mailto:${item.contact.email}`"
                  class="tap-target inline-flex min-w-11 items-center justify-center px-1 text-sm font-medium text-ink-2 underline underline-offset-2"
                >
                  Email
                </a>
                <button
                  v-if="
                    item.contact.source === 'rep' &&
                    item.contact.kind !== 'rep-primary' &&
                    session.canWrite
                  "
                  type="button"
                  class="tap-target inline-flex min-w-11 items-center justify-center px-1 text-sm font-medium text-ink-2 underline underline-offset-2 disabled:opacity-50"
                  :disabled="goToPendingId !== null"
                  @click="makeGoTo(item.contact)"
                >
                  {{ goToPendingId === item.contact.id ? 'Saving…' : 'Make go-to contact' }}
                </button>
                <button
                  v-if="item.contact.source === 'rep' && session.canWrite"
                  type="button"
                  class="tap-target inline-flex min-w-11 items-center justify-center px-1 text-sm font-medium text-ink-2 underline underline-offset-2"
                  @click="startEdit(item.contact)"
                >
                  Edit
                </button>
                <button
                  v-if="
                    item.contact.source === 'rep' &&
                    canDelete &&
                    session.canWrite &&
                    !isConfirmingDelete(item.contact)
                  "
                  type="button"
                  class="tap-target inline-flex min-w-11 items-center justify-center px-1 text-sm font-medium text-danger underline underline-offset-2"
                  @click="askDelete(item.contact)"
                >
                  Delete
                </button>
              </div>
              <p
                v-if="goToError && goToError.id === item.contact.id"
                role="alert"
                class="text-danger mt-1 text-sm"
              >
                {{ goToError.message }}
              </p>

              <!-- Two-tap confirm, inline. -->
              <div
                v-if="isConfirmingDelete(item.contact)"
                class="border-line border-l-danger bg-surface mt-2 border border-l-[3px] p-3"
              >
                <p class="text-ink text-sm">
                  Delete {{ item.contact.label }}? This can't be undone.
                </p>
                <p v-if="deleteError" role="alert" class="text-danger mt-1 text-sm">
                  {{ deleteError }}
                </p>
                <div class="mt-2 flex gap-2">
                  <AppButton
                    variant="danger"
                    :loading="remove.isPending.value"
                    @click="confirmDelete(item.contact)"
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
        </template>
      </ul>
    </AsyncState>
  </AppCard>
</template>
