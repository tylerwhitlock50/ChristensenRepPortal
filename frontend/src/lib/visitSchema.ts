/**
 * The structured visit survey — PRD §7 "Structured visit survey
 * (GoSpotCheck-style)".
 *
 * This schema mirrors `public.visits` (005_app_execution.sql) field for field,
 * including its CHECK constraints, so a form that validates here cannot be
 * rejected by Postgres.
 *
 * Design rule that outranks completeness: acceptance criterion #5 says a rep
 * must be able to finish a survey on a phone in under 60 seconds. So only
 * `visit_type` is required — and even that is pre-filled — and every other
 * answer is nullable. A nearly-empty survey is a successful survey; a blocked
 * rep is a lost one.
 *
 * No `z.union()` anywhere on purpose: @vee-validate/zod 4.15 still reads the
 * zod 3 shape of a union issue (`issue.unionErrors`), so a union error would
 * throw instead of rendering.
 */
import { z } from 'zod'
import {
  COMPETITOR_PROMOS,
  INVENTORY_LEVELS,
  STORE_TRAFFIC,
  VISIT_TYPES,
  type CompetitorPromos,
  type InventoryLevel,
  type StoreTraffic,
  type VisitType,
} from '@/types/domain'

/* ---- vocabulary ---------------------------------------------------------- */

/**
 * The brands a Christensen Arms rep actually finds on the rack next to ours.
 * `visits.competition_seen` is a free `text[]` in the DB, so this list can grow
 * without a migration — keep 'Other' last.
 */
export const COMPETITOR_BRANDS = [
  'Weatherby',
  'Bergara',
  'Tikka',
  'Browning',
  'Savage',
  'Ruger',
  'Remington',
  'Seekins',
  'Fierce',
  'Gunwerks',
  'Other',
] as const
export type CompetitorBrand = (typeof COMPETITOR_BRANDS)[number]

/** The 1–5 smallint scales: store_condition, display_quality, staff_knowledge. */
export const RATING_VALUES = [1, 2, 3, 4, 5] as const
export type RatingValue = (typeof RATING_VALUES)[number]

/** Pre-selected so the fastest possible survey is one tap: Save. */
export const DEFAULT_VISIT_TYPE: VisitType = 'in_person'

/* ---- labels (the UI vocabulary the generated types widen to `string`) ----- */

export const VISIT_TYPE_LABELS: Record<VisitType, string> = {
  in_person: 'In person',
  phone: 'Phone',
  email: 'Email',
}

export const INVENTORY_LEVEL_LABELS: Record<InventoryLevel, string> = {
  empty: 'Empty',
  low: 'Low',
  good: 'Good',
  overstock: 'Overstock',
}

export const STORE_TRAFFIC_LABELS: Record<StoreTraffic, string> = {
  poor: 'Slow',
  average: 'Average',
  busy: 'Busy',
}

export const COMPETITOR_PROMO_LABELS: Record<CompetitorPromos, string> = {
  none: 'None',
  some: 'Some',
  heavy: 'Heavy',
}

export interface SurveyOption<T> {
  value: T
  label: string
}

const toOptions = <T extends string>(
  values: readonly T[],
  labels: Record<T, string>,
): ReadonlyArray<SurveyOption<T>> =>
  values.map((value) => ({ value, label: labels[value] }))

export const VISIT_TYPE_OPTIONS = toOptions(VISIT_TYPES, VISIT_TYPE_LABELS)
export const INVENTORY_LEVEL_OPTIONS = toOptions(
  INVENTORY_LEVELS,
  INVENTORY_LEVEL_LABELS,
)
export const STORE_TRAFFIC_OPTIONS = toOptions(
  STORE_TRAFFIC,
  STORE_TRAFFIC_LABELS,
)
export const COMPETITOR_PROMO_OPTIONS = toOptions(
  COMPETITOR_PROMOS,
  COMPETITOR_PROMO_LABELS,
)

