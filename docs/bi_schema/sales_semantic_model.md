# Sales Semantic Model — Query Guide for AI Agents

This document describes the **certified sales semantic model**: a Kimball star
schema exposed as SQL views in the `bi` schema. It is written so that an AI
agent (or analyst) can query the data correctly **without knowing the underlying
Infor Visual ERP schema**. If you follow the rules here, you cannot double-count,
orphan rows, or smear the wrong grain.

All objects live in the `bi` schema on the VECA SQL Server instance
(e.g. `SELECT ... FROM bi.vw_FactOrderLine`). They are read-only.

---

## 1. Golden rules (read first)

1. **Filter and group on DIMENSIONS. Aggregate FACTS.** Slicers, rows, columns,
   `WHERE`, and `GROUP BY` use dimension attributes. Facts appear only inside
   `SUM()`, `COUNT()`, `AVG()`, etc.
2. **Never join one fact to another fact.** To analyze orders + shipments +
   invoices together, join each fact to the **shared dimensions** and aggregate.
   There is no `FactOrderLine.LineNum = FactShipmentLine.LineNum` relationship — the
   lifecycle is connected through `DimCustomer`, `DimPart`, `DimDate`, etc.
3. **Every fact has ONE grain** (stated below). Respect it or you will
   double-count. The three facts have *different* grains.
4. **Keys are explicit.** Each fact carries dimension foreign keys that match the
   dimension's primary key exactly (same string). Join on those, nothing else.
5. **No hidden filters.** Status/active flags are **never** filtered inside the
   views — every row is present. You filter visibly with `WHERE` on the exposed
   status columns. (E.g. to get open orders, `WHERE LineStatus = 'A'`.)
6. **Sentinels, not NULLs.** Unresolved foreign keys point to a sentinel
   dimension member (`'(Unknown)'` for text keys, `19000101` for dates) so rows
   never silently drop. There are no NULL foreign keys.
7. **Mind measure additivity** (marked below): *additive* sums across anything;
   *semi-additive* (cumulative-to-date) must not be summed across the same line;
   *non-additive* (rates/percents/prices) must be averaged or weighted, never
   summed.

---

## 2. The star schema

```
                         ┌──────────────┐
                         │   DimDate    │  (role-played: one physical view,
                         └──────┬───────┘   referenced as many date roles)
                                │
   ┌────────────┐        ┌──────┴───────┐        ┌────────────┐
   │ DimCustomer│────────│              │────────│  DimPart   │
   └────────────┘        │   3 FACTS    │        └────────────┘
   ┌────────────┐        │ OrderLine    │        ┌────────────┐
   │ DimShipTo  │────────│ ShipmentLine │────────│  DimSite   │
   └────────────┘        │ InvoiceLine  │        └────────────┘
   ┌────────────┐        │              │
   │ DimSalesRep│────────│              │   Facts sit side by side and are
   └────────────┘        └──────────────┘   filtered by the SHARED dimensions.
```

Every dimension relates to every fact the same way: **dimension (one) → fact
(many)**, joining `Dim.<Key> = Fact.<Key>`. Dimensions never relate to other
dimensions (no snowflaking — descriptive attributes are flattened as columns).

### Lifecycle
**Order → Shipment → Invoice.** Each stage is a separate fact:

| Fact | Represents | Grain (one row per…) |
|------|-----------|----------------------|
| `bi.vw_FactOrderLine` | Demand / what was booked | sales order line `(OrderID, LineNum)` |
| `bi.vw_FactShipmentLine` | Fulfillment / what physically shipped | packlist line `(PacklistID, LineNum)` |
| `bi.vw_FactInvoiceLine` | Revenue / what was billed (AR) | AR invoice line `(InvoiceEntityID, InvoiceID, InvoiceLineNo)` |

A single order line can fan out to many shipment lines (partial/multi-packlist)
and many invoice lines. That is exactly why you **don't** join them directly —
you aggregate each to a common dimension grain (e.g. by `DimDate` month, by
`DimCustomer`, by `DimPart`).

---

## 3. Relationship map

Join each fact key to the matching dimension key (`many → one`):

