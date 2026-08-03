/**
 * Domain vocabulary — the values behind the CHECK constraints in the
 * migrations. The generated types widen these to `string`, so this file is the
 * single place the UI learns what the legal values actually are.
 *
 * These lists must stay in sync with supabase/migrations/005_app_execution.sql.
 * When `packages/shared` exists (TECH_STACK §7) these become zod schemas and
 * are shared with the Edge Functions.
 */

export const ROLES = ['admin', 'rep'] as const
export type Role = (typeof ROLES)[number]

export const REC_STATUSES = ['open', 'acted', 'closed', 'dismissed'] as const
export type RecStatus = (typeof REC_STATUSES)[number]

export const REC_PRIORITIES = ['high', 'normal', 'low'] as const
export type RecPriority = (typeof REC_PRIORITIES)[number]

/** PRD §7: a recommendation cannot close without one of these. */
export const REC_OUTCOMES = [
  'order_received',
  'inventory_issue',
  'competitor',
  'customer_shrinking',
  'seasonal',
  'false_positive',
  'could_not_contact',
] as const
export type RecOutcome = (typeof REC_OUTCOMES)[number]

export const OUTCOME_LABELS: Record<RecOutcome, string> = {
  order_received: 'Order received',
  inventory_issue: 'Inventory issue',
  competitor: 'Competitor activity',
  customer_shrinking: 'Customer shrinking',
  seasonal: 'Seasonal',
  false_positive: 'Bad recommendation',
  could_not_contact: 'Could not contact',
}

export const ACTION_TYPES = ['call', 'visit', 'email', 'other'] as const
export type ActionType = (typeof ACTION_TYPES)[number]

export const ACTION_LABELS: Record<ActionType, string> = {
  call: 'Called',
  visit: 'Visited',
  email: 'Emailed',
  other: 'Other',
}

export const VISIT_TYPES = ['in_person', 'phone', 'email'] as const
export type VisitType = (typeof VISIT_TYPES)[number]

export const INVENTORY_LEVELS = ['empty', 'low', 'good', 'overstock'] as const
export type InventoryLevel = (typeof INVENTORY_LEVELS)[number]

export const STORE_TRAFFIC = ['poor', 'average', 'busy'] as const
export type StoreTraffic = (typeof STORE_TRAFFIC)[number]

export const COMPETITOR_PROMOS = ['none', 'some', 'heavy'] as const
export type CompetitorPromos = (typeof COMPETITOR_PROMOS)[number]

export const PHOTO_CATEGORIES = [
  'storefront',
  'counter',
  'display',
  'endcap',
  'competition',
  'other',
] as const
export type PhotoCategory = (typeof PHOTO_CATEGORIES)[number]

export const TASK_STATUSES = ['open', 'done', 'cancelled'] as const
export type TaskStatus = (typeof TASK_STATUSES)[number]

/**
 * The account page's quick-action strip. Not a DB value — a UI vocabulary that
 * two components have to agree on, which is the same reason everything else
 * here exists.
 */
export const QUICK_ACTIONS = [
  'visit',
  'contact',
  'note',
  'photo',
  'task',
  'summary',
] as const
export type QuickAction = (typeof QUICK_ACTIONS)[number]

/** Mission scope options — mission_batches.scope_type (016_missions_admin.sql). */
export const MISSION_SCOPES = ['all', 'vendor', 'rep', 'custom'] as const
export type MissionScope = (typeof MISSION_SCOPES)[number]

export const MISSION_SCOPE_LABELS: Record<MissionScope, string> = {
  all: 'All accounts',
  vendor: 'A rep group',
  rep: 'One rep',
  custom: 'Hand-picked',
}
