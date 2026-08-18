<script setup lang="ts">
import { computed, ref } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import { parseCsv } from '@/lib/csv'
import { money } from '@/lib/format'
import { erp } from '@/lib/supabase'
import {
  useReplacePriceListItems,
  type PriceListItemInput,
} from '@/composables/usePriceLists'

/**
 * Per-list item upload: "Save as CSV" from the approved Excel sheet, columns
 * part_id, description, unit_price (a header row is detected and skipped).
 * The description column is a FALLBACK only: the app reads items through
 * v_price_list_items, where the ERP part master's description and
 * family/caliber attributes win whenever dim_part knows the part. The
 * uploaded text only ever shows for SKUs the ERP doesn't have yet.
 *
 * Same shape as the missions composer: parse → PREVIEW → confirm, and any
 * change of file voids the preview. The upload REPLACES the list's items —
 * that is what "the new approved sheet" means — and the confirm button says
 * so. Part numbers are cross-checked against erp.dim_part as a warning, not
 * a block: the ERP part master occasionally lags a new SKU the sheet
 * legitimately carries.
 */
const props = defineProps<{ priceListId: number }>()
const emit = defineEmits<{ uploaded: [count: number] }>()

const replaceItems = useReplacePriceListItems()

const fileName = ref('')
const parseErrors = ref<string[]>([])
const parsed = ref<PriceListItemInput[]>([])
const unknownParts = ref<string[]>([])
const checkingParts = ref(false)
const done = ref('')

const preview = computed(() => parsed.value.slice(0, 20))

function reset() {
  fileName.value = ''
  parseErrors.value = []
  parsed.value = []
  unknownParts.value = []
  done.value = ''
}

async function onFile(event: Event) {
  reset()
  const input = event.target as HTMLInputElement
  const file = input.files?.[0]
  input.value = ''
  if (!file) return
  fileName.value = file.name

  const rows = parseCsv(await file.text())
  if (rows.length === 0) {
    parseErrors.value = ['The file has no rows.']
    return
  }

  // A header row is any first row whose price column is not a number.
  const startAt = Number.isFinite(Number(rows[0][2] ?? rows[0][1])) ? 0 : 1

  const errors: string[] = []
  const items: PriceListItemInput[] = []
  const seen = new Set<string>()

  rows.slice(startAt).forEach((row, index) => {
    const line = startAt + index + 1
    const [partRaw, descriptionRaw, priceRaw] = row
    // Two-column sheets (part, price) are fine too.
    const hasDescription = row.length >= 3
    const partId = (partRaw ?? '').trim()
    const priceText = ((hasDescription ? priceRaw : descriptionRaw) ?? '').trim()
    const price = Number(priceText.replace(/[$,]/g, ''))

    if (!partId) {
      errors.push(`Line ${line}: missing part number`)
      return
    }
    if (seen.has(partId)) {
      errors.push(`Line ${line}: duplicate part ${partId}`)
      return
    }
    if (!priceText || !Number.isFinite(price) || price < 0) {
      errors.push(`Line ${line}: "${priceText}" is not a price`)
      return
    }
    seen.add(partId)
    items.push({
      part_id: partId,
      description: hasDescription ? (descriptionRaw ?? '').trim() || null : null,
      unit_price: Math.round(price * 100) / 100,
    })
  })

  parseErrors.value = errors
  parsed.value = errors.length === 0 ? items : []
  if (parsed.value.length > 0) void checkParts(parsed.value)
}

/** Warn (never block) on part numbers the ERP part master doesn't know. */
async function checkParts(items: PriceListItemInput[]) {
  checkingParts.value = true
  try {
    const known = new Set<string>()
    const ids = items.map((i) => i.part_id)
    for (let i = 0; i < ids.length; i += 200) {
      const { data, error } = await erp
        .from('dim_part' as never)
        .select('part_id')
        .in('part_id', ids.slice(i, i + 200))
      if (error) throw error
      for (const row of (data ?? []) as { part_id: string | null }[]) {
        if (row.part_id) known.add(row.part_id)
      }
    }
    unknownParts.value = ids.filter((id) => !known.has(id))
  } catch {
    // The check is advisory; a failed lookup must not stop a valid upload.
    unknownParts.value = []
  } finally {
    checkingParts.value = false
  }
}

