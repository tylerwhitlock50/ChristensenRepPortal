<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { onBeforeRouteLeave, useRouter } from 'vue-router'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AccountPicker from '@/components/AccountPicker.vue'
import { useTerritoryAccounts } from '@/composables/useOverview'
import {
  promoLabel,
  useEffectivePriceLists,
  usePriceListItems,
  type PriceListItemRow,
  type PriceListRow,
} from '@/composables/usePriceLists'
import {
  useCreateDraftOrder,
  useDeleteDraftOrder,
  useOrderCustomer,
  useOrderDetail,
  useSaveDraftLines,
  useSubmitOrder,
  useUpdateDraftOrder,
  type DraftLineInput,
} from '@/composables/useOrders'
import { orderTotal, priceOrder, type PricingLineInput } from '@/lib/orderPricing'
import { money } from '@/lib/format'
import { newPhotoId } from '@/lib/photos'

/**
 * The order writer. Flow: pick the account → its customer_type resolves the
 * effective price lists (the general list opens preselected; specials are a
 * tap away) → add SKUs from the open list → the promo prorate previews live
 * as quantities change → save draft / submit.
 *
 * The pricing preview runs through lib/orderPricing.ts on every edit, but
 * nothing here is authoritative: submit_order() re-validates the lines
 * against today's effective lists and recomputes every discount
 * server-side. A stale tab cannot submit stale prices.
 */
const props = defineProps<{ id?: string }>()

const router = useRouter()

// ------------------------------------------------------------ local state
interface LocalLine {
  key: string
  priceListId: number
  priceListItemId: number | null
  partId: string
  description: string | null
  qty: number
  listUnitPrice: number
}

const orderId = ref<number | null>(props.id ? Number(props.id) : null)
const customerKey = ref('')
const poNumber = ref('')
const shipDate = ref('')
const notes = ref('')
const lines = ref<LocalLine[]>([])
const dirty = ref(false)
const formError = ref('')
const hydrated = ref(!props.id)

watch([customerKey, poNumber, shipDate, notes, lines], () => (dirty.value = true), {
  deep: true,
})

// ------------------------------------------------- editing an existing draft
const existing = props.id ? useOrderDetail(Number(props.id)) : null
watch(
  () => existing?.data.value,
  (detail) => {
    if (!detail || hydrated.value) return
    if (detail.order.status !== 'draft') {
      void router.replace({ name: 'order-detail', params: { id: detail.order.id } })
      return
    }
    customerKey.value = detail.order.customer_key
    poNumber.value = detail.order.po_number ?? ''
    shipDate.value = detail.order.requested_ship_date ?? ''
    notes.value = detail.order.notes ?? ''
    lines.value = detail.lines.map((l) => ({
      key: String(l.id),
      priceListId: l.price_list_id,
      priceListItemId: l.price_list_item_id,
      partId: l.part_id,
      description: l.description,
      qty: l.qty,
      listUnitPrice: l.unit_price,
    }))
    hydrated.value = true
    // Hydration is not a user edit.
    void Promise.resolve().then(() => (dirty.value = false))
  },
  { immediate: true },
)

// ------------------------------------------------------------- the account
const territory = useTerritoryAccounts()
const accounts = computed(() =>
  [...(territory.data.value ?? [])].sort((a, b) =>
    (a.customer_name ?? a.customer_key).localeCompare(
      b.customer_name ?? b.customer_key,
    ),
  ),
)

const customer = useOrderCustomer(customerKey)
const customerType = computed(() => customer.data.value?.customer_type ?? null)
const customerLoaded = computed(
  () => !!customerKey.value && customer.isSuccess.value,
)

/** Changing the account invalidates every line's list eligibility. */
watch(customerKey, (next, prev) => {
  if (prev && next !== prev && lines.value.length > 0) {
    lines.value = []
    browseListId.value = null
  }
})

// ---------------------------------------------------------- effective lists
const effective = useEffectivePriceLists(
  computed(() => (customerLoaded.value ? customerType.value : undefined) as string | null),
)
const effectiveLists = computed(() => effective.data.value ?? [])
const specialLists = computed(() => effectiveLists.value.filter((l) => l.is_special))

/** Which list the SKU picker is browsing. General preselects itself. */
const browseListId = ref<number | null>(null)
watch(effectiveLists, (lists) => {
  if (browseListId.value == null && lists.length > 0) {
    browseListId.value = (lists.find((l) => !l.is_special) ?? lists[0]).id
  }
})
const browseList = computed(
  () => effectiveLists.value.find((l) => l.id === browseListId.value) ?? null,
)

