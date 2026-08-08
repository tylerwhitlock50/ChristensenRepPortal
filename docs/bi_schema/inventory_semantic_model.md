# Inventory Semantic Model — Query Guide for AI Agents

The **certified inventory semantic model**: current-state inventory snapshots in the
`bi` schema. It reuses the conformed `DimPart`, `DimSite`, and `DimDate` from the
sales/purchasing models and adds `DimWarehouse`. The golden rules are identical
to the sales guide (`docs/sales_semantic_model.md` §1) — read that first.

**What this model is for:** inventory *position, valuation, and available to
sell* — how much stock we hold right now, where, what it's worth, and what
remains after existing customer promises (turns, days-of-supply, E&O /
dead-stock, ABC, ATS, by warehouse/location). It is the governed home for the
volatile quantity balances that are deliberately kept OFF `DimPart`.

**What it is NOT:** a history. All three facts are **current-state snapshots (as-of the
last Power BI refresh)**. For inventory *over time* (turns trend, as-of
reconstruction, movement analysis) a movement fact over `INVENTORY_TRANS` (16.2M
rows) is needed — deferred by design. Ask before assuming historical inventory.

---

## 1. The three facts

| Fact | Grain (one row per…) | Use it for |
|------|----------------------|-----------|
| `bi.vw_FactInventoryOnHand` | part × site (21,051) | **The authoritative number.** On-hand qty + valuation that ties to GL. |
| `bi.vw_FactInventoryLocation` | part × warehouse × location (327,217) | Bin-level detail — stock by warehouse/location + hold status. |
| `bi.vw_FactAvailableToSell` | part × site with SHIPPING stock or open demand | **The governed sell list.** SHIPPING QOH outside R10 staging minus open Released/Firmed SO demand. |

**Which to use:**
- Valuation / GL tie-out → **`FactInventoryOnHand`** (`QTY_ON_HAND` is the
  authoritative balance).
- Where is it / warehouse / hold → **`FactInventoryLocation`**.
- What can we still promise → **`FactAvailableToSell`**.

On-hand and location reconcile to ~0.13% (bin balances can drift from the
official on-hand) — don't be surprised they aren't identical. ATS is a
different question: shippable SHIPPING stock after open customer promises, not
a substitute for GL on-hand.

