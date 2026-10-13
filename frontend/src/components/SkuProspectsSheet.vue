<script setup lang="ts">
import { computed } from 'vue'
import AppModal from '@/components/ui/AppModal.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import { useBestContacts } from '@/composables/useBestContacts'
import { useSkuProspects, type ProspectPart } from '@/composables/useSkuProspects'
import { count, shortDate, telHref } from '@/lib/format'

/**
 * "Who should I call?" for one in-stock SKU: the dealers in the rep's book
 * who have bought it, most recent buyer first, each with the person to ring
 * (lib/contacts.ts ranking — the buyer, not the INVOICE mailbox) and a way
 * into the account. When nobody bought that exact part, the dealers who
 * bought the same family / chambering, and the sheet says so.
 *
 * A bottom sheet on a phone (AppModal). Nothing is fetched until it opens.
 */
const props = defineProps<{
  open: boolean
  part: ProspectPart | null
}>()

const emit = defineEmits<{ 'update:open': [value: boolean] }>()

const prospects = useSkuProspects(() => (props.open ? props.part : null))
const dealers = computed(() => prospects.data.value?.dealers ?? [])
const match = computed(() => prospects.data.value?.match ?? 'none')

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
</script>

<template>
  <AppModal
    :open="open"
    title="Who should I call?"
    :subtitle="subtitle"
    @update:open="emit('update:open', $event)"
  >
    <AsyncState
      :loading="prospects.isPending.value"
      :error="prospects.error.value"
      :has-data="prospects.data.value !== undefined"
      :updated-at="prospects.dataUpdatedAt.value"
      :empty="dealers.length === 0"
      empty-title="Nobody in your book has bought this"
      :empty-body="
        similarTo
          ? `No dealer in your book has bought this SKU, or another ${similarTo}, in the last four years.`
          : 'No dealer in your book has bought this SKU in the last four years.'
      "
      :rows="3"
      @retry="prospects.refetch()"
    >
      <p class="text-muted text-[13px]">
        <template v-if="match === 'similar'">
          Nobody in your book has bought this exact SKU. These dealers bought
          other {{ similarTo }}, most recent first.
        </template>
        <template v-else>Dealers in your book who bought it, most recent first.</template>
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
            <span v-if="place(d)" class="text-muted text-xs">{{ place(d) }}</span>
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