const itemsQuery = usePriceListItems(browseListId)
const itemSearch = ref('')
const matchingItems = computed(() => {
  const term = itemSearch.value.trim().toLowerCase()
  const pool = itemsQuery.data.value ?? []
  if (!term) return pool.slice(0, 30)
  return pool
    .filter(
      (i) =>
        i.part_id.toLowerCase().includes(term) ||
        (i.description ?? '').toLowerCase().includes(term),
    )
    .slice(0, 30)
})

function addItem(item: PriceListItemRow) {
  const existingLine = lines.value.find(
    (l) => l.priceListId === item.price_list_id && l.partId === item.part_id,
  )
  if (existingLine) {
    existingLine.qty += 1
    return
  }
  lines.value.push({
    key: newPhotoId(),
    priceListId: item.price_list_id,
    priceListItemId: item.id,
    partId: item.part_id,
    description: item.description,
    qty: 1,
    listUnitPrice: item.unit_price,
  })
}

function removeLine(key: string) {
  lines.value = lines.value.filter((l) => l.key !== key)
}

// ------------------------------------------------------------ live pricing
const promosByListId = computed(() => {
  const map = new Map<number, { buyQty: number; getQty: number }>()
  for (const list of specialLists.value) {
    if (list.promo_buy_qty != null && list.promo_get_qty != null) {
      map.set(list.id, { buyQty: list.promo_buy_qty, getQty: list.promo_get_qty })
    }
  }
  return map
})

const priced = computed(() => {
  const inputs: PricingLineInput[] = lines.value.map((l) => ({
    key: l.key,
    priceListId: l.priceListId,
    partId: l.partId,
    qty: l.qty,
    listUnitPrice: l.listUnitPrice,
  }))
  return priceOrder(inputs, promosByListId.value)
})
const pricedByKey = computed(
  () => new Map(priced.value.map((l) => [l.key, l] as const)),
)
const total = computed(() => orderTotal(priced.value))

/** "Buy 10, get 2 — 11.11% off" or "4 more units to unlock". */
const promoStatus = computed(() => {
  const statuses: { list: PriceListRow; text: string; earned: boolean }[] = []
  for (const list of specialLists.value) {
    const promo = promosByListId.value.get(list.id)
    if (!promo) continue
    const qtyOnList = lines.value
      .filter((l) => l.priceListId === list.id)
      .reduce((sum, l) => sum + l.qty, 0)
    if (qtyOnList === 0) continue
    const block = promo.buyQty + promo.getQty
    const pct = priced.value.find(
      (l) => l.priceListId === list.id && l.discountPct > 0,
    )?.discountPct
    if (pct) {
      statuses.push({
        list,
        text: `${promoLabel(list)} — ${pct}% off ${qtyOnList} units`,
        earned: true,
      })
    } else {
      statuses.push({
        list,
        text: `${promoLabel(list)} — ${block - qtyOnList} more unit${
          block - qtyOnList === 1 ? '' : 's'
        } to earn the discount`,
        earned: false,
      })
    }
  }
  return statuses
})

function listName(id: number): string {
  return effectiveLists.value.find((l) => l.id === id)?.name ?? `List ${id}`
}

// ------------------------------------------------------------ save / submit
const createOrder = useCreateDraftOrder()
const updateOrder = useUpdateDraftOrder()
const saveLines = useSaveDraftLines()
const submitOrder = useSubmitOrder()
const deleteOrder = useDeleteDraftOrder()

const saving = computed(
  () =>
    createOrder.isPending.value ||
    updateOrder.isPending.value ||
    saveLines.isPending.value,
)

async function persistDraft(): Promise<number> {
  const header = {
    customer_key: customerKey.value,
    po_number: poNumber.value.trim() || null,
    requested_ship_date: shipDate.value || null,
    notes: notes.value.trim() || null,
  }
  let id = orderId.value
  if (id == null) {
    const created = await createOrder.mutateAsync(header)
    id = created.id
    orderId.value = id
  } else {
    await updateOrder.mutateAsync({ id, ...header })
  }

  const draftLines: DraftLineInput[] = lines.value.map((l) => {
    const p = pricedByKey.value.get(l.key)
    return {
      price_list_id: l.priceListId,
      price_list_item_id: l.priceListItemId,
      part_id: l.partId,
      description: l.description,
      qty: l.qty,
      unit_price: l.listUnitPrice,
      discount_pct: p?.discountPct ?? 0,
      effective_unit_price: p?.effectiveUnitPrice ?? l.listUnitPrice,
    }
  })
  await saveLines.mutateAsync({ orderId: id, lines: draftLines })
  dirty.value = false
  return id
}

