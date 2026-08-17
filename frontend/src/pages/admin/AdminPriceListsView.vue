<script setup lang="ts">
import { computed, ref } from 'vue'
import { useQuery } from '@tanstack/vue-query'
import type { SupabaseClient } from '@supabase/supabase-js'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import PriceListItemsUpload from '@/components/admin/PriceListItemsUpload.vue'
import {
  useDeletePriceListFile,
  useUploadPriceListFile,
  usePriceListFiles,
  type PriceListFileRow,
} from '@/composables/usePriceListFiles'
import {
  promoLabel,
  useCreatePriceList,
  useDeletePriceList,
  usePriceListItems,
  usePriceLists,
  useUpdatePriceList,
  type PriceListRow,
} from '@/composables/usePriceLists'
import { supabase } from '@/lib/supabase'
import { formatBytes } from '@/lib/photos'
import { shortDate } from '@/lib/format'

/**
 * Both halves of price-list publishing:
 *   1. the downloadable approved sheets (one Excel file per customer type),
 *   2. the structured lists + items the order writer prices from.
 * The two must SAY the same thing — the sheet is the human copy, the items
 * are the machine copy — which is why they share one admin tab.
 */

/** Same untyped-handle convention as useAppSettings.ts. */
const db = supabase as unknown as SupabaseClient

// ---------------------------------------------------------------- vocabulary
interface CustomerTypeRow {
  customer_type: string
  customer_count: number
}
const customerTypes = useQuery({
  queryKey: ['admin', 'customer-types'] as const,
  queryFn: async (): Promise<CustomerTypeRow[]> => {
    const { data, error } = await db.from('v_customer_types').select('*')
    if (error) throw error
    return (data ?? []) as CustomerTypeRow[]
  },
})

// ------------------------------------------------------------------- files
const filesQuery = usePriceListFiles()
const uploadFile = useUploadPriceListFile()
const deleteFile = useDeletePriceListFile()

const fType = ref('')
const fTitle = ref('')
const fInput = ref<HTMLInputElement | null>(null)
const fileNotice = ref('')
const fileError = ref('')

async function publishFile() {
  fileError.value = ''
  fileNotice.value = ''
  const file = fInput.value?.files?.[0]
  if (!file || !fType.value.trim() || !fTitle.value.trim()) {
    fileError.value = 'Customer type, a title, and a file are all required.'
    return
  }
  const replaces =
    (filesQuery.data.value ?? []).find(
      (f) => f.customer_type === fType.value.trim(),
    ) ?? null
  try {
    await uploadFile.mutateAsync({
      file,
      customerType: fType.value,
      title: fTitle.value,
      replaces,
    })
    fileNotice.value = replaces
      ? `Replaced the ${fType.value} sheet.`
      : `Published the ${fType.value} sheet.`
    fType.value = ''
    fTitle.value = ''
    if (fInput.value) fInput.value.value = ''
  } catch (err) {
    fileError.value = (err as { message?: string }).message || 'Upload failed.'
  }
}

async function removeFile(file: PriceListFileRow) {
  if (!window.confirm(`Remove the ${file.customer_type} sheet "${file.title}"?`)) return
  await deleteFile.mutateAsync(file)
}

// ------------------------------------------------------------------- lists
const listsQuery = usePriceLists()
const createList = useCreatePriceList()
const updateList = useUpdatePriceList()
const deleteList = useDeletePriceList()

const showListForm = ref(false)
const editingId = ref<number | null>(null)
const lName = ref('')
const lType = ref('')
const lSpecial = ref(false)
const lFrom = ref(new Date().toISOString().slice(0, 10))
const lTo = ref('')
const lBuy = ref('')
const lGet = ref('')
const lActive = ref(true)
const lNotes = ref('')
const listError = ref('')

function openCreate() {
  editingId.value = null
  lName.value = ''
  lType.value = ''
  lSpecial.value = false
  lFrom.value = new Date().toISOString().slice(0, 10)
  lTo.value = ''
  lBuy.value = ''
  lGet.value = ''
  lActive.value = true
  lNotes.value = ''
  listError.value = ''
  showListForm.value = true
}

