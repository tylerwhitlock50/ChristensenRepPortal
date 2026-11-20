<script setup lang="ts">
import { computed, nextTick, ref, toRef, useId, watch } from 'vue'
import {
  FAMILY_GROUPING_LABEL,
  hasProductLine,
  mixBar,
  mixSlots,
  pivotSkuYears,
  rollupFamilySales,
  useSkuSalesByAccount,
  type FamilyGrouping,
  type FamilySalesRow,
} from '@/composables/useIntel'
import { useAccount } from '@/composables/useAccounts'
import AppCollapsibleCard from '@/components/ui/AppCollapsibleCard.vue'
import AppButton from '@/components/ui/AppButton.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import ExportMenu from '@/components/ui/ExportMenu.vue'
import FamilyMixBars from '@/components/FamilyMixBars.vue'
import { cardHintState } from '@/components/ui/cardHint'
import { mixColor } from '@/lib/mixColors'
import { count, money, share } from '@/lib/format'
import type { ExportColumn } from '@/lib/xlsx'

/**
 * What this account buys, by family: the mix this year against last, then
 * each family's dollars, and under a family the SKUs that make it up.
 *
 * The same rows as the "Sales by SKU" card below it, read through the same
 * query (one fetch feeds both), only grouped — so a family's line is exactly
 * the sum of the SKUs it opens to, and both cards' totals agree.
 *
 * Last year is the WHOLE calendar year (the rollup has no months), so the
 * two years' dollars are never set against each other as a change. Their
 * SHARES are comparable whatever the date, which is why the card leads with
 * mix: a family at 40% of last year and 25% of this one has slipped, in
 * March as surely as in November.
 *
 * Collapsed and unfetched on arrival, like the SKU card (see its header for
 * why): the query runs against an empty key until the card is first opened.
 */
const props = defineProps<{ customerKey: string }>()

const card = ref<InstanceType<typeof AppCollapsibleCard> | null>(null)
/* Latched per account, exactly as AccountSkuSalesCard does. */
const wanted = ref(false)
watch(
  () => card.value?.isOpen,
  (open) => {
    if (open) wanted.value = true
  },
)
const key = computed(() => (wanted.value ? props.customerKey : ''))

const query = useSkuSalesByAccount(key)
const yearNow = new Date().getFullYear()
const pivoted = computed(() => pivotSkuYears(query.data.value ?? [], yearNow))

/* ---- family or product line ----------------------------------------------
   Two near-twin attributes (see FamilyGrouping). Family is the portal's own
   word and the default; Product line is Tableau's "Family", for anyone
   matching an old report. Offered only when the data carries product codes.
------------------------------------------------------------------------- */
const grouping = ref<FamilyGrouping>('family')
const canGroupByLine = computed(() => hasProductLine(pivoted.value))
const GROUPINGS: FamilyGrouping[] = ['family', 'line']
const noun = computed(() => (grouping.value === 'line' ? 'product line' : 'family'))
const nounPlural = computed(() => (grouping.value === 'line' ? 'product lines' : 'families'))

const families = computed(() => rollupFamilySales(pivoted.value, grouping.value))
const slots = computed(() => mixSlots(families.value))
const bars = computed(() => [
  { label: `${yearNow} to date`, bar: mixBar(families.value, slots.value, 'this') },
  { label: `All of ${yearNow - 1}`, bar: mixBar(families.value, slots.value, 'last') },
])

const hint = computed(() =>
  !wanted.value
    ? 'Mix this year vs last'
    : (cardHintState(query, families.value.length) ??
      `${families.value.length} ${families.value.length === 1 ? noun.value : nounPlural.value}`),
)

/* ---- the list: families, each opening to its SKUs ------------------------- */
const PREVIEW = 8
const SKU_PREVIEW = 10
const showAllFamilies = ref(false)
const shown = computed(() =>
  showAllFamilies.value ? families.value : families.value.slice(0, PREVIEW),
)

/** Families whose SKUs are showing, and those showing every SKU. */
const openKeys = ref(new Set<string>())
const fullKeys = ref(new Set<string>())
/** The family under the pointer (bar segment or list row): its colour stays lit. */
const active = ref<string | null>(null)

function toggle(familyKey: string) {
  const next = new Set(openKeys.value)
  if (next.has(familyKey)) next.delete(familyKey)
  else next.add(familyKey)
  openKeys.value = next
}
function showEverySku(familyKey: string) {
  fullKeys.value = new Set(fullKeys.value).add(familyKey)
}
function skusShown(f: FamilySalesRow) {
  return fullKeys.value.has(f.key) ? f.skus : f.skus.slice(0, SKU_PREVIEW)
}

/**
 * A family's small print: this year's units (its dollars and share are the
 * big figures on the right), then last year whole. A year with nothing in
 * it says "none" rather than "0 units, $0 (0%)".
 */
