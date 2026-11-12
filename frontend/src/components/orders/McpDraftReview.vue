<script setup lang="ts">
import { computed } from 'vue'
import OrderSourceBadge from '@/components/orders/OrderSourceBadge.vue'
import { emailSourceRef, isNoPoWarning, warningList } from '@/lib/mcpOrders'
import { shortDate } from '@/lib/format'

/**
 * The review block for a Claude-drafted order (source <> 'portal'): what the
 * server flagged when the draft was made, the email it came from when there
 * was one, and — while it is still a draft — the acknowledgement that gates
 * Submit. submit_order() refuses the order without it (acknowledge_required),
 * so the checkbox is the only way through, not a courtesy.
 *
 * Phone first: reps open the portal link Claude hands them on a phone, so
 * this stacks in one column with a full-width tap target on the checkbox.
 */
const props = withDefaults(
  defineProps<{
    source: string | null | undefined
    warnings: unknown
    sourceRef: unknown
    /** Show the acknowledgement checkbox (drafts the viewer may submit). */
    showAck?: boolean
    /** The warnings were computed before a portal edit and may be stale. */
    edited?: boolean
    /**
     * A draft with no customer PO right now: "No customer PO: it will be
     * submitted as PORTAL-<id>." (lib/mcpOrders noPoHint), or '' when there
     * is one. A PO is optional since 20261113090000.
     */
    poHint?: string
    /**
     * The order has a customer PO now. The server's "No customer PO" warning
     * was stored when Claude drafted it; once a PO is added it is not true.
     */
    hasPo?: boolean
  }>(),
  { showAck: false, edited: false, poHint: '', hasPo: false },
)

const acknowledged = defineModel<boolean>('acknowledged', { default: false })

const warningsList = computed(() =>
  warningList(props.warnings).filter((w) => !(props.hasPo && isNoPoWarning(w))),
)
const email = computed(() => emailSourceRef(props.sourceRef))
/**
 * The server flags a blank PO in the same words when Claude drafts the order
 * (mcp_order_preview), so the line is only added when that warning is not
 * already listed: a draft from before the PO became optional, or a PO
 * cleared in the portal since.
 */
const showPoHint = computed(() => !!props.poHint && !warningsList.value.some(isNoPoWarning))
</script>

<template>
  <section
    class="border-line border-l-accent bg-surface space-y-3 border border-l-[3px] px-4 py-3"
    aria-label="Drafted by Claude"
  >
    <div class="flex flex-wrap items-center gap-2">
      <OrderSourceBadge :source="source" />
      <p class="text-ink-2 text-[14px]">
        Claude wrote this draft. Check the account, ship-to, products and
        quantities before submitting.
      </p>
    </div>

    <p v-if="showPoHint" class="text-muted text-[13px]">{{ poHint }}</p>

    <div v-if="warningsList.length">
      <p class="u-label text-ink pb-1">
        Flagged when drafted<span v-if="edited" class="text-muted normal-case tracking-normal">
          (before your edits)</span
        >
      </p>
      <ul class="text-ink-2 list-disc space-y-1 pl-5 text-[14px]">
        <!-- By position: two lines of one part can give the same sentence. -->
        <li v-for="(w, i) in warningsList" :key="i" class="break-words">{{ w }}</li>
      </ul>
    </div>

    <div v-if="email" class="border-line bg-canvas border px-3 py-2">
      <p class="u-label text-ink pb-1">From an email</p>
      <dl class="text-[13px]">
        <div v-if="email.sender" class="flex flex-wrap gap-x-2">
          <dt class="text-muted">From</dt>
          <dd class="text-ink min-w-0 break-words">{{ email.sender }}</dd>
        </div>
        <div v-if="email.subject" class="flex flex-wrap gap-x-2">
          <dt class="text-muted">Subject</dt>
          <dd class="text-ink min-w-0 break-words">{{ email.subject }}</dd>
        </div>
        <div v-if="email.received_at" class="flex flex-wrap gap-x-2">
          <dt class="text-muted">Received</dt>
          <dd class="text-ink">{{ shortDate(email.received_at) }}</dd>
        </div>
      </dl>
      <!-- Untrusted text: rendered as text, never as HTML. -->
      <p
        v-if="email.excerpt"
        class="text-ink-2 mt-2 max-h-48 overflow-y-auto text-[13px] break-words whitespace-pre-wrap"
      >{{ email.excerpt }}</p>
    </div>

    <label
      v-if="showAck"
      class="border-line bg-canvas flex min-h-12 cursor-pointer items-start gap-3 border px-3 py-3"
    >
      <input v-model="acknowledged" type="checkbox" class="mt-0.5 size-6 shrink-0" />
      <span class="text-ink text-[15px] font-semibold">
        I've reviewed this order and it is correct
      </span>
    </label>
  </section>
</template>