| Dimension | Primary key | Fact foreign key(s) |
|-----------|-------------|---------------------|
| `bi.vw_DimCustomer` | `CustomerKey` | `CustomerKey` on all 3 facts |
| `bi.vw_DimShipTo` | `ShipToKey` | `ShipToKey` on all 3 facts |
| `bi.vw_DimSalesRep` | `SalesRepKey` | `SalesRepKey` on all 3 facts |
| `bi.vw_DimPart` | `PartKey` | `PartKey` on all 3 facts |
| `bi.vw_DimSite` | `SiteKey` | `SiteKey` on all 3 facts |
| `bi.vw_DimDate` | `DateKey` | one key per **date role** (below) |

### Date roles (role-playing `DimDate`)
`DimDate` is one physical view joined multiple times — once per meaningful date
on a fact. Join `bi.vw_DimDate.DateKey = Fact.<RoleKey>`.

| Fact | Date role keys |
|------|----------------|
| `FactOrderLine` | `OrderDateKey`, `DesiredShipDateKey`, `PromiseDateKey`, `LastShippedDateKey` |
| `FactShipmentLine` | `ShipDateKey`, `InvoicedDateKey`, `ActualDeliveryDateKey`, `PromiseDateKey` |
| `FactInvoiceLine` | `InvoiceDateKey`, `LastPaidDateKey` |

`DateKey` is an integer `yyyymmdd` (e.g. `20260626`). NULL fact dates map to the
sentinel `19000101`. To filter a real date range, either join `DimDate` and use
its `[Date]` column, or compare the integer key (`OrderDateKey >= 20260101`).

---

## 4. Dimension reference

All dimensions keep **every** row (including inactive/closed) so historical facts
never orphan. Filter status in your query, not by hoping rows are absent.

