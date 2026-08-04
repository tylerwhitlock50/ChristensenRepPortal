<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import AppButton from '@/components/ui/AppButton.vue'
import AppCard from '@/components/ui/AppCard.vue'
import AppBadge from '@/components/ui/AppBadge.vue'
import AsyncState from '@/components/ui/AsyncState.vue'
import FeatureFlagsCard from '@/components/admin/FeatureFlagsCard.vue'
import {
  FACTOR_HELP,
  FACTOR_LABELS,
  SCORE_FACTORS,
  friendlyScoreError,
  usePreviewScores,
  useRuleSettings,
  useSaveScoreSettings,
  useScoreSettings,
  type PreviewInput,
  type ScoreFactor,
  type ScoreWeights,
} from '@/composables/useScoreSettings'

/**
 * Tuning for the recommendation engine.
 *
 * The shape is lifted from AdminMissionsView on purpose: edit, PREVIEW, then
 * save — and any edit voids the preview, so nobody saves a change they have
 * not seen the size of. That matters more here than it does for a mission,
 * because these values apply to every account in the book at once and the
 * 015 last_order_date fix widened what the rules can see.
 */
const settings = useScoreSettings()
const rules = useRuleSettings()

/* ---- the form ----------------------------------------------------------
   Local copies, seeded once the queries land. Editing writes nothing until
   Save; nothing here mutates the cached query data.
------------------------------------------------------------------------- */
const weights = ref<ScoreWeights>({
  cadence: 30, recency: 20, trend: 20, value: 20, mix: 10,
})
const params = ref<Record<string, Record<string, unknown>>>({})
const priorityHigh = ref(70)
const priorityLow = ref(35)
const ruleState = ref<Record<string, { enabled: boolean; params: Record<string, unknown> }>>({})
const seeded = ref(false)

watch(
  () => [settings.data.value, rules.data.value] as const,
  ([s, r]) => {
    if (!s || !r || seeded.value) return
    weights.value = { ...s.weights }
    params.value = JSON.parse(JSON.stringify(s.params))
    priorityHigh.value = Number(s.priority_high)
    priorityLow.value = Number(s.priority_low)
    ruleState.value = Object.fromEntries(
      r.map((rule) => [
        rule.rule_key,
        { enabled: rule.enabled, params: JSON.parse(JSON.stringify(rule.params)) },
      ]),
    )
    seeded.value = true
  },
  { immediate: true },
)

/**
 * Weights are relative — the score renormalizes over whichever factors had
 * something to judge — so this readout is the honest way to show what a
 * number means without pretending they must total 100.
 */
const weightTotal = computed(() =>
  SCORE_FACTORS.reduce((sum, f) => sum + (Number(weights.value[f]) || 0), 0),
)
function sharePct(factor: ScoreFactor): number {
  if (weightTotal.value <= 0) return 0
  return Math.round(((Number(weights.value[factor]) || 0) / weightTotal.value) * 100)
}

/** Rule params worth exposing, with a label. Anything else stays jsonb. */
const RULE_FIELDS: Record<string, { key: string; label: string; suffix?: string }[]> = {
  no_order_days: [
    { key: 'days', label: 'Days without an order', suffix: 'days' },
    { key: 'min_trailing_12m_revenue', label: 'Minimum trailing 12m revenue', suffix: '$' },
    { key: 'min_score', label: 'Minimum priority score' },
    { key: 'resolve_cooldown_days', label: 'Silence after a rep closes it', suffix: 'days' },
    { key: 'false_positive_cooldown_days', label: 'Silence after a false positive', suffix: 'days' },
  ],
  yoy_decline: [
    { key: 'decline_pct', label: 'Decline vs last year', suffix: '%' },
    { key: 'min_prior_ytd_revenue', label: 'Minimum prior-year revenue', suffix: '$' },
    { key: 'min_score', label: 'Minimum priority score' },
    { key: 'resolve_cooldown_days', label: 'Silence after a rep closes it', suffix: 'days' },
    { key: 'false_positive_cooldown_days', label: 'Silence after a false positive', suffix: 'days' },
  ],
  cadence_overdue: [
    { key: 'trigger_ratio', label: 'Times their normal gap', suffix: '×' },
    { key: 'min_trailing_12m_revenue', label: 'Minimum trailing 12m revenue', suffix: '$' },
    { key: 'min_score', label: 'Minimum priority score' },
    { key: 'resolve_cooldown_days', label: 'Silence after a rep closes it', suffix: 'days' },
    { key: 'false_positive_cooldown_days', label: 'Silence after a false positive', suffix: 'days' },
  ],
}

const RULE_LABELS: Record<string, string> = {
  no_order_days: 'No order in N days',
  yoy_decline: 'Revenue down year on year',
  cadence_overdue: 'Overdue against their own rhythm',
}

/* ---- preview / save ----------------------------------------------------- */
const preview = usePreviewScores()
const save = useSaveScoreSettings()

