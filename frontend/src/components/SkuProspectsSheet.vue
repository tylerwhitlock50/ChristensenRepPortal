<script setup lang="ts">
import { computed } from 'vue'
import AppModal from '@/components/ui/AppModal.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { useBestContacts } from '@/composables/useBestContacts'
import {
  useSkuProspects,
  type ProspectPart,
  type ProspectPurpose,
} from '@/composables/useSkuProspects'
import { count, shortDate, telHref } from '@/lib/format'

/**
 * "Who should I call?" for one in-stock SKU: the dealers in the rep's book
 * who have bought it, most recent buyer first, each with the person to ring
 * (lib/contacts.ts ranking — the buyer, not the INVOICE mailbox) and a way
 * into the account. When nobody bought that exact part, the dealers who
 * bought the same family / chambering, and the sheet says so.
 *
 * The same sheet answers SKU Sales' "who bought it" (`purpose="buyers"`):
 * every buyer in the book, the accounts the rep stopped working included and
 * marked, so the list is the population of the SKU row it opened from.
 *
 * A bottom sheet on a phone (AppModal). Nothing is fetched until it opens.
 */
const props = withDefaults(
  defineProps<{
    open: boolean
    part: ProspectPart | null
    /** The In stock list asks who to call; SKU Sales asks who bought it. */
    purpose?: ProspectPurpose
  }>(),
  { purpose: 'call' },
)

const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const title = computed(() => (props.purpose === 'buyers' ? 'Who bought it' : 'Who should I call?'))

const prospects = useSkuProspects(() => (props.open ? props.part : null), props.purpose)
const dealers = computed(() => prospects.data.value?.dealers ?? [])
const match = computed(() => prospects.data.value?.match ?? 'none')
/** Exact buyers the call list left off because the rep stopped working them. */
const hidden = computed(() => prospects.data.value?.hidden ?? 0)

const emptyTitle = computed(() =>
  hidden.value > 0
    ? 'Only accounts you stopped working bought this'
    : 'Nobody in your book has bought this',
)
const emptyBody = computed(() => {
  if (hidden.value > 0) {
    return `${count(hidden.value)} ${hidden.value === 1 ? 'account' : 'accounts'} in your book bought it, all deactivated — they're left off a call list. Reactivate one from its account page to see it here.`
  }
  return similarTo.value
    ? `No dealer in your book has bought this SKU, or another ${similarTo.value}, in the last four years.`
    : 'No dealer in your book has bought this SKU in the last four years.'
})

const reach = useBestContacts(() => dealers.value.map((d) => d.customer_key))

/** Each dealer with the one number to ring (null until contacts load). */
const rows = computed(() =>
  dealers.value.map((d) => {
    const best = reach.byKey.value.get(d.customer_key)?.best ?? null
    return {
      ...d,
      contactsLoaded: best !== null,
      callLabel: best?.callable ? best.contact?.label ?? null : null,
      callHref: best?.callable && best.contact?.phone ? telHref(best.contact.phone) : null,
      // There IS a number; the dealer asked not to be called on it. Said as
      // that, not as "no number" — the rep would add a duplicate contact or
      // ring the store anyway (the account header says the same).
      doNotCall: !best?.callable && !!best?.contact?.phone && best.contact.do_not_call === true,
    }
  }),
)

const similarTo = computed(() => {
  const p = props.part
  if (!p) return ''
  return [p.product_family, p.chambering]
    .map((v) => (v ?? '').trim())
    .filter((v) => v && v.toUpperCase() !== 'N/A')
    .join(' ')
})

const subtitle = computed(() =>
  props.part ? [props.part.part_id, props.part.part_description].filter(Boolean).join(' · ') : '',
)

function place(d: { city: string | null; state: string | null }) {
  return [d.city, d.state].filter(Boolean).join(', ')
}

/** Name the rep only when the dealers belong to more than one — a
 *  principal's agency, an admin — never a rep's own name on every row. */
const showRep = computed(() => new Set(dealers.value.map((d) => d.repName)).size > 1)

function whereAndWhose(d: { city: string | null; state: string | null; repName: string | null }) {
  return [place(d), showRep.value ? d.repName : null].filter(Boolean).join(' · ')
}
</script>

<template>
  <AppModal
    :open="open"
    :title="title"
    :subtitle="subtitle"
    @update:open="emit('update:open', $event)"
  >
    <AsyncState
      :loading="prospects.isPending.value"
      :error="prospects.error.value"
      :has-data="prospects.data.value !== undefined"
      :updated-at="prospects.dataUpdatedAt.value"
      :empty="dealers.length === 0"
      :empty-title="emptyTitle"
      :empty-body="emptyBody"
      :rows="3"
      @retry="prospects.refetch()"
    >
      <p class="text-muted text-[13px]">
        <template v-if="match === 'similar'">
          Nobody in your book has bought this exact SKU. These dealers bought
          other {{ similarTo }}, most recent first.
        </template>
        <template v-else>Dealers in your book who bought it, most recent first.</template>
        <template v-if="hidden > 0">
          {{ count(hidden) }} {{ hidden === 1 ? 'buyer' : 'buyers' }} of this SKU you
          stopped working {{ hidden === 1 ? 'is' : 'are' }} left off.
        </template>
      </p>

      <ul class="divide-line mt-2 divide-y">
        <li v-for="d in rows" :key="d.customer_key" class="py-3">
          <RouterLink
            :to="{ name: 'account', params: { customerKey: d.customer_key } }"
            class="tap-target group flex flex-col justify-center"
          >
            <span class="text-ink text-[15px] font-semibold group-hover:underline">
              {{ d.customer_name || d.customer_key }}
              <span aria-hidden="true" class="text-muted">→</span>
            </span>
            <span v-if="whereAndWhose(d)" class="text-muted text-xs">{{ whereAndWhose(d) }}</span>
            <span v-if="d.deactivated" class="text-muted text-xs">Not being worked — deactivated</span>
          </RouterLink>
          <p class="text-ink-2 text-sm tabular-nums">
            Bought {{ count(d.unitsLastYear) }} in {{ d.lastYear }}
            <template v-if="d.lastInvoiceDate"> · last {{ shortDate(d.lastInvoiceDate) }}</template>
          </p>

          <template v-if="d.contactsLoaded">
            <a
              v-if="d.callHref"
              :href="d.callHref"
              class="btn-secondary mt-2 w-full max-w-full text-[13px]"
            >
              <span class="truncate">Call {{ d.callLabel }}</span>
            </a>
            <p v-else-if="d.doNotCall" class="text-muted mt-1 text-[13px]">
              Number marked do not call
            </p>
            <p v-else class="text-muted mt-1 text-[13px]">No buyer number on file</p>
          </template>
        </li>
      </ul>

      <p v-if="(prospects.data.value?.more ?? 0) > 0" class="text-muted mt-2 text-[13px]">
        And about {{ count(prospects.data.value!.more) }} more who bought less recently.
      </p>
    </AsyncState>
  </AppModal>
</template>