async function onSaveDraft() {
  formError.value = ''
  if (!customerKey.value) {
    formError.value = 'Pick an account first.'
    return
  }
  try {
    await persistDraft()
  } catch (err) {
    formError.value = (err as { message?: string }).message || 'Saving failed.'
  }
}

async function onSubmit() {
  formError.value = ''
  if (!customerKey.value) {
    formError.value = 'Pick an account first.'
    return
  }
  if (lines.value.length === 0) {
    formError.value = 'Add at least one line.'
    return
  }
  try {
    const id = await persistDraft()
    await submitOrder.mutateAsync(id)
    void router.push({ name: 'order-detail', params: { id } })
  } catch (err) {
    formError.value = (err as { message?: string }).message || 'Submitting failed.'
  }
}

async function onDiscard() {
  if (orderId.value != null) {
    if (!window.confirm('Delete this draft order?')) return
    await deleteOrder.mutateAsync(orderId.value)
  }
  dirty.value = false
  void router.push({ name: 'orders' })
}

onBeforeRouteLeave(() => {
  if (!dirty.value) return true
  return window.confirm('Leave without saving this draft?')
})
</script>

<template>
  <div class="space-y-5">
    <!-- 1 · Account -->
    <AppCard title="1 · Account">
      <AccountPicker
        v-model="customerKey"
        :accounts="accounts"
        label="Who is this order for?"
      />
      <p
        v-if="customerLoaded && customer.data.value && !customerType"
        role="alert"
        class="border-line border-l-accent text-ink-2 mt-3 border border-l-[3px] p-3 text-[14px]"
      >
        <strong class="text-ink">This account has no customer type in the ERP</strong>
        — the portal can't tell which price list applies. Ask an admin to fix
        the account before writing this order.
      </p>
    </AppCard>

    <!-- 2 · Price list + SKUs -->
    <AppCard v-if="customerLoaded && customerType" title="2 · Add products">
      <div class="space-y-4">
        <div
          v-if="!effective.isLoading.value && effectiveLists.length === 0"
          role="alert"
          class="border-line border-l-accent text-ink-2 border border-l-[3px] p-3 text-[14px]"
        >
          No price list is effective today for
          <strong class="text-ink">{{ customerType }}</strong> — an admin needs
          to publish one under Admin → Price Lists.
        </div>

        <template v-else>
          <div class="flex flex-wrap gap-2" role="tablist" aria-label="Price lists">
            <button
              v-for="list in effectiveLists"
              :key="list.id"
              type="button"
              role="tab"
              :aria-selected="browseListId === list.id"
              class="tap-target font-label border px-3 text-[13px] font-semibold tracking-[0.1em] uppercase"
              :class="
                browseListId === list.id
                  ? 'border-ink bg-ink text-canvas'
                  : 'border-line text-muted hover:text-ink'
              "
              @click="browseListId = list.id"
            >
              {{ list.name }}
              <span v-if="list.is_special" class="ml-1 normal-case tracking-normal">
                · {{ promoLabel(list) ?? 'special' }}
              </span>
            </button>
          </div>

          <p v-if="browseList?.is_special" class="text-muted text-[13px]">
            Special pricing{{
              promoLabel(browseList)
                ? ` — ${promoLabel(browseList)}, settled as a prorated percent off, never free goods`
                : ''
            }}.
          </p>

          <label class="block">
            <span class="sr-only">Search this price list</span>
            <input
              v-model="itemSearch"
              class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              :placeholder="`Search ${browseList?.name ?? 'the list'} by SKU or description…`"
            />
          </label>

          <div v-if="itemsQuery.isLoading.value" class="text-muted text-[14px]">
            Loading items…
          </div>
          <p
            v-else-if="(itemsQuery.data.value ?? []).length === 0"
            class="text-muted text-[14px]"
          >
            This list has no items yet — an admin needs to upload them.
          </p>
          <ul v-else class="divide-line border-line max-h-72 divide-y overflow-y-auto border">
            <li v-for="item in matchingItems" :key="item.id">
              <button
                type="button"
                class="hover:bg-canvas flex w-full items-center justify-between gap-3 px-3 py-2.5 text-left"
                @click="addItem(item)"
              >
                <span class="min-w-0">
                  <span class="text-ink block truncate text-[15px] font-medium">
                    {{ item.part_id }}
                  </span>
                  <span class="text-muted block truncate text-[13px]">
                    {{ item.description || '—' }}
                  </span>
                </span>
                <span class="text-ink shrink-0 text-[15px] font-semibold">
                  {{ money(item.unit_price) }}
                </span>
              </button>
            </li>
          </ul>
        </template>
      </div>
    </AppCard>

    <!-- 3 · Lines -->
    <AppCard v-if="lines.length > 0" title="3 · Order lines" :hint="`${lines.length} lines`">
      <div class="space-y-4">
        <div
          v-for="status in promoStatus"
          :key="status.list.id"
          class="flex items-center gap-2"
        >
          <AppBadge :tone="status.earned ? 'good' : 'neutral'">
            {{ status.list.name }}
          </AppBadge>
          <span class="text-ink-2 text-[14px]">{{ status.text }}</span>
        </div>

        <div class="-mx-4 overflow-x-auto px-4">
          <table class="w-full min-w-[560px] text-[14px]">
            <thead>
              <tr class="text-muted border-line border-b text-left">
                <th class="py-2 pr-3 font-semibold">Part</th>
                <th class="py-2 pr-3 font-semibold">List</th>
                <th class="py-2 pr-3 text-right font-semibold">Qty</th>
                <th class="py-2 pr-3 text-right font-semibold">List price</th>
                <th class="py-2 pr-3 text-right font-semibold">Disc.</th>
                <th class="py-2 pr-3 text-right font-semibold">Net</th>
                <th class="py-2 pr-3 text-right font-semibold">Total</th>
                <th class="py-2"></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="line in lines" :key="line.key" class="border-line border-b">
                <td class="py-2 pr-3">
                  <span class="text-ink block font-medium">{{ line.partId }}</span>
                  <span class="text-muted block max-w-[200px] truncate text-[12px]">
                    {{ line.description || '' }}
                  </span>
                </td>
                <td class="text-ink-2 py-2 pr-3">{{ listName(line.priceListId) }}</td>
                <td class="py-2 pr-3 text-right">
                  <input
                    v-model.number="line.qty"
                    type="number"
                    min="1"
                    step="1"
                    class="border-line text-ink min-h-10 w-20 border px-2 text-right text-[14px]"
                    :aria-label="`Quantity for ${line.partId}`"
                  />
                </td>
                <td class="text-ink py-2 pr-3 text-right">
                  {{ money(line.listUnitPrice) }}
                </td>
                <td class="text-ink-2 py-2 pr-3 text-right">
                  {{
                    (pricedByKey.get(line.key)?.discountPct ?? 0) > 0
                      ? `${pricedByKey.get(line.key)!.discountPct}%`
                      : '—'
                  }}
                </td>
                <td class="text-ink py-2 pr-3 text-right font-medium">
                  {{ money(pricedByKey.get(line.key)?.effectiveUnitPrice ?? line.listUnitPrice) }}
                </td>
                <td class="text-ink py-2 pr-3 text-right font-semibold">
                  {{ money(pricedByKey.get(line.key)?.lineTotal ?? 0) }}
                </td>
                <td class="py-2 text-right">
                  <button
                    type="button"
                    class="text-muted hover:text-danger tap-target px-2 text-[13px] font-semibold uppercase"
                    @click="removeLine(line.key)"
                  >
                    Remove
                  </button>
                </td>
              </tr>
            </tbody>
            <tfoot>
              <tr>
                <td colspan="6" class="text-ink py-3 pr-3 text-right font-semibold">
                  Order total
                </td>
                <td class="text-ink py-3 pr-3 text-right text-[16px] font-bold">
                  {{ money(total) }}
                </td>
                <td></td>
              </tr>
            </tfoot>
          </table>
        </div>
      </div>
    </AppCard>

    <!-- 4 · Details + actions -->
    <AppCard v-if="customerLoaded && customerType" title="4 · Details & submit">
      <div class="grid gap-3 md:grid-cols-3">
        <label class="block">
          <span class="u-label text-ink block pb-2">Customer PO #</span>
          <input
            v-model="poNumber"
            class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
          />
        </label>
        <label class="block">
          <span class="u-label text-ink block pb-2">Requested ship date</span>
          <input
            v-model="shipDate"
            type="date"
            class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
          />
        </label>
        <label class="block">
          <span class="u-label text-ink block pb-2">Notes for order entry</span>
          <input
            v-model="notes"
            class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
          />
        </label>
      </div>

      <p v-if="formError" role="alert" class="text-danger mt-3 text-sm font-medium">
        {{ formError }}
      </p>

      <div class="mt-4 flex flex-wrap gap-2">
        <AppButton
          variant="primary"
          :loading="submitOrder.isPending.value || saving"
          :disabled="lines.length === 0"
          @click="onSubmit"
        >
          Submit order
        </AppButton>
        <AppButton variant="secondary" :loading="saving" @click="onSaveDraft">
          Save draft
        </AppButton>
        <AppButton variant="ghost" @click="onDiscard">
          {{ orderId == null ? 'Discard' : 'Delete draft' }}
        </AppButton>
      </div>
    </AppCard>
  </div>
</template>