/** Reads the DB value back out safely — ERP/legacy rows can hold anything. */
export function visitTypeLabel(value: string | null | undefined): string {
  return value && value in VISIT_TYPE_LABELS
    ? VISIT_TYPE_LABELS[value as VisitType]
    : '—'
}

export function inventoryLevelLabel(value: string | null | undefined): string {
  return value && value in INVENTORY_LEVEL_LABELS
    ? INVENTORY_LEVEL_LABELS[value as InventoryLevel]
    : '—'
}

export function storeTrafficLabel(value: string | null | undefined): string {
  return value && value in STORE_TRAFFIC_LABELS
    ? STORE_TRAFFIC_LABELS[value as StoreTraffic]
    : '—'
}

export function competitorPromoLabel(value: string | null | undefined): string {
  return value && value in COMPETITOR_PROMO_LABELS
    ? COMPETITOR_PROMO_LABELS[value as CompetitorPromos]
    : '—'
}

/* ---- schema -------------------------------------------------------------- */

export const VISIT_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/

/**
 * Local calendar date, never UTC. A 6pm Mountain visit must not log as
 * tomorrow, which is exactly what `toISOString().slice(0, 10)` would do.
 */
export function todayISO(): string {
  const d = new Date()
  const month = `${d.getMonth() + 1}`.padStart(2, '0')
  const day = `${d.getDate()}`.padStart(2, '0')
  return `${d.getFullYear()}-${month}-${day}`
}

const rating = z.number().int().min(1).max(5).nullable().default(null)

export const visitFormSchema = z.object({
  // The only required answer. `check (visit_type in ('in_person','phone','email'))`
  visit_type: z.enum(VISIT_TYPES, { error: 'Pick how you contacted them.' }),
  visit_date: z
    .string()
    .regex(VISIT_DATE_PATTERN, 'Pick a date.')
    .default(() => todayISO()),
  inventory_level: z.enum(INVENTORY_LEVELS).nullable().default(null),
  store_condition: rating,
  display_quality: rating,
  staff_knowledge: rating,
  store_traffic: z.enum(STORE_TRAFFIC).nullable().default(null),
  competitor_promos: z.enum(COMPETITOR_PROMOS).nullable().default(null),
  competition_seen: z.array(z.enum(COMPETITOR_BRANDS)).default([]),
  comments: z
    .string()
    .max(2000, 'Keep it under 2,000 characters.')
    .nullable()
    .default(null),
})

/** What the form holds and what the mutation consumes. */
export type VisitFormValues = z.output<typeof visitFormSchema>
/** What a caller may hand in — every defaulted field is optional. */
export type VisitFormInput = z.input<typeof visitFormSchema>

/**
 * A complete, always-valid set of form values.
 *
 * `partial` is merged field by field and anything that fails validation is
 * dropped rather than rejected wholesale — a half-corrupt offline draft should
 * cost the rep the bad field, not the whole survey. Handing vee-validate a set
 * of values that parses cleanly also keeps it away from @vee-validate/zod's
 * `cast()` fallback, which still calls the zod 3 `_def.defaultValue()` thunk
 * and throws under zod 4.
 */
export function makeVisitFormValues(
  partial?: Partial<VisitFormValues> | null,
): VisitFormValues {
  const base = visitFormSchema.parse({ visit_type: DEFAULT_VISIT_TYPE })
  if (!partial) return base

  const out: Record<string, unknown> = { ...base }
  for (const key of Object.keys(base) as (keyof VisitFormValues)[]) {
    const raw = partial[key]
    if (raw === undefined) continue
    const field = visitFormSchema.shape[key] as z.ZodType
    const parsed = field.safeParse(raw)
    if (parsed.success) out[key] = parsed.data
  }
  return out as VisitFormValues
}

/** True when the rep answered something beyond the pre-filled defaults. */
export function isVisitFormEmpty(values: VisitFormValues): boolean {
  return (
    values.inventory_level === null &&
    values.store_condition === null &&
    values.display_quality === null &&
    values.staff_knowledge === null &&
    values.store_traffic === null &&
    values.competitor_promos === null &&
    values.competition_seen.length === 0 &&
    !values.comments?.trim()
  )
}