function openEdit(list: PriceListRow) {
  editingId.value = list.id
  lName.value = list.name
  lType.value = list.customer_type ?? ''
  lSpecial.value = list.is_special
  lFrom.value = list.effective_from
  lTo.value = list.effective_to ?? ''
  lBuy.value = list.promo_buy_qty == null ? '' : String(list.promo_buy_qty)
  lGet.value = list.promo_get_qty == null ? '' : String(list.promo_get_qty)
  lActive.value = list.active
  lNotes.value = list.notes ?? ''
  listError.value = ''
  showListForm.value = true
}

async function saveList() {
  listError.value = ''
  const buy = lBuy.value.trim() === '' ? null : Number(lBuy.value)
  const get = lGet.value.trim() === '' ? null : Number(lGet.value)
  if (!lName.value.trim()) {
    listError.value = 'A name is required.'
    return
  }
  if (!lSpecial.value && !lType.value.trim()) {
    listError.value = 'A general list needs a customer type.'
    return
  }
  if ((buy == null) !== (get == null)) {
    listError.value = 'A promo needs both a buy quantity and a get quantity.'
    return
  }
  if (buy != null && (!Number.isInteger(buy) || buy <= 0 || !Number.isInteger(get!) || get! <= 0)) {
    listError.value = 'Promo quantities must be whole numbers above zero.'
    return
  }
  const input = {
    name: lName.value.trim(),
    customer_type: lType.value.trim() || null,
    is_special: lSpecial.value,
    effective_from: lFrom.value,
    effective_to: lTo.value || null,
    promo_buy_qty: lSpecial.value ? buy : null,
    promo_get_qty: lSpecial.value ? get : null,
    active: lActive.value,
    notes: lNotes.value.trim() || null,
  }
  try {
    if (editingId.value == null) {
      await createList.mutateAsync(input)
    } else {
      await updateList.mutateAsync({ id: editingId.value, ...input })
    }
    showListForm.value = false
  } catch (err) {
    listError.value = (err as { message?: string }).message || 'Save failed.'
  }
}

async function removeList(list: PriceListRow) {
  if (
    !window.confirm(
      `Delete "${list.name}" and its items? Existing orders keep their captured prices.`,
    )
  )
    return
  await deleteList.mutateAsync(list.id)
  if (itemsFor.value === list.id) itemsFor.value = null
}

/** Which list's item panel is open. */
const itemsFor = ref<number | null>(null)
const itemsQuery = usePriceListItems(itemsFor)

function toggleItems(list: PriceListRow) {
  itemsFor.value = itemsFor.value === list.id ? null : list.id
}

/**
 * Two live general lists for the same type is legal (a handover window) but
 * usually a mistake — warn, don't block. Mirrors the DB's stance.
 */
const overlapWarnings = computed(() => {
  const today = new Date().toISOString().slice(0, 10)
  const liveByType = new Map<string, number>()
  for (const l of listsQuery.data.value ?? []) {
    if (l.is_special || !l.active || !l.customer_type) continue
    if (l.effective_from > today) continue
    if (l.effective_to && l.effective_to < today) continue
    liveByType.set(l.customer_type, (liveByType.get(l.customer_type) ?? 0) + 1)
  }
  return [...liveByType.entries()].filter(([, n]) => n > 1).map(([t]) => t)
})

function rangeLabel(list: PriceListRow): string {
  const from = shortDate(list.effective_from)
  return list.effective_to ? `${from} – ${shortDate(list.effective_to)}` : `from ${from}`
}
</script>