function unitsLine(f: FamilySalesRow): string {
  const units = (n: number) => `${count(n)} ${n === 1 ? 'unit' : 'units'}`
  const now =
    f.qtyThisYear || f.revenueThisYear ? `${yearNow}: ${units(f.qtyThisYear)}` : `${yearNow}: none`
  if (!f.qtyLastYear && !f.revenueLastYear) return `${now} · ${yearNow - 1}: none`
  const mix = f.shareLastYear != null ? ` (${share(f.shareLastYear)})` : ''
  return `${now} · ${yearNow - 1}: ${units(f.qtyLastYear)}, ${money(f.revenueLastYear)}${mix}`
}

function resetList() {
  openKeys.value = new Set()
  fullKeys.value = new Set()
  showAllFamilies.value = false
  active.value = null
}
/* A family name means something else in the other grouping, and nothing at
   all on the next account (the router reuses this component). */
watch(grouping, resetList)
watch(
  () => props.customerKey,
  () => {
    wanted.value = !!card.value?.isOpen
    grouping.value = 'family'
    resetList()
  },
)

/* A tap on a bar segment opens that family in the list and brings it into
   view. "Other" is not one family, so it shows the ones it stands for. */
const uid = useId()
const rowId = (index: number) => `${uid}-family-${index}`

async function openFromBar(familyKey: string) {
  const index = families.value.findIndex((f) => f.key === familyKey)
  if (index < 0) {
    showAllFamilies.value = true
    return
  }
  if (index >= PREVIEW) showAllFamilies.value = true
  if (!openKeys.value.has(familyKey)) toggle(familyKey)
  await nextTick()
  document.getElementById(rowId(index))?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
}

/* ---- download ------------------------------------------------------------
   One row per family — the list on screen, all of it, not the preview. The
   SKU-level file is the Sales by SKU card's download (it has a Family and a
   Product line column to pivot on).
------------------------------------------------------------------------- */
const account = useAccount(toRef(props, 'customerKey'))
const accountName = computed(() => account.data.value?.customer_name || props.customerKey)
const accountLine = computed(() => {
  const id = account.data.value?.customer_id
  return id && id !== accountName.value
    ? `Account: ${id} — ${accountName.value}`
    : `Account: ${accountName.value}`
})

const exportColumns = computed<ExportColumn<FamilySalesRow>[]>(() => [
  { key: 'key', header: FAMILY_GROUPING_LABEL[grouping.value] },
  { key: 'skuCount', header: 'SKUs', type: 'integer' },
  { key: 'qtyThisYear', header: `Units ${yearNow} to date`, type: 'number' },
  { key: 'revenueThisYear', header: `Revenue ${yearNow} to date`, type: 'money' },
  { key: 'shareThisYear', header: `Share of ${yearNow} revenue`, type: 'percent' },
  { key: 'qtyLastYear', header: `Units all of ${yearNow - 1}`, type: 'number' },
  { key: 'revenueLastYear', header: `Revenue all of ${yearNow - 1}`, type: 'money' },
  { key: 'shareLastYear', header: `Share of ${yearNow - 1} revenue`, type: 'percent' },
  { key: 'lastInvoiceDate', header: 'Last invoice', type: 'date' },
])
const exportDescription = computed(
  () =>
    `Invoiced units and revenue by ${noun.value}, biggest first. ${yearNow} is year to ` +
    `date; ${yearNow - 1} is the whole calendar year, not the same period — compare the ` +
    'shares, not the dollars.',
)
const exportDetails = computed(() => [
  accountLine.value,
  grouping.value === 'line'
    ? 'Grouped by product line (the ERP product code — "Family" in Tableau)'
    : 'Grouped by family; barreled actions, and components & accessories, are one row each',
  `Only what was invoiced in ${yearNow - 1} or ${yearNow}`,
])
</script>