### `bi.vw_DimCustomer` — one row per customer (`CustomerKey`). No sentinel row.
Sold-to **and** bill-to addresses are inline (1:1). The customer's *assigned* rep
(`AssignedSalesRepID/Name`) is "who owns the account" — different from the
transacting rep on an order (that's `DimSalesRep`).

- **Identity/geography:** `CustomerID`, `CustomerName`, `SoldToCity/State/ZipCode/Country`, `BillTo*`
- **Region/classification:** `SalesRegion` (driven by the customer's **own state** — account HQ, not ship-to), `Territory`, `MarketID`, `CustomerGroupID`, `CarmsCustomerGroup` / `CarmsCustomerSubGroup` (distribution channel, e.g. BIG BOX), `CustomerType`, `PriceGroup`, `Priority`, `SICCode`, `IndustryCode`, `InternalCustomerFlag`
- **Terms/tax/status:** `DiscountCode`, `CurrencyID`, `DefaultSalesTaxGroupID`, `TaxExemptFlag`, `ActiveFlag`, `AccountOpenDate`, `LastOrderDate`
- **Goal:** `YearlySalesGoal` (numeric) / `YearlySalesGoalRaw` (text)
- **Credit/AR (from VFIN):** `CreditStatus`, `CreditLimitAmount`, `ARTermsRuleID`, `ARPaymentMethodID`, `FinanceChargePct`, `ReceivablesAccountID`, `BillToParentFlag`, email/statement delivery config
- **Compliance:** `FFLLicenseNumber`, `FFLExpirationRaw` (customer-master default; the authoritative FFL is on `DimShipTo`)

### `bi.vw_DimShipTo` — ship-to destinations (`ShipToKey`). Sentinel `'(Unknown)'`.
Ship-to is 1:many off a customer, so it is its own dimension. **`ShipToKey` =
`CustomerID + '|' + ADDR_NO`.** It also carries a **customer-master fallback row
per customer** keyed `CustomerID + '|CUST'` — used when an order/shipment/invoice
has no resolvable ship-to, so geography questions never lose rows.

- `AddressSource` = `'ShipTo'` (real address) | `'CustomerMaster'` (fallback = the customer's own address) | `'Unknown'`
- Attributes: `ShipToName`, `Address1-3`, `City`, `State`, `ZipCode`, `Country`, `ShipVia`, `CarrierID`, `Territory`, `DiscountCode`, `ActiveFlag`
- **Authoritative FFL** for shipping firearms: `FFLLicenseNumber` (`USER_4`), `FFLExpirationRaw` (`USER_5`, free-form text)

### `bi.vw_DimPart` — one row per part (`PartKey`). Sentinel `'(Unknown)'`.
Conformed (used by sales **and** purchasing). Built on the global `PART` record,
enriched with single-site cost/planning and product-spec attributes.

- **Identity/classification:** `PartID`, `PartDescription`, `ProductCode` + `ProductCodeDescription`, `CommodityCode` + `CommodityCodeDescription`, `Status`, `ABCCode`, `StockUM`
- **Type flags:** `FabricatedFlag`, `PurchasedFlag`, `StockedFlag`, `IsKitFlag`, `DetailOnlyFlag`, `InspectionRequiredFlag`
- **Product spec (firearms):** `ProductFamily`, `Chambering`, `BarrelLength`, `Twist`, `Finish`, `Handedness`, `ActionType`, `Handguard`, `StockColor`, `StockStyle`, `UPC` (free-form; `'N/A'` where not applicable)
- **Planning policy:** `OrderPolicy`, `SafetyStockQty`, `OrderPoint`, `MinimumOrderQty`/`MaximumOrderQty`/`FixedOrderQty`/`MultipleOrderQty`, `PlanningLeadTimeDays`, `MinimumLeadTimeDays`, `PrimaryWarehouseID`, `PreferredVendorID`, `BuyerUserID`, `PlannerUserID`
- **Standard cost (reference):** `StandardUnitCost` (material+labor+burden+service), `UnitMaterialCost`, `UnitLaborCost`, `UnitBurdenCost`, `UnitServiceCost`, `FixedCost`, `BurdenPercent`, `StandardUnitPrice`, `WholesaleUnitCost`
- **Not here:** live inventory balances (on-hand, available, on-order) — those are volatile measures, not part attributes.

### `bi.vw_DimSite` — one row per site (`SiteKey`). Sentinel `'(Unknown)'`.
`SiteID`, `SiteName`, `EntityID`, address, `Status`. (Single operating site today,
but every fact still carries `SiteKey`; never assume one site in a query.)

### `bi.vw_DimSalesRep` — the **transacting** rep (`SalesRepKey`). Sentinel `'(Unknown)'`.
The rep on the order/shipment (drives commission), distinct from the customer's
assigned rep. `SalesRepName`, `TerritoryID`, `SalesRepEmail`, commission structure
(`EntityCommissionPct`, `PctPaidAtOrder/Shipment/Collect`). `IsPlaceholderRep`
flags `'WEB'`/`'HOUSE'` placeholder codes.

### `bi.vw_DimDate` — one row per calendar day (`DateKey` int `yyyymmdd`). Sentinel `19000101`.
`[Date]`, `Year`, `Quarter`/`QuarterName`, `MonthNumber`/`MonthName`/`MonthShortName`,
`YearMonthNumber`, `MonthYear`, `DayOfMonth`, `DayName`, `ISOWeek`, `IsWeekend`.

---

## 5. Fact reference (keys, grain, measures)

> **The three headline dollar measures — use the right one, they do NOT tie.**
> Each lifecycle stage has ONE certified $ measure, and they legitimately differ
> (different grains/definitions): **`Bookings`** (`FactOrderLine` — what was
> ordered), **`ShippedRevenue`** (`FactShipmentLine` — what physically shipped,
> booked to AR at ship time), **`Revenue`** (`FactInvoiceLine` — what was billed;
> the authoritative revenue number). A report that wants "sales" almost always
> means `Revenue`. Never sum two of them together, and never join the facts —
> aggregate each to a shared dimension. Margin lives on the shipment fact
> (`GrossMarginAmount = ShippedRevenue - COGSAmount`).

### `bi.vw_FactOrderLine` — demand. Grain: `(OrderID, LineNum)`.
- **Keys:** `CustomerKey`, `ShipToKey`, `SalesRepKey`, `PartKey`, `SiteKey`; dates `OrderDateKey`, `DesiredShipDateKey`, `PromiseDateKey`, `LastShippedDateKey`
- **Degenerate / tags:** `OrderID`, `LineNum`, `CustomerPONumber`, `OrderStatus`/`OrderStatusDesc`, `LineStatus`/`LineStatusDesc`, `OrderState` (Open/Held/Closed/Canceled), `OrderType`, `BackorderFlag`, `ProductCode`, `CustomerPartID`, `SellingUM`, `WarehouseID`, `CurrencyID`, `ServiceChargeID`/`IsServiceLine`, `HasLinkedWorkOrder`/`LinkedWorkOrderID`/`LinkedWorkOrderCount`
- **Measures:**
  - *Additive:* `OrderQty` (stock UM), `OrderQtySellingUM`, **`Bookings`** (booked order value $), `AllocatedQty`, `FulfilledQty`, `BacklogQty`, `BacklogAmount`
  - *Semi-additive (cumulative-to-date on the line — do not sum across packlists):* `TotalShippedQtyToDate`, `TotalAmountShippedToDate`
  - *Non-additive (rates):* `UnitPrice`, `TradeDiscountPct`
- **Backlog definition:** `BacklogQty`/`BacklogAmount`/`IsBacklogLine` = still-owed
  demand: `LineStatus = 'A'` **and** order `OrderStatus NOT IN ('C','X')` **and**
  `OrderQty > TotalShippedQtyToDate`. Zero (not negative) when off-backlog.

### `bi.vw_FactShipmentLine` — fulfillment. Grain: `(PacklistID, LineNum)`.
- **Keys:** `CustomerKey`, `ShipToKey`, `SalesRepKey`, `PartKey`, `SiteKey`; dates `ShipDateKey`, `InvoicedDateKey`, `ActualDeliveryDateKey`, `PromiseDateKey`
- **Degenerate / tags:** `PacklistID`, `LineNum`, `OrderID`, `OrderLineNo`, `ShipperStatus`/`ShipperStatusDesc`, `ShipmentState` (Shipped/In Review), `InvoiceID`, `WaybillNumber`, `BillOfLadingID`, `ShipVia`, `RMAID`, `NoInvoiceFlag`, `InventoryTransID`
- **Measures:**
  - *Additive:* `ShippedQty` (stock UM), `ShippedQtySellingUM`, **`ShippedRevenue`** (net shipped revenue booked to AR), `COGSAmount` (actual cost at ship time), `GrossMarginAmount` (= ShippedRevenue − COGS), `COGSMaterial`/`COGSLabor`/`COGSBurden`/`COGSService`, `ActualFreight`, `ShippingWeight`
  - *Non-additive:* `UnitPrice`, `TradeDiscountPct`, `CommissionPct`
- Use `ShipDateKey` for "what shipped when." `ShippedRevenue` is the per-line
  shipped revenue — timely, before the AR invoice posts.
- **COGS is actual cost**, pulled from `INVENTORY_TRANS` via the shipment's
  inventory movement (not standard cost — `DimPart` holds the static standard).
  It's signed to match returns (`TYPE='I'` return = negative) and is **NULL on
  freight/service lines** (~2.6%, no inventory movement), so `GrossMarginAmount`
  is NULL there rather than showing 100% margin. For a margin %, sum
  `ShippedRevenue` and `COGSAmount` separately and divide — don't average the
  per-line margin.

### `bi.vw_FactInvoiceLine` — revenue / AR. Grain: `(InvoiceEntityID, InvoiceID, InvoiceLineNo)`.
Sourced from **VFIN AR** (authoritative for tax, memos, payment status, GL).
- **Keys:** `CustomerKey`, `ShipToKey`, `SalesRepKey`, `PartKey`, `SiteKey`; dates `InvoiceDateKey`, `LastPaidDateKey`
- **Degenerate / tags:** `InvoiceID`, `InvoiceLineNo`, `InvoiceStatus`/`InvoiceStatusDesc`, `InvoiceType`/`InvoiceTypeDesc`, `DocumentTypeID` (`AR`/`ARM`), `IsMemo`, `InvoiceState` (Open/Closed/Void), `PostedFlag`, `FreightLineFlag`, `OrderID`, `OrderLineNo`, `PacklistID`, `RevenueAccountID`, `BillToCustomerID`
- **Measures:**
  - *Additive:* **`Revenue`** (net AR line revenue — the certified revenue number), `InvoiceQty`, `CommissionAmount`
  - *Non-additive:* `UnitPrice`, `CommissionPct`
- **Header totals are deliberately absent** (`TOTAL_AMOUNT`, tax, paid…): they are
  invoice-header grain and would double-count on a line. For AR aging/payment a
  separate header-grain fact is needed (not yet built).
- **Memos (verified live — do NOT assume the textbook convention):** memos are
  `InvoiceType='MEMO'` / `DocumentTypeID='ARM'`, flagged by `IsMemo`. In this
  install they are **not** negative credit memos — headers are never negative
  (~$26M positive), most memo lines are positive, and some memos carry
  offsetting ± lines that net to $0. **You cannot net memos by sign.** ~78% of
  memo lines are order/shipper-linked; the rest are purely financial. Whether
  ARM memos count as sales `Revenue` is a **finance decision** — filter on
  `IsMemo`/`DocumentTypeID` to include or exclude them explicitly. The base
  `Revenue` measure includes them (gross) until finance rules otherwise.
- **`(Unknown)`-part tail:** ~15% of invoice lines ($15M) have no part
  (freight, finance charges, memos, non-stock — no VECA order-line link) and
  land on `PartKey='(Unknown)'`. For product-family revenue, prefer
  `FactShipmentLine` (its part resolves far more completely) or expect an
  `(Unknown)` bucket here.

---

## 6. Status code reference

These are exposed raw **and** decoded; filter on whichever you prefer.

| Field | Codes | Meaning |
|-------|-------|---------|
| `FactOrderLine.OrderStatus` | `R`/`F`/`H`/`C`/`X` | Released / Firmed / Hold / Closed / Canceled (universal Infor) |
| `FactOrderLine.LineStatus` | `A`/`C` | Active / Closed |
| `FactShipmentLine.ShipperStatus` | `A`/`S`/`1`/`2`/`3` | Approved / Shipped / Review 1 / Review 2 / Review 3 |
| `FactInvoiceLine.InvoiceStatus` | `OPEN`/`CLOSED`/`VOID` | (decoded to Open/Closed/Void) |
| `FactInvoiceLine.InvoiceType` | `INVOICE`/`MEMO` | Invoice / AR Memo (`DocumentTypeID` = `AR`/`ARM`). Memos are NOT stored negative here — see §5 memo note; don't net by sign |

Rollup tags for convenience: `OrderState` (Open/Held/Closed/Canceled),
`ShipmentState` (Shipped/In Review), `InvoiceState` (Open/Closed/Void).

---

## 7. Worked examples

**Shipped revenue by month and product family (current year):**
```sql
SELECT d.[Year], d.MonthShortName, p.ProductFamily,
       SUM(f.ShippedRevenue) AS ShippedRevenue
FROM bi.vw_FactShipmentLine f
JOIN bi.vw_DimDate d ON d.DateKey = f.ShipDateKey
JOIN bi.vw_DimPart p ON p.PartKey = f.PartKey
WHERE f.ShipperStatus IN ('A','S')          -- exclude in-review packlists
  AND d.[Year] = 2026
GROUP BY d.[Year], d.MonthNumber, d.MonthShortName, p.ProductFamily
ORDER BY d.MonthNumber, ShippedRevenue DESC;
```

**Gross margin % by product family (current year, from actual COGS):**
```sql
SELECT p.ProductFamily,
       SUM(f.ShippedRevenue)                                   AS Revenue,
       SUM(f.COGSAmount)                                       AS COGS,
       SUM(f.ShippedRevenue) - SUM(f.COGSAmount)               AS GrossMargin,
       CAST(100.0 * (SUM(f.ShippedRevenue) - SUM(f.COGSAmount))
            / NULLIF(SUM(f.ShippedRevenue), 0) AS decimal(5,1)) AS GrossMarginPct
FROM bi.vw_FactShipmentLine f
JOIN bi.vw_DimDate d ON d.DateKey = f.ShipDateKey
JOIN bi.vw_DimPart p ON p.PartKey = f.PartKey
WHERE f.ShipperStatus IN ('A','S') AND d.[Year] = 2026
GROUP BY p.ProductFamily
ORDER BY GrossMargin DESC;
```
(Sum revenue and COGS separately, then divide — never average the per-line
margin, and remember freight/service lines have NULL COGS.)

**Open backlog $ by sales rep:**
```sql
SELECT r.SalesRepName, SUM(f.BacklogAmount) AS BacklogDollars
FROM bi.vw_FactOrderLine f
JOIN bi.vw_DimSalesRep r ON r.SalesRepKey = f.SalesRepKey
WHERE f.IsBacklogLine = 1
GROUP BY r.SalesRepName
ORDER BY BacklogDollars DESC;
```

**Bookings vs shipments by customer region (note: two facts, NO fact-to-fact join):**
```sql
SELECT c.SalesRegion,
       (SELECT SUM(o.Bookings)
          FROM bi.vw_FactOrderLine o
          JOIN bi.vw_DimCustomer oc ON oc.CustomerKey = o.CustomerKey
         WHERE oc.SalesRegion = c.SalesRegion)   AS Booked,
       (SELECT SUM(s.ShippedRevenue)
          FROM bi.vw_FactShipmentLine s
          JOIN bi.vw_DimCustomer sc ON sc.CustomerKey = s.CustomerKey
         WHERE sc.SalesRegion = c.SalesRegion)    AS Shipped
FROM bi.vw_DimCustomer c
GROUP BY c.SalesRegion;
```
(Or aggregate each fact to `SalesRegion` separately and `FULL JOIN` the two
summaries on region — never join the raw fact rows.)

**Sales into each state this month (geography from ship-to):**
```sql
SELECT st.[State], SUM(f.ShippedRevenue) AS ShippedValue
FROM bi.vw_FactShipmentLine f
JOIN bi.vw_DimShipTo st ON st.ShipToKey = f.ShipToKey
JOIN bi.vw_DimDate d    ON d.DateKey   = f.ShipDateKey
WHERE d.YearMonthNumber = 202606 AND f.ShipperStatus IN ('A','S')
GROUP BY st.[State]
ORDER BY ShippedValue DESC;
```

**Order lines with a work order attached, for one customer:**
```sql
SELECT f.OrderID, f.LineNum, p.PartDescription,
       f.LinkedWorkOrderID, f.LinkedWorkOrderCount
FROM bi.vw_FactOrderLine f
JOIN bi.vw_DimCustomer c ON c.CustomerKey = f.CustomerKey
JOIN bi.vw_DimPart p     ON p.PartKey     = f.PartKey
WHERE c.CustomerName LIKE '%LIPSEY%' AND f.HasLinkedWorkOrder = 1;
```

---

## 8. Gotchas / install-specific assumptions

- **Cumulative vs per-shipment qty.** `FactOrderLine.TotalShippedQtyToDate` is the
  running total on the order line. Per-packlist quantity is
  `FactShipmentLine.ShippedQty`. Never add them together or sum the cumulative
  one across packlists.
- **Ship-to fallback.** A fact with no real ship-to resolves to the customer's
  own address (`ShipToKey` ending `|CUST`, `AddressSource='CustomerMaster'`), not
  `(Unknown)`. So `DimShipTo` geography is always populated for a real customer.
- **Single site / single accounting entity.** Several enrichments (part cost,
  customer credit, rep commission) are flattened on a 1:1 basis that holds only
  while there is one site and one entity. Still always carry `SiteKey`.
- **VFIN ↔ VECA sync.** Invoice facts come from VFIN; customer/rep IDs are
  LSA-synced to VECA. A handful of AR-only customers may not exist in VECA and
  land on `(Unknown)` — surfaced by validation, not silently dropped.
- **No status filter in views.** If you want "open orders" you must add
  `WHERE LineStatus='A'` (and usually `OrderStatus NOT IN ('C','X')`). The views
  return closed/canceled rows too, by design.

---

## 9. Scope — what this model does and does not cover

**Covers (use these views):** the commercial sales lifecycle — bookings,
backlog, shipments, fulfillment, AR revenue, and slicing by customer, ship-to /
geography, sales rep, part / product family, site, and any date role. This is the
right source for sales reporting, commercial dashboards, and most "how much did
we sell / ship / bill, to whom, of what" questions.

**Does NOT cover (use the SQL Toolbox / raw schema):** production & work-order
execution, MRP / planning / net requirements, BOM explosion & routings, inventory
on-hand / serial-trace, purchasing & AP, GL / financial statements, and other
deep-operational domains. Those have their own curated queries and are not
modeled as this star.

**Guidance for an AI choosing a path:** if the question is answerable from the
columns in this document, prefer these views — the grain, keys, and additivity
are guaranteed, so the SQL is simple and safe. Only drop to the raw Visual schema
(or the toolbox's canonical queries) when the question needs an entity this model
doesn't expose.