const previewed = ref(false)
const errorMessage = ref('')
const savedNotice = ref('')

function currentInput(): PreviewInput {
  return {
    weights: { ...weights.value },
    params: params.value,
    priorityHigh: Number(priorityHigh.value),
    priorityLow: Number(priorityLow.value),
    rules: ruleState.value,
  }
}

const bandsValid = computed(() => Number(priorityLow.value) < Number(priorityHigh.value))

/** Any edit voids the preview — straight from the mission composer. */
watch(
  [weights, params, priorityHigh, priorityLow, ruleState],
  () => {
    if (!seeded.value) return
    previewed.value = false
    savedNotice.value = ''
  },
  { deep: true },
)

async function runPreview() {
  errorMessage.value = ''
  savedNotice.value = ''
  if (!bandsValid.value) {
    errorMessage.value = 'The "high" band has to be above the "low" band.'
    return
  }
  try {
    await preview.mutateAsync(currentInput())
    previewed.value = true
  } catch (e) {
    errorMessage.value = friendlyScoreError(e)
  }
}

async function runSave() {
  errorMessage.value = ''
  try {
    const result = await save.mutateAsync(currentInput())
    savedNotice.value = result.rescored
      ? 'Saved. Every account has been re-scored.'
      : 'Saved. Re-scoring did not finish in time — tonight\'s run will apply it.'
    previewed.value = false
  } catch (e) {
    errorMessage.value = friendlyScoreError(e)
  }
}

const previewRows = computed(() => preview.data.value?.rows ?? [])
const previewCounts = computed(() => preview.data.value?.counts ?? [])
const totalWouldCreate = computed(() =>
  previewCounts.value.reduce((n, c) => n + (c.would_create ?? 0), 0),
)

function topWhy(row: (typeof previewRows.value)[number]): string {
  const entries = Object.values(row.factors ?? {})
    .filter((f) => f?.why)
    .sort((a, b) => (b.contribution ?? 0) - (a.contribution ?? 0))
  return entries[0]?.why ?? ''
}
</script>

