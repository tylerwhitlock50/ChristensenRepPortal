<script setup lang="ts">
import { ref, watch } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import { useUpdateAppSetting, type AppSettingRow } from '@/composables/useAppSettings'
import {
  MCP_ORDERS_LIMIT_FIELDS,
  parseMcpOrdersParams,
  validateMcpOrdersParams,
  type McpOrdersParams,
} from '@/lib/mcpOrders'

/**
 * The feature.mcp_orders params: the caps the server holds every draft to
 * (mcp_orders_gate / mcp_create_order_draft). Admin only — rendered from
 * FeatureFlagsCard under the flag's own switch. WHO may draft is not here:
 * it is the mcp_order_users table, edited in McpOrderUsersEditor.
 */
const props = defineProps<{ row: AppSettingRow }>()

const update = useUpdateAppSetting()

const form = ref<McpOrdersParams>(parseMcpOrdersParams(props.row.params))
const dirty = ref(false)
const error = ref('')
const saved = ref(false)

// A save (or another admin's change) re-seeds the form unless mid-edit.
watch(
  () => props.row.params,
  (p) => {
    if (!dirty.value) form.value = parseMcpOrdersParams(p)
  },
)

function touch() {
  dirty.value = true
  saved.value = false
}

async function save() {
  error.value = ''
  const checked = validateMcpOrdersParams(form.value)
  if (!checked.ok) {
    error.value = checked.error
    return
  }
  try {
    await update.mutateAsync({
      setting_key: props.row.setting_key,
      // Drop a stale allowed_user_ids: the list lives in mcp_order_users now.
      params: { ...withoutAllowList(props.row.params), ...checked.params },
    })
    dirty.value = false
    saved.value = true
  } catch (e) {
    error.value = (e as Error).message || 'Could not save that.'
  }
}

function withoutAllowList(params: Record<string, unknown>): Record<string, unknown> {
  const rest = { ...params }
  delete rest.allowed_user_ids
  return rest
}

function reset() {
  form.value = parseMcpOrdersParams(props.row.params)
  dirty.value = false
  error.value = ''
}
</script>

<template>
  <div class="bg-canvas border-line space-y-4 border-t px-4 py-3">
    <p class="u-label text-ink">Limits on every Claude draft</p>
    <div class="grid gap-3 sm:grid-cols-2">
      <label v-for="f in MCP_ORDERS_LIMIT_FIELDS" :key="f.key" class="block">
        <span class="u-label text-ink block pb-1">{{ f.label }}</span>
        <input
          v-model.number="form[f.key]"
          type="number"
          min="1"
          step="1"
          inputmode="numeric"
          class="border-line bg-surface text-ink min-h-11 w-full border px-3 text-[15px]"
          @input="touch"
        />
      </label>
    </div>

    <p v-if="error" role="alert" class="text-danger text-sm font-medium">{{ error }}</p>
    <p v-else-if="saved" class="text-muted text-sm">Saved.</p>

    <div class="flex flex-wrap gap-2">
      <AppButton
        variant="primary"
        :loading="update.isPending.value"
        :disabled="!dirty"
        @click="save"
      >
        Save drafting settings
      </AppButton>
      <AppButton v-if="dirty" variant="ghost" @click="reset">Undo changes</AppButton>
    </div>
  </div>
</template>