None of the current-state facts relates to `DimDate` for its balance (they're "now").
`FactInventoryLocation` has one date role, `LastCountDateKey` (cycle-count
recency) — currently unpopulated in this install (all rows on the `19000101`
sentinel). ATS has no date role and no `DimWarehouse` relationship (warehouse is
the degenerate constant `ShippableWarehouseID = 'SHIPPING'`).

### Available to sell rule

`FactAvailableToSell` is a current-state operational snapshot. Headline math
matches Toolbox `domains/sales/ats_finished_goods.sql`; the fact population is
only part×sites with SHIPPING stock or open demand (not every A/O part-site).

```text
AvailableToSellQty = ShippingOnHandQty - OpenOrderQty
```

- `ShippingOnHandQty` is `PART_LOCATION.QTY` in warehouse `SHIPPING`, excluding
  locations matching `R10%`. `ShippingOnHandBeforeExclusionsQty` and
  `ExcludedStagingQty` make that exclusion auditable.
- `OpenOrderQty` includes positive remaining qty on active lines whose order is
  Released or Firmed. It includes credit-restricted customers; those promises
  do not disappear from inventory exposure. The approved/restricted split is
  exposed separately from **VECA** `CUSTOMER_ENTITY` single-letter codes
  (`A`/`H`/`O`/`S`) — not the VFIN full-word codes on `DimCustomer`.
- `DemandWithLinkedSupplyQty` and `DemandWithoutLinkedSupplyQty` partition open
  demand. `LinkedSupplyAllocatedQty` / `LinkedSupplyRemainingQty` describe the
  explicit CO→WO peg and are **subsets of the same demand, not extra demand**.
  Never subtract them again from ATS.
- Negative `AvailableToSellQty` is an intentional oversold signal. Use
  `IsAvailableToSell=1` (ATS >= 1) for the sell list and `IsOversold=1` for the
  exception list.
- Held orders and future PO/WO supply are excluded. Sales
  `FactOrderLine.Backlog*` still includes Hold — that is sales backlog, not ATS.
  Revisit held demand only as an explicit policy choice; do not silently mix it
  into the measure.
- Finished-goods / current-pricelist narrowing stays in the report (or sales
  pricing facts). This inventory fact does not silently apply those filters.

---

## 2. `DimWarehouse` — one row per warehouse (`WarehouseKey`). Sentinel `'(Unknown)'`.
13 warehouses within the single site. `WarehouseName`, `Description`, `SiteID`,
`RegionID`, address, and consignment attributes (`ConsignedType`,
`ConsignCustomerID`/`ConsignVendorID`). Its own dimension, distinct from
`DimSite`. Related only to `FactInventoryLocation` — not to ATS (ATS is
part×site grain with a degenerate `ShippableWarehouseID`).

---

## 3. Measures & valuation

The on-hand and location facts expose the same valuation shape:
- **Quantities (additive):** `OnHandQty`; on the part-site fact also
  `QtyAvailableIssue`, `QtyAvailableMRP`, `QtyOnOrder`, `QtyInDemand`,
  `QtyCommitted`, `AnnualUsageQty`; on the bin fact also `CommittedQty`,
  `PurgeQty`.
- **Value (additive):** `OnHandValue` and its cost-element split
  (`OnHandValueMaterial`/`Labor`/`Burden`/`Service`).
- **Unit costs (NON-additive rates):** `UnitMaterialCost`… and `StandardUnitCost`
  (part-site fact).

**Valuation basis = standard cost.** `OnHandValue = OnHandQty × StandardUnitCost`
where standard cost = material + labor + burden + service (same basis as
`DimPart.StandardUnitCost`). Verified total **~$21.6M**. This must reconcile to
the GL inventory control account (validation ID4). If it does not tie (possible
under actual costing), `OnHandValue` should be rebuilt on an actual
weighted-average from `INVENTORY_TRANS` — a known switch, not a silent choice.

---

## 4. Cross-model measures (the point of conforming dimensions)

Inventory only becomes powerful joined to the other models via the shared dims —
aggregate each fact separately, never join facts:

- **Inventory turns** = annualized COGS (`FactShipmentLine.COGSAmount`, sales
  model) ÷ average `OnHandValue` (this model). Both slice by `DimPart` /
  `DimSite`.
- **Days of supply** = `OnHandQty` ÷ (usage rate). Usage from `AnnualUsageQty`
  here, or from shipment/issue history.
- **E&O / dead stock** = on-hand for parts with no recent sales
  (`FactShipmentLine`) or no usage — join on `DimPart`.

---

## 5. Worked examples

**Inventory value by ABC class and product family:**
```sql
SELECT p.ProductFamily, f.ABCCode,
       SUM(f.OnHandQty)   AS OnHandUnits,
       SUM(f.OnHandValue) AS InventoryValue
FROM bi.vw_FactInventoryOnHand f
JOIN bi.vw_DimPart p ON p.PartKey = f.PartKey
GROUP BY p.ProductFamily, f.ABCCode
ORDER BY InventoryValue DESC;
```

**Stock on hold, by warehouse:**
```sql
SELECT w.WarehouseName, f.HoldReasonID,
       SUM(f.OnHandQty) AS Qty, SUM(f.OnHandValue) AS Value
FROM bi.vw_FactInventoryLocation f
JOIN bi.vw_DimWarehouse w ON w.WarehouseKey = f.WarehouseKey
WHERE f.HoldReasonID IS NOT NULL
GROUP BY w.WarehouseName, f.HoldReasonID
ORDER BY Value DESC;
```

**Potential dead stock (on hand, no annual usage):**
```sql
SELECT p.PartID, p.PartDescription, f.OnHandQty, f.OnHandValue
FROM bi.vw_FactInventoryOnHand f
JOIN bi.vw_DimPart p ON p.PartKey = f.PartKey
WHERE f.OnHandQty > 0 AND COALESCE(f.AnnualUsageQty,0) = 0
ORDER BY f.OnHandValue DESC;
```

**Available to sell list (with demand-link audit context):**
```sql
SELECT p.PartID, p.PartDescription, p.ProductCode, p.UPC,
       f.ShippingOnHandQty, f.OpenOrderQty, f.AvailableToSellQty,
       f.DemandWithLinkedSupplyQty, f.LinkedSupplyAllocatedQty
FROM bi.vw_FactAvailableToSell f
JOIN bi.vw_DimPart p ON p.PartKey = f.PartKey
WHERE f.IsAvailableToSell = 1
ORDER BY f.AvailableToSellQty DESC, p.PartID;
```

---

## 6. Gotchas / install-specific
- **Snapshots, not history** — current-state only; no time dimension on the balance.
- **Authoritative vs bin drift** — `FactInventoryOnHand` (part-site) ties to GL; `FactInventoryLocation` (bins) can differ ~0.1%.
- **Standard-cost valuation** — must be reconciled to the GL inventory account; switch to actual weighted-average if it doesn't tie.
- **Only ~3,320 parts hold stock** (of 21K) — most part-site rows are zero on-hand; filter `OnHandQty <> 0` for "what we actually stock."
- **Cycle-count date unpopulated** — `LastCountDateKey` is always the sentinel here.
- **Demand links are coverage, not more demand** — `LinkedSupplyAllocatedQty`
  is already represented inside `OpenOrderQty`; subtracting both double-counts
  the same customer promise and understates ATS.
- **Credit restriction is diagnostic only** — ATS conservatively reserves all
  Released/Firmed open demand. Use the credit split to investigate, not to alter
  the certified headline measure in a report. The split uses VECA single-letter
  `CUSTOMER_ENTITY.CREDIT_STATUS` (`A` = approved); do not compare it to
  `DimCustomer.CreditStatus` (VFIN full words).
- **Hold is sales backlog, not ATS** — `FactOrderLine.Backlog*` includes Hold;
  ATS does not. That divergence is intentional until policy says otherwise.
- **ATS population is sparse** — only part×sites with SHIPPING stock or open
  demand. Zero/zero part-sites are omitted on purpose.
