/**
 * Order pricing — the buy-X-get-Y prorate, for LIVE PREVIEW ONLY.
 *
 * The database recomputes and overwrites these numbers inside submit_order()
 * (20260817000200_orders.sql), so nothing a client sends is ever trusted.
 * This file exists so the rep watches the discount appear while they type,
 * not so the discount is decided here. The two implementations mirror each
 * other line for line; change both or neither.
 *
 * The formula
 * -----------
 * A special sells "buy X get Y" — but the business never ships free goods,
 * so the earned free units are settled as a prorated percent off every
 * qualifying unit on that list:
 *
 *     block     = buyQty + getQty
 *     multiples = floor(totalQty / block)        totalQty = Σ qty on the list
 *     pct       = 100 · (multiples · getQty) / totalQty
 *
 * At totalQty an exact number of blocks this is getQty/block (buy 10 get 2,
 * 24 units → 16.6667%); remainder units past the last whole block dilute it
 * (18 units → 2 free-equivalents over 18 = 11.1111%); below one block it is
 * zero. The percent can never reach getQty/block · 100 ≥ 100, so a line is
 * never free.
 *
 * Dependency-free and pure on purpose — the unit tests in
 * tests/unit/orderPricing.test.ts run it under vite-node with no framework.
 */

export interface PromoConfig {
  buyQty: number
  getQty: number
}

export interface PricingLineInput {
  /** Caller's row identity (draft line id / local uuid), passed through. */
  key: string
  priceListId: number
  partId: string
  qty: number
  /** The published list price for this SKU. */
  listUnitPrice: number
}

export interface PricedLine extends PricingLineInput {
  /** 0–100, 4 decimal places — matches order_lines.discount_pct. */
  discountPct: number
  /** listUnitPrice with the discount applied, rounded to cents. */
  effectiveUnitPrice: number
  /** qty × effectiveUnitPrice, in cents-exact dollars. */
  lineTotal: number
}

const round2 = (n: number) => Math.round(n * 100) / 100
const round4 = (n: number) => Math.round(n * 10000) / 10000

/**
 * Price every line of a draft order. Lines are grouped by price list; lists
 * present in `promosByListId` prorate across their own lines, everything
 * else (general lists, promo-less specials) passes through at list price.
 *
 * Pure and O(n): callers re-run it on every qty edit.
 */
export function priceOrder(
  lines: readonly PricingLineInput[],
  promosByListId: ReadonlyMap<number, PromoConfig>,
): PricedLine[] {
  const totalByList = new Map<number, number>()
  for (const line of lines) {
    totalByList.set(
      line.priceListId,
      (totalByList.get(line.priceListId) ?? 0) + line.qty,
    )
  }

  const pctByList = new Map<number, number>()
  for (const [listId, totalQty] of totalByList) {
    const promo = promosByListId.get(listId)
    if (!promo || promo.buyQty <= 0 || promo.getQty <= 0 || totalQty <= 0) {
      pctByList.set(listId, 0)
      continue
    }
    const block = promo.buyQty + promo.getQty
    const multiples = Math.floor(totalQty / block)
    pctByList.set(
      listId,
      multiples === 0 ? 0 : round4((100 * multiples * promo.getQty) / totalQty),
    )
  }

  return lines.map((line) => {
    const discountPct = pctByList.get(line.priceListId) ?? 0
    const effectiveUnitPrice = round2(line.listUnitPrice * (1 - discountPct / 100))
    return {
      ...line,
      discountPct,
      effectiveUnitPrice,
      lineTotal: round2(line.qty * effectiveUnitPrice),
    }
  })
}

/** Σ lineTotal, rounded to cents — what the order footer shows. */
export function orderTotal(lines: readonly PricedLine[]): number {
  return round2(lines.reduce((sum, l) => sum + l.lineTotal, 0))
}