async function confirm() {
  if (parsed.value.length === 0) return
  const count = await replaceItems.mutateAsync({
    priceListId: props.priceListId,
    items: parsed.value,
  })
  done.value = `${count} items saved.`
  parsed.value = []
  fileName.value = ''
  unknownParts.value = []
  emit('uploaded', count)
}
</script>

<template>
  <div class="space-y-3">
    <label class="block">
      <span class="u-label text-ink block pb-2">Upload items (CSV)</span>
      <input
        type="file"
        accept=".csv,text/csv"
        class="border-line text-ink block w-full border p-2 text-[15px] file:mr-3 file:border-0 file:bg-transparent file:font-semibold"
        @change="onFile"
      />
      <span class="text-muted mt-1 block text-[13px]">
        Columns: part number, description, unit price — “Save as CSV” from the
        approved sheet. Uploading replaces every item on this list.
        Descriptions come from the ERP part master when it knows the part;
        the sheet's description only shows for SKUs the ERP doesn't have yet.
      </span>
    </label>

    <div v-if="parseErrors.length" role="alert" class="space-y-1">
      <p class="text-danger text-sm font-semibold">
        {{ fileName }} can't be loaded:
      </p>
      <ul class="text-danger list-inside list-disc text-[13px]">
        <li v-for="msg in parseErrors.slice(0, 10)" :key="msg">{{ msg }}</li>
        <li v-if="parseErrors.length > 10">…and {{ parseErrors.length - 10 }} more</li>
      </ul>
    </div>

    <div v-if="parsed.length" class="space-y-3">
      <p class="text-ink text-sm font-medium">
        {{ fileName }} — {{ parsed.length }} items. Showing the first
        {{ preview.length }}:
      </p>
      <div class="border-line max-h-64 overflow-y-auto border">
        <table class="w-full text-[13px]">
          <thead class="bg-canvas sticky top-0">
            <tr class="text-muted text-left">
              <th class="px-3 py-2 font-semibold">Part</th>
              <th class="px-3 py-2 font-semibold">Description</th>
              <th class="px-3 py-2 text-right font-semibold">Price</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="item in preview" :key="item.part_id" class="border-line border-t">
              <td class="text-ink px-3 py-1.5 font-medium">{{ item.part_id }}</td>
              <td class="text-ink-2 px-3 py-1.5">{{ item.description || '—' }}</td>
              <td class="text-ink px-3 py-1.5 text-right">{{ money(item.unit_price) }}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <p v-if="checkingParts" class="text-muted text-[13px]">
        Checking part numbers against the ERP…
      </p>
      <p v-else-if="unknownParts.length" class="text-ink-2 text-[13px]">
        <strong class="text-ink">Heads up:</strong> the ERP part master doesn't
        know {{ unknownParts.length }} of these —
        {{ unknownParts.slice(0, 5).join(', ') }}<span v-if="unknownParts.length > 5"
          >, …</span
        >. They'll still upload; the QC step will flag them if they never ship.
      </p>

      <p v-if="replaceItems.error.value" role="alert" class="text-danger text-sm">
        {{ (replaceItems.error.value as { message?: string }).message }}
      </p>

      <AppButton
        variant="primary"
        :loading="replaceItems.isPending.value"
        @click="confirm"
      >
        Replace items with these {{ parsed.length }}
      </AppButton>
    </div>

    <p v-if="done" role="status" class="text-ink text-sm font-medium">{{ done }}</p>
  </div>
</template>