<template>
  <AppCollapsibleCard ref="card" title="Sales by family" :hint="hint" :padded="false">
    <template #actions>
      <ExportMenu
        :rows="families"
        :columns="exportColumns"
        :title="`Sales by ${noun} — ${accountName}`"
        :filename="`${grouping === 'line' ? 'product-line' : 'family'}-sales-${customerKey}`"
        :description="exportDescription"
        :details="exportDetails"
        :sheet-name="`Sales by ${noun}`"
      />
    </template>
    <AsyncState
      :loading="query.isPending.value"
      :error="query.error.value"
      :has-data="query.data.value !== undefined"
      :updated-at="query.dataUpdatedAt.value"
      :empty="!query.isPending.value && families.length === 0"
      empty-title="No sales to split"
      :empty-body="`Nothing invoiced to this account in ${yearNow - 1} or ${yearNow}.`"
      :rows="2"
      @retry="query.refetch()"
    >
      <div class="space-y-3 px-4 pt-3 pb-4">
        <div
          v-if="canGroupByLine"
          class="border-line inline-flex border"
          role="group"
          aria-label="Group by"
        >
          <button
            v-for="g in GROUPINGS"
            :key="g"
            type="button"
            class="tap-target font-label px-4 text-[13px] font-semibold tracking-[0.12em] uppercase"
            :class="grouping === g ? 'bg-ink text-canvas' : 'text-muted'"
            :aria-pressed="grouping === g"
            @click="grouping = g"
          >
            {{ FAMILY_GROUPING_LABEL[g] }}
          </button>
        </div>

        <FamilyMixBars
          :bars="bars"
          :active="active"
          @select="openFromBar"
          @hover="active = $event"
        />
        <p class="text-muted text-xs">
          Share of invoiced revenue. {{ yearNow - 1 }} is the whole year, so compare the
          mix, not the dollars.
        </p>
      </div>

      <!-- What the right-hand figures are, said once instead of on every row. -->
      <div
        class="border-line font-label text-muted flex justify-between gap-3 border-y px-4 py-1.5 text-[11px] font-semibold tracking-[0.1em] uppercase"
        aria-hidden="true"
      >
        <span>{{ FAMILY_GROUPING_LABEL[grouping] }}</span>
        <span>{{ yearNow }} to date · share</span>
      </div>

      <ul class="divide-line divide-y">
        <li v-for="(f, i) in shown" :id="rowId(i)" :key="f.key" class="scroll-mt-16">
          <button
            type="button"
            class="hover:bg-canvas flex w-full items-start gap-3 px-4 py-2.5 text-left"
            :class="active === f.key ? 'bg-canvas' : ''"
            :aria-expanded="openKeys.has(f.key)"
            :aria-controls="`${rowId(i)}-skus`"
            @click="toggle(f.key)"
            @pointerenter="active = f.key"
            @pointerleave="active = null"
          >
            <!-- The legend: this row's colour in the bars above. -->
            <span
              class="mt-1.5 size-2.5 shrink-0 rounded-[2px]"
              :style="{ backgroundColor: mixColor(slots.get(f.key) ?? -1) }"
              aria-hidden="true"
            />
            <span class="min-w-0 flex-1">
              <span class="text-ink block text-[15px] font-semibold break-words">{{ f.key }}</span>
              <span class="text-muted mt-0.5 block text-xs tabular-nums">
                {{ unitsLine(f) }}
              </span>
            </span>
            <span class="shrink-0 text-right">
              <span class="text-ink block text-[15px] font-semibold tabular-nums">
                {{ money(f.revenueThisYear) }}
              </span>
              <span class="text-muted mt-0.5 block text-xs tabular-nums">
                {{ share(f.shareThisYear) }}
              </span>
            </span>
            <svg
              class="text-muted mt-1 size-4 shrink-0 transition-transform"
              :class="openKeys.has(f.key) ? 'rotate-180' : ''"
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

          <!-- The SKUs behind the line above, in the SKU card's own wording.
               The wrapper stays mounted so aria-controls always resolves. -->
          <div :id="`${rowId(i)}-skus`">
            <template v-if="openKeys.has(f.key)">
              <ul class="divide-line bg-canvas border-line divide-y border-t">
                <!-- Indented to the family's name, past its swatch. -->
                <li v-for="p in skusShown(f)" :key="p.part_key" class="py-2 pr-4 pl-[2.375rem]">
                  <p class="text-ink text-sm font-semibold">
                    {{ p.part_id }}
                    <span class="text-ink-2 font-normal"> · {{ p.part_description }}</span>
                  </p>
                  <p class="text-muted mt-0.5 text-xs tabular-nums">
                    {{ yearNow }}: {{ count(p.qtyThisYear) }} units,
                    {{ money(p.revenueThisYear) }}
                    · {{ yearNow - 1 }}: {{ count(p.qtyLastYear) }} units,
                    {{ money(p.revenueLastYear) }}
                  </p>
                </li>
              </ul>
              <div
                v-if="f.skus.length > SKU_PREVIEW && !fullKeys.has(f.key)"
                class="bg-canvas border-line border-t p-2"
              >
                <AppButton variant="ghost" block @click="showEverySku(f.key)">
                  Show all {{ f.skus.length }} SKUs
                </AppButton>
              </div>
            </template>
          </div>
        </li>
      </ul>
      <div v-if="families.length > PREVIEW" class="border-line border-t p-3">
        <AppButton variant="ghost" block @click="showAllFamilies = !showAllFamilies">
          {{ showAllFamilies ? 'Show fewer' : `Show all ${families.length} ${nounPlural}` }}
        </AppButton>
      </div>
    </AsyncState>
  </AppCollapsibleCard>
</template>