<template>
  <div class="space-y-6">
    <!-- ============================== downloadable sheets -->
    <AppCard title="Downloadable sheets" hint="what reps see under Intel → Price Lists">
      <div class="space-y-4">
        <AsyncState
          :loading="filesQuery.isLoading.value"
          :error="filesQuery.error.value"
          :empty="(filesQuery.data.value ?? []).length === 0"
          empty-title="No sheets published"
          empty-body="Publish the approved Excel sheet for each customer type below."
          :rows="2"
          @retry="filesQuery.refetch()"
        >
          <ul class="divide-line divide-y">
            <li
              v-for="file in filesQuery.data.value"
              :key="file.id"
              class="flex flex-wrap items-center justify-between gap-3 py-3"
            >
              <div class="min-w-0">
                <p class="text-ink text-[15px] font-semibold">
                  {{ file.customer_type }} — {{ file.title }}
                </p>
                <p class="text-muted text-[13px]">
                  {{ file.file_name }} · {{ formatBytes(file.file_size) }} ·
                  {{ shortDate(file.uploaded_at) }}
                </p>
              </div>
              <AppButton variant="ghost" @click="removeFile(file)">Remove</AppButton>
            </li>
          </ul>
        </AsyncState>

        <div class="border-line grid gap-3 border-t pt-4 md:grid-cols-2">
          <label class="block">
            <span class="u-label text-ink block pb-2">Customer type</span>
            <input
              v-model="fType"
              list="admin-customer-types"
              class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              placeholder="Exactly as in the ERP"
            />
          </label>
          <label class="block">
            <span class="u-label text-ink block pb-2">Title</span>
            <input
              v-model="fTitle"
              class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              placeholder="2026 Dealer Price List"
            />
          </label>
          <label class="block md:col-span-2">
            <span class="u-label text-ink block pb-2">File (.xlsx, .xls, .csv, .pdf)</span>
            <input
              ref="fInput"
              type="file"
              accept=".xlsx,.xls,.csv,.pdf"
              class="border-line text-ink block w-full border p-2 text-[15px] file:mr-3 file:border-0 file:bg-transparent file:font-semibold"
            />
          </label>
          <p v-if="fileError" role="alert" class="text-danger text-sm md:col-span-2">
            {{ fileError }}
          </p>
          <p v-if="fileNotice" role="status" class="text-ink text-sm font-medium md:col-span-2">
            {{ fileNotice }}
          </p>
          <div>
            <AppButton
              variant="primary"
              :loading="uploadFile.isPending.value"
              @click="publishFile"
            >
              Publish sheet
            </AppButton>
          </div>
        </div>
      </div>
    </AppCard>

    <!-- ============================== structured lists -->
    <AppCard title="Order writer price lists" hint="what the order writer prices from">
      <div class="space-y-4">
        <p
          v-if="overlapWarnings.length"
          role="alert"
          class="border-line border-l-accent text-ink-2 border border-l-[3px] p-3 text-[14px]"
        >
          More than one active general list is effective today for:
          <strong class="text-ink">{{ overlapWarnings.join(', ') }}</strong
          >. Reps will be offered all of them — end-date the old one unless
          this is a deliberate handover.
        </p>

        <AsyncState
          :loading="listsQuery.isLoading.value"
          :error="listsQuery.error.value"
          :empty="(listsQuery.data.value ?? []).length === 0"
          empty-title="No price lists yet"
          empty-body="Create the general list for each customer type, then upload its items."
          :rows="2"
          @retry="listsQuery.refetch()"
        >
          <ul class="divide-line divide-y">
            <li v-for="list in listsQuery.data.value" :key="list.id" class="py-3">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <div class="min-w-0">
                  <p class="text-ink flex flex-wrap items-center gap-2 text-[15px] font-semibold">
                    {{ list.name }}
                    <AppBadge v-if="list.is_special" tone="high">Special</AppBadge>
                    <AppBadge v-if="!list.active" tone="neutral">Inactive</AppBadge>
                  </p>
                  <p class="text-muted text-[13px]">
                    {{ list.customer_type ?? 'All customer types' }} ·
                    {{ rangeLabel(list) }}
                    <template v-if="promoLabel(list)"> · {{ promoLabel(list) }}</template>
                  </p>
                </div>
                <div class="flex gap-2">
                  <AppButton variant="ghost" @click="toggleItems(list)">
                    {{ itemsFor === list.id ? 'Hide items' : 'Items' }}
                  </AppButton>
                  <AppButton variant="ghost" @click="openEdit(list)">Edit</AppButton>
                  <AppButton variant="ghost" @click="removeList(list)">Delete</AppButton>
                </div>
              </div>

              <div v-if="itemsFor === list.id" class="border-line mt-3 border p-4">
                <p class="text-ink-2 pb-3 text-[14px]">
                  <template v-if="itemsQuery.isLoading.value">Loading items…</template>
                  <template v-else>
                    {{ (itemsQuery.data.value ?? []).length }} items on this list.
                  </template>
                </p>
                <PriceListItemsUpload
                  :price-list-id="list.id"
                  @uploaded="itemsQuery.refetch()"
                />
              </div>
            </li>
          </ul>
        </AsyncState>

        <div v-if="!showListForm">
          <AppButton variant="secondary" @click="openCreate">New price list</AppButton>
        </div>

        <div v-else class="border-line space-y-3 border p-4">
          <p class="u-label text-ink">
            {{ editingId == null ? 'New price list' : 'Edit price list' }}
          </p>
          <div class="grid gap-3 md:grid-cols-2">
            <label class="block">
              <span class="u-label text-ink block pb-2">Name</span>
              <input
                v-model="lName"
                class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
                placeholder="2026 Dealer Pricing"
              />
            </label>
            <label class="block">
              <span class="u-label text-ink block pb-2">
                Customer type{{ lSpecial ? ' (blank = all types)' : '' }}
              </span>
              <input
                v-model="lType"
                list="admin-customer-types"
                class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              />
            </label>
            <label class="block">
              <span class="u-label text-ink block pb-2">Effective from</span>
              <input
                v-model="lFrom"
                type="date"
                class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              />
            </label>
            <label class="block">
              <span class="u-label text-ink block pb-2">Effective to (blank = open)</span>
              <input
                v-model="lTo"
                type="date"
                class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              />
            </label>
            <label class="flex min-h-12 items-center gap-2">
              <input v-model="lSpecial" type="checkbox" class="size-5" />
              <span class="text-ink text-[15px]">Special (promo list)</span>
            </label>
            <label class="flex min-h-12 items-center gap-2">
              <input v-model="lActive" type="checkbox" class="size-5" />
              <span class="text-ink text-[15px]">Active</span>
            </label>
            <template v-if="lSpecial">
              <label class="block">
                <span class="u-label text-ink block pb-2">Promo: buy qty</span>
                <input
                  v-model="lBuy"
                  type="number"
                  min="1"
                  step="1"
                  class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
                  placeholder="10"
                />
              </label>
              <label class="block">
                <span class="u-label text-ink block pb-2">Promo: get qty</span>
                <input
                  v-model="lGet"
                  type="number"
                  min="1"
                  step="1"
                  class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
                  placeholder="2"
                />
              </label>
              <p class="text-muted text-[13px] md:col-span-2">
                Settled as a prorated percent off the qualifying lines — buy 10
                get 2 shows up as 16.67% off once 12 units are on the order,
                never as free goods.
              </p>
            </template>
            <label class="block md:col-span-2">
              <span class="u-label text-ink block pb-2">Notes</span>
              <input
                v-model="lNotes"
                class="border-line text-ink min-h-12 w-full border px-3 text-[15px]"
              />
            </label>
          </div>
          <p v-if="listError" role="alert" class="text-danger text-sm">{{ listError }}</p>
          <div class="flex gap-2">
            <AppButton
              variant="primary"
              :loading="createList.isPending.value || updateList.isPending.value"
              @click="saveList"
            >
              Save
            </AppButton>
            <AppButton variant="ghost" @click="showListForm = false">Cancel</AppButton>
          </div>
        </div>
      </div>
    </AppCard>

    <datalist id="admin-customer-types">
      <option
        v-for="t in customerTypes.data.value ?? []"
        :key="t.customer_type"
        :value="t.customer_type"
      >
        {{ t.customer_count }} customers
      </option>
    </datalist>
  </div>
</template>