<template>
  <div class="space-y-5">
    <header>
      <p class="font-label text-muted text-xs font-semibold tracking-[0.18em] uppercase">
        Settings
      </p>
      <h1 class="u-display mt-1 text-4xl">How work gets prioritised</h1>
      <p class="text-muted mt-2 text-[15px]">
        These values decide what every rep sees first. Preview before you save —
        a change here lands on the whole book at once.
      </p>
    </header>

    <!-- Feature flags (data-first restructure) sit above the scoring tuning:
         which surfaces exist at all comes before how work is ranked. -->
    <FeatureFlagsCard />

    <AsyncState
      :loading="settings.isPending.value || rules.isPending.value"
      :error="settings.error.value || rules.error.value"
      :rows="3"
      @retry="settings.refetch(); rules.refetch()"
    >
      <div class="space-y-5">
        <!-- Weights -->
        <AppCard title="What matters, and how much">
          <template #hint>
            Relative, not percentages — the score divides by whichever factors
            had something to judge, so these do not need to total anything.
          </template>

          <ul class="divide-line divide-y">
            <li v-for="f in SCORE_FACTORS" :key="f" class="py-3 first:pt-0 last:pb-0">
              <div class="flex flex-wrap items-center gap-3">
                <label class="min-w-0 flex-1" :for="`w-${f}`">
                  <span class="text-ink block text-[15px] font-semibold">
                    {{ FACTOR_LABELS[f] }}
                  </span>
                  <span class="text-muted mt-0.5 block text-sm">{{ FACTOR_HELP[f] }}</span>
                </label>
                <div class="flex shrink-0 items-center gap-2">
                  <input
                    :id="`w-${f}`"
                    v-model.number="weights[f]"
                    type="number"
                    min="0"
                    max="100"
                    class="field w-20 text-center"
                  />
                  <span class="text-muted w-12 text-right text-sm tabular-nums">
                    {{ sharePct(f) }}%
                  </span>
                </div>
              </div>
            </li>
          </ul>

          <p v-if="weightTotal <= 0" role="alert" class="text-danger mt-3 text-sm font-medium">
            At least one factor needs a weight above zero, or nothing can be ranked.
          </p>
        </AppCard>

        <!-- Bands -->
        <AppCard title="Priority bands">
          <template #hint>
            Where a score turns into the high / normal / low badge a rep sees.
          </template>
          <div class="flex flex-wrap gap-4">
            <label class="min-w-32 flex-1">
              <span class="u-label mb-1.5 block">High at or above</span>
              <input v-model.number="priorityHigh" type="number" min="0" max="100" class="field" />
            </label>
            <label class="min-w-32 flex-1">
              <span class="u-label mb-1.5 block">Low below</span>
              <input v-model.number="priorityLow" type="number" min="0" max="100" class="field" />
            </label>
          </div>
          <p v-if="!bandsValid" role="alert" class="text-danger mt-2 text-sm font-medium">
            The "high" band has to be above the "low" band.
          </p>
        </AppCard>

        <!-- Rules -->
        <AppCard title="Which rules fire">
          <template #hint>
            The score ranks the queue; these decide what gets into it at all.
          </template>

          <div class="space-y-5">
            <section
              v-for="(rule, key) in ruleState"
              :key="key"
              class="border-line border-t pt-4 first:border-t-0 first:pt-0"
            >
              <div class="flex flex-wrap items-center gap-3">
                <h3 class="text-ink min-w-0 flex-1 text-[15px] font-semibold">
                  {{ RULE_LABELS[key] ?? key }}
                  <AppBadge v-if="!rule.enabled" tone="neutral" class="ml-2">Off</AppBadge>
                </h3>
                <button
                  type="button"
                  class="tap-target rounded-[2px] px-4 text-[15px] font-semibold"
                  :class="
                    rule.enabled
                      ? 'bg-ink text-canvas'
                      : 'border-line-2 text-ink-2 border bg-transparent'
                  "
                  :aria-pressed="rule.enabled"
                  @click="rule.enabled = !rule.enabled"
                >
                  {{ rule.enabled ? 'On' : 'Off' }}
                </button>
              </div>

              <div class="mt-3 grid gap-3 sm:grid-cols-2">
                <label v-for="field in RULE_FIELDS[key] ?? []" :key="field.key">
                  <span class="u-label mb-1.5 block">
                    {{ field.label }}
                    <span v-if="field.suffix" class="normal-case">({{ field.suffix }})</span>
                  </span>
                  <input
                    v-model.number="rule.params[field.key]"
                    type="number"
                    step="any"
                    min="0"
                    class="field"
                  />
                </label>
              </div>
            </section>
          </div>
        </AppCard>

        <!-- Preview / save -->
        <AppCard title="Before you save">
          <p class="text-muted text-[15px]">
            Preview re-scores every account with the values above and writes
            nothing. Saving applies them to the whole book.
          </p>

          <p v-if="errorMessage" role="alert" class="text-danger mt-3 text-sm font-medium">
            {{ errorMessage }}
          </p>
          <p v-if="savedNotice" role="status" class="text-ink mt-3 text-sm font-medium">
            {{ savedNotice }}
          </p>

          <div class="mt-4 flex flex-wrap gap-2">
            <AppButton
              variant="secondary"
              :loading="preview.isPending.value"
              :disabled="!bandsValid || weightTotal <= 0"
              @click="runPreview"
            >
              Preview
            </AppButton>
            <!-- The one primary on this view, and it stays out of reach until
                 the admin has actually looked at the consequences. -->
            <AppButton
              variant="primary"
              :loading="save.isPending.value"
              :disabled="!previewed"
              @click="runSave"
            >
              Save and re-score
            </AppButton>
          </div>
          <p v-if="!previewed" class="text-muted mt-2 text-sm">
            Preview first — Save unlocks once you have seen what changes.
          </p>
        </AppCard>

        <!-- Results -->
        <template v-if="previewed">
          <AppCard title="What tonight would create">
            <p class="u-display text-3xl">{{ totalWouldCreate }}</p>
            <p class="text-muted mt-1 text-[15px]">
              new recommendations across the book, on the next run.
            </p>
            <ul class="divide-line mt-3 divide-y">
              <li
                v-for="c in previewCounts"
                :key="c.rule_key"
                class="flex items-center justify-between py-2 text-[15px]"
              >
                <span class="text-ink-2">{{ RULE_LABELS[c.rule_key] ?? c.rule_key }}</span>
                <span class="u-display text-xl tabular-nums">{{ c.would_create }}</span>
              </li>
            </ul>
          </AppCard>

          <AppCard title="Top accounts under these settings" :padded="false">
            <div class="overflow-x-auto">
              <table class="w-full text-left text-sm">
                <thead class="border-line text-muted font-label border-b">
                  <tr>
                    <th class="px-4 py-2 font-semibold tracking-[0.1em] uppercase">Account</th>
                    <th class="px-4 py-2 text-right font-semibold tracking-[0.1em] uppercase">
                      Score
                    </th>
                    <th class="px-4 py-2 font-semibold tracking-[0.1em] uppercase">Why</th>
                  </tr>
                </thead>
                <tbody class="divide-line divide-y">
                  <tr v-for="row in previewRows" :key="row.customer_key">
                    <td class="px-4 py-2">
                      <span class="text-ink font-semibold">
                        {{ row.customer_name || row.customer_key }}
                      </span>
                    </td>
                    <td class="px-4 py-2 text-right tabular-nums">
                      <span class="u-display text-lg">{{ row.score }}</span>
                      <AppBadge
                        :tone="row.priority === 'high' ? 'high' : 'neutral'"
                        class="ml-2"
                      >
                        {{ row.priority }}
                      </AppBadge>
                    </td>
                    <td class="text-muted px-4 py-2">{{ topWhy(row) }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </AppCard>
        </template>
      </div>
    </AsyncState>
  </div>
</template>
