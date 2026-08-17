<script setup lang="ts">
import { computed } from 'vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import { fflSentence, fflStatus, isCreditBlocked } from '@/lib/ffl'
import { humanize, money, shortDate } from '@/lib/format'

/**
 * "Can we ship to this dealer?" — the question a rep should ask before
 * writing an order, and which the portal could not answer at all.
 *
 * Two things stop a shipment and neither was visible:
 *
 *   FFL. An expired Federal Firearms License blocks the shipment outright.
 *   ffl_license_number and ffl_expiration_raw have been landed on BOTH
 *   dim_customer and dim_ship_to since 002 and read by nothing. The rep is
 *   the person with the relationship and the one who could get a renewal
 *   chased — they were the last to know.
 *
 *   Credit. The page rendered credit_status as one bare humanized word with
 *   no limit and no terms beside it, so "Hold" looked like a detail rather
 *   than a stop sign. A rep could write orders all afternoon for an account
 *   that cannot receive them.
 *
 * ── Renders nothing when there is nothing to say ──────────────────────────
 * A valid licence and normal credit produce no output. This strip is an
 * exception reporter: if it is on screen, something needs attention. That is
 * also what makes it safe against sparse data — an account with no FFL on
 * file is silent rather than accusing, because a blank ERP field is not
 * evidence that a dealer is unlicensed. See docs note in lib/ffl.ts.
 */

const props = defineProps<{
  fflLicenseNumber: string | null | undefined
  fflExpirationRaw: string | null | undefined
  creditStatus: string | null | undefined
  creditLimitAmount: number | null | undefined
  arTermsRuleId: string | null | undefined
}>()

const ffl = computed(() =>
  fflStatus(props.fflLicenseNumber, props.fflExpirationRaw),
)
const fflLine = computed(() => fflSentence(ffl.value))
const creditBlocked = computed(() => isCreditBlocked(props.creditStatus))

/** Tone follows severity: expired or on hold is a stop, expiring is a nudge. */
const stopped = computed(
  () => creditBlocked.value || ffl.value.state === 'expired',
)

/** Nothing to report → render nothing at all. */
const show = computed(() => creditBlocked.value || fflLine.value !== null)

/** The credit detail the bare status word was missing. */
const creditDetail = computed(() => {
  const parts: string[] = []
  if (props.creditLimitAmount != null) {
    parts.push(`Limit ${money(props.creditLimitAmount)}`)
  }
  if (props.arTermsRuleId) parts.push(`Terms ${props.arTermsRuleId}`)
  return parts.join(' · ')
})
</script>

<template>
  <div
    v-if="show"
    class="border-line bg-surface border border-l-[3px] px-4 py-3"
    :class="stopped ? 'border-l-danger' : 'border-l-accent'"
    role="note"
  >
    <p class="font-label text-muted text-[11px] font-semibold tracking-[0.14em] uppercase">
      Before you write an order
    </p>

    <div v-if="creditBlocked" class="mt-2">
      <div class="flex flex-wrap items-center gap-2">
        <AppBadge tone="high">
          Credit {{ humanize(creditStatus) }}
        </AppBadge>
        <span v-if="creditDetail" class="text-ink-2 text-sm">
          {{ creditDetail }}
        </span>
      </div>
      <p class="text-muted mt-1 text-[13px]">
        Orders on this account may not release. Check with credit before
        promising a date.
      </p>
    </div>

    <div v-if="fflLine" class="mt-2">
      <div class="flex flex-wrap items-center gap-2">
        <AppBadge :tone="ffl.state === 'expired' ? 'high' : 'late'">
          {{ fflLine }}
        </AppBadge>
        <span v-if="ffl.licenseNumber" class="text-ink-2 text-sm tabular-nums">
          {{ ffl.licenseNumber }}
        </span>
      </div>
      <p v-if="ffl.expiresOn" class="text-muted mt-1 text-[13px]">
        On file through {{ shortDate(ffl.expiresOn) }}.
        <template v-if="ffl.state === 'expired'">
          Firearms can't ship against an expired licence — a renewed copy
          needs to reach us.
        </template>
        <template v-else>
          Worth asking for the renewal before it lapses.
        </template>
      </p>
      <!-- Unparseable: show exactly what the ERP holds and claim nothing. The
           field is free-form, so a confident wrong date is the one outcome
           worse than no date. -->
      <p v-else class="text-muted mt-1 text-[13px]">
        We can't read that as a date, so it isn't being checked. Worth
        confirming the licence is current.
      </p>
    </div>
  </div>
</template>
