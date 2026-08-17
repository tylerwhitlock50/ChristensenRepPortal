/**
 * Domain vocabulary — the values behind the CHECK constraints in the
 * migrations. The generated types widen these to `string`, so this file is the
 * single place the UI learns what the legal values actually are.
 *
 * These lists must stay in sync with supabase/migrations/005_app_execution.sql.
 * When `packages/shared` exists (TECH_STACK §7) these become zod schemas and
 * are shared with the Edge Functions.
 */

export const ROLES = ['admin', 'rep', 'order_entry'] as const
export type Role = (typeof ROLES)[number]

export const REC_STATUSES = ['open', 'acted', 'closed', 'dismissed'] as const
export type RecStatus = (typeof REC_STATUSES)[number]

export const REC_PRIORITIES = ['high', 'normal', 'low'] as const
export type RecPriority = (typeof REC_PRIORITIES)[number]

/**
 * PRD §7: a recommendation cannot close without one of these. This is the
 * list a rep can CHOOSE from — 'account_deactivated' is deliberately not in
 * it. That outcome is stamped only by the deactivation trigger
 * (023_account_deactivations.sql) and would be a nonsense chip in a close
 * panel, but it still needs a label wherever closed work is displayed.
 */
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

export type SystemRecOutcome = 'account_deactivated'

export const OUTCOME_LABELS: Record<RecOutcome | SystemRecOutcome, string> = {
  order_received: 'Order received',
  inventory_issue: 'Inventory issue',
  competitor: 'Competitor activity',
  customer_shrinking: 'Customer shrinking',
  seasonal: 'Seasonal',
  false_positive: 'Bad recommendation',
  could_not_contact: 'Could not contact',
  account_deactivated: 'Account deactivated',
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

/**
 * Why a rep took an account out of play —
 * account_deactivations.reason (023_account_deactivations.sql).
 */
export const DEACTIVATION_REASONS = [
  'store_closed',
  'buys_elsewhere',
  'unresponsive',
  'low_potential',
  'duplicate_account',
  'other',
] as const
export type DeactivationReason = (typeof DEACTIVATION_REASONS)[number]

export const DEACTIVATION_REASON_LABELS: Record<DeactivationReason, string> = {
  store_closed: 'Store closed',
  buys_elsewhere: 'Buys elsewhere now',
  unresponsive: "Can't get a response",
  low_potential: 'Not worth the calls',
  duplicate_account: 'Duplicate account',
  other: 'Something else',
}

/**
 * Order lifecycle — orders.status (20260817000200_orders.sql). Drafts are
 * the only state a rep edits directly; every other move is a transition RPC.
 */
export const ORDER_STATUSES = [
  'draft',
  'submitted',
  'entered',
  'verified',
  'discrepancy',
  'cancelled',
] as const
export type OrderStatus = (typeof ORDER_STATUSES)[number]

export const ORDER_STATUS_LABELS: Record<OrderStatus, string> = {
  draft: 'Draft',
  submitted: 'Submitted',
  entered: 'Entered in ERP',
  verified: 'Verified',
  discrepancy: 'Discrepancy',
  cancelled: 'Cancelled',
}

/** QC finding kinds — order_qc_results.result (20260817000200_orders.sql). */
export const QC_RESULTS = [
  'customer_mismatch',
  'price_mismatch',
  'qty_mismatch',
  'missing_in_erp',
  'extra_in_erp',
  'order_not_found',
] as const
export type QcResult = (typeof QC_RESULTS)[number]

export const QC_RESULT_LABELS: Record<QcResult, string> = {
  customer_mismatch: 'Wrong customer in ERP',
  price_mismatch: 'Price differs',
  qty_mismatch: 'Quantity differs',
  missing_in_erp: 'Missing from ERP order',
  extra_in_erp: 'Extra line in ERP order',
  order_not_found: 'ERP order not found',
}

/** Mission scope options — mission_batches.scope_type (016_missions_admin.sql). */
export const MISSION_SCOPES = ['all', 'vendor', 'rep', 'custom'] as const
export type MissionScope = (typeof MISSION_SCOPES)[number]

export const MISSION_SCOPE_LABELS: Record<MissionScope, string> = {
  all: 'All accounts',
  vendor: 'A rep group',
  rep: 'One rep',
  custom: 'Hand-picked',
}
