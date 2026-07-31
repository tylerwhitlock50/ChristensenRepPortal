# Inventory Semantic Model — Query Guide for AI Agents

The **certified inventory semantic model**: current-state on-hand snapshots in the
`bi` schema. It reuses the conformed `DimPart`, `DimSite`, and `DimDate` from the
sales/purchasing models and adds `DimWarehouse`. The golden rules are identical
to the sales guide (`docs/sales_semantic_model.md` §1) — read that first.

**What this model is for:** inventory *position and valuation* — how much stock
we hold right now, where, and what it's worth (turns, days-of-supply, E&O /
dead-stock, ABC, by warehouse/location). It is the governed home for the
volatile quantity balances that are deliberately kept OFF `DimPart`.

**What it is NOT:** a history. Both facts are **current-state snapshots (as-of the
last Power BI refresh)**. For inventory *over time* (turns trend, as-of
reconstruction, movement analysis) a movement fact over `INVENTORY_TRANS` (16.2M
rows) is needed — deferred by design. Ask before assuming historical inventory.

---

## 1. The two facts

| Fact | Grain (one row per…) | Use it for |
|------|----------------------|-----------|
| `bi.vw_FactInventoryOnHand` | part × site (21,051) | **The authoritative number.** On-hand qty + valuation that ties to GL. |
| `bi.vw_FactInventoryLocation` | part × warehouse × location (327,217) | Bin-level detail — stock by warehouse/location + hold status. |

**Which to use:** for a valuation or on-hand total that must be correct/tie to
the GL, use **`FactInventoryOnHand`** (`QTY_ON_HAND` is the authoritative
balance). For "where is it / which warehouse / on hold", use
**`FactInventoryLocation`**. The two reconcile to ~0.13% (bin balances can drift
from the official on-hand) — don't be surprised they aren't identical.

Neither snapshot relates to `DimDate` for its balance (they're "now").
`FactInventoryLocation` has one date role, `LastCountDateKey` (cycle-count
recency) — currently unpopulated in this install (all rows on the `19000101`
sentinel).

---

## 2. `DimWarehouse` — one row per warehouse (`WarehouseKey`). Sentinel `'(Unknown)'`.
13 warehouses within the single site. `WarehouseName`, `Description`, `SiteID`,
`RegionID`, address, and consignment attributes (`ConsignedType`,
`ConsignCustomerID`/`ConsignVendorID`). Its own dimension, distinct from
`DimSite`. Related only to `FactInventoryLocation`.

---

## 3. Measures & valuation

Both facts expose the same shape:
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

---

## 6. Gotchas / install-specific
- **Snapshots, not history** — current-state only; no time dimension on the balance.
- **Authoritative vs bin drift** — `FactInventoryOnHand` (part-site) ties to GL; `FactInventoryLocation` (bins) can differ ~0.1%.
- **Standard-cost valuation** — must be reconciled to the GL inventory account; switch to actual weighted-average if it doesn't tie.
- **Only ~3,320 parts hold stock** (of 21K) — most part-site rows are zero on-hand; filter `OnHandQty <> 0` for "what we actually stock."
- **Cycle-count date unpopulated** — `LastCountDateKey` is always the sentinel here.
