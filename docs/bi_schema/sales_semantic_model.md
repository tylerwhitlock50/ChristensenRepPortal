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

## 2. The star schema (plus one customer-contact leaf)

```
                         ┌──────────────┐
                         │   DimDate    │  (role-played: one physical view,
                         └──────┬───────┘   referenced as many date roles)
                                │
   ┌──────────────────┐
   │DimCustomerContact│ (*) CRM/master-data leaf; no fact relationship
   └────────┬─────────┘
            │
   ┌────────┴───┐        ┌──────┴───────┐        ┌────────────┐
   │ DimCustomer│────────│              │────────│  DimPart   │
   └────────────┘  (1)   │   3 FACTS    │        └────────────┘
   ┌────────────┐        │ OrderLine    │        ┌────────────┐
   │ DimShipTo  │────────│ ShipmentLine │────────│  DimSite   │
   └────────────┘        │ InvoiceLine  │        └────────────┘
   ┌────────────┐        │              │
   │ DimSalesRep│────────│              │   Facts sit side by side and are
   └────────────┘        └──────────────┘   filtered by the SHARED dimensions.
```

Every fact-facing dimension relates to every fact the same way: **dimension
(one) → fact (many)**, joining `Dim.<Key> = Fact.<Key>`. The sole exception to
the otherwise-flat star is `DimCustomerContact`, a one-to-many leaf under
`DimCustomer` for CRM/customer-master lookup. It never relates directly to a
fact and must not use bidirectional filtering.

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

The one dimension-to-dimension relationship is:

| Parent (one) | Leaf (many) | Join | Cross-filter |
|---|---|---|---|
| `bi.vw_DimCustomer` | `bi.vw_DimCustomerContact` | `CustomerKey` | Single direction, customer → contacts |

`DimCustomerContact` is not a fact slicer. Do not join it to transaction facts
or enable bidirectional filtering; doing so can multiply measures by a
customer's contact count or create ambiguous filter paths.

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
- **Region/classification:** `SalesRegion` (driven by the customer's **own state** — account HQ, not ship-to), `Territory`, `MarketID`, `CustomerGroupID`, raw `CarmsCustomerGroup` / `CarmsCustomerSubGroup` / `CarmsCustomerName`, governed `CustomerReportingGroup` / `CustomerReportingSubGroup` / `CustomerReportingName`, `CustomerType`, `PriceGroup`, `Priority`, `SICCode`, `IndustryCode`, `InternalCustomerFlag`
- **Terms/tax/status:** `DiscountCode`, `CurrencyID`, `DefaultSalesTaxGroupID`, `TaxExemptFlag`, `ActiveFlag`, `AccountOpenDate`, `LastOrderDate`
- **Goal:** `YearlySalesGoal` (numeric) / `YearlySalesGoalRaw` (text)
- **Credit/AR (from VFIN):** `CreditStatus`, `CreditLimitAmount`, `ARTermsRuleID`, `ARPaymentMethodID`, `FinanceChargePct`, `ReceivablesAccountID`, `BillToParentFlag`, email/statement delivery config
- **Compliance:** `FFLLicenseNumber`, `FFLExpirationRaw` (customer-master default; the authoritative FFL is on `DimShipTo`)

For channel reporting, use the governed hierarchy in this order:
`CustomerReportingGroup` → `CustomerReportingSubGroup` →
`CustomerReportingName`. The raw `Carms*` fields remain available to reconcile
the source view and support older reports, but its `EVERYTHING ELSE` value is
too broad for executive reporting.

| Customer reporting group | Subgroups |
|---|---|
| Big Box | Big Box |
| Distribution | Distributor |
| Buy Group | NBS, Sports Inc, Worldwide, Mid States, Other Buy Group |
| Dealer | Independent Dealer, National / Master Dealer |
| International | International |
| Direct to Consumer | Web / E-commerce, Retail / Consumer |
| Special Programs | Ducks Unlimited, Rocky Mountain Elk Foundation, National Wild Turkey Foundation, Employee, Prostaff, Law Enforcement, Military, VIP, Distributor Reward, Industry, Other Non-Profit |
| Internal | Internal |
| Other | Unclassified |

Classification precedence is named special programs, other special-program
customer types, CARMS channel, then `DISCOUNT_CODE` / `CUSTOMER_TYPE` fallback.
This makes the groups mutually exclusive. It is reporting logic only and does
not change ERP pricing or customer setup.

### `bi.vw_DimCustomerContact` — customer-contact assignments (`CustomerContactKey`). No sentinel row.

The model's one deliberate snowflake leaf. Grain is one normalized
`CustomerKey + ContactID` assignment from `CUST_CONTACT -> CONTACT`; a
`ContactID` can belong to multiple customers, so use `CustomerContactKey` as the
row key. Query it directly for CRM/master-data use or relate it
`DimCustomer[CustomerKey]` **1 → many** `DimCustomerContact[CustomerKey]` with
single-direction filtering from customer to contacts. It has no fact
relationship.

- **Identity/role:** `ContactID`, `ContactNumber`, `FirstName`, `LastName`, `ContactName`, `MiddleName`, `Position`, `Salutation`, `Honorific`, `PrimaryContactFlag`
- **Communication:** `Phone`, `PhoneExtension`, `Mobile`, `Fax`, `Email`, `PreferredContactMethodCode`
- **Consent/status:** `DoNotCallPhoneFlag`, `DoNotCallMobileFlag`, `DoNotEmailFlag`, `ContactActiveFlag`
- **Address/profile:** `Address1-3`, `City`, `State`, `ZipCode`, `Country`, `LinkedInURL`, `TwitterURL`, `FacebookURL`
- `PrimaryContactFlag` is optional; do not assume every customer has one. Filter active/consent flags explicitly—the view keeps all rows.
- Web credentials, birth date, gender, marital status, and ungoverned contact UDFs are intentionally excluded.

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
- **Degenerate / tags:** `PacklistID`, `LineNum`, `OrderID`, `OrderLineNo`, `ShipperStatus`/`ShipperStatusDesc`, `ShipmentState` (Shipped/In Review), `InvoiceID`, `TrackingNumber`, `WaybillNumber`, `BillOfLadingID`, `ShipVia`, `RMAID`, `NoInvoiceFlag`, `InventoryTransID`
- **Measures:**
  - *Additive:* `ShippedQty` (stock UM), `ShippedQtySellingUM`, **`ShippedRevenue`** (net shipped revenue booked to AR), `COGSAmount` (actual cost at ship time), `GrossMarginAmount` (= ShippedRevenue − COGS), `COGSMaterial`/`COGSLabor`/`COGSBurden`/`COGSService`, `ActualFreight`, `ShippingWeight`
  - *Non-additive:* `UnitPrice`, `TradeDiscountPct`, `CommissionPct`
- Use `ShipDateKey` for "what shipped when." `ShippedRevenue` is the per-line
  shipped revenue — timely, before the AR invoice posts.
- **Tracking is line-level:** `TrackingNumber` comes from Visual ship-entry UDF
  `UDF-0000028` (`VMSHPENT`, `tblShpLineItem`) on the exact
  `(PacklistID, LineNum)` key. Blank and placeholder `'0'` values are returned
  as NULL. `WaybillNumber` remains the separate packlist-header value from
  `SHIPPER.WAYBILL_NUMBER`; do not substitute one for the other.
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

**Customer contacts for a CRM account lookup:**
```sql
SELECT CustomerContactKey, ContactID, ContactNumber, ContactName, Position,
       Phone, PhoneExtension, Mobile, Email, PrimaryContactFlag,
       PreferredContactMethodCode, DoNotCallPhoneFlag, DoNotCallMobileFlag,
       DoNotEmailFlag, ContactActiveFlag
FROM bi.vw_DimCustomerContact
WHERE CustomerKey = @CustomerID
ORDER BY CASE WHEN PrimaryContactFlag = N'Y' THEN 0 ELSE 1 END,
         ContactName, ContactID;
```
This returns all assigned contacts so the CRM can apply channel-specific active
and consent rules explicitly. Do not join this result to a transaction fact.

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
backlog, shipments, fulfillment, AR revenue, slicing by customer, ship-to /
geography, sales rep, part / product family, site, and any date role — plus
customer-contact lookup for CRM/master-data use. This is the right source for
sales reporting, commercial dashboards, contact lookup, and most "how much did
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

## 10. Current pricing extension (SQL views deployed; Power BI certification pending)

The pricing extension is additive to the certified three-transaction-fact model.
Both SQL views are deployed in the live `bi` schema. Adding them to the certified
Power BI Sales model, including relationship setup and size / refresh
certification, remains pending. Their source DDL lives in the sibling
`power-bi-model/20_facts/` project and is not copied into ChristensenCRM because
the portal ETL does not land either pricing fact. The full rollout and
customer-master remediation plan is in the Power BI project's
`docs/pricing_model_change_map.md`.

### `bi.vw_FactPublishedPriceList`

Current published price book at one row per `PartKey` and `PriceListType` for the
latest `reporting.active_parts_pricelist` effective date with
`pl_status='EXISTING'`. The source's thirteen price columns are normalized into:

- **Keys/context:** `PartKey`, `PriceListDateKey`, `PriceListEffectiveDate`,
  `PriceListTypeKey`, `PriceListType`, `PriceListTypeSortOrder`.
- **Non-additive rate:** `PublishedUnitPrice` (never sum).
- **Provenance:** `PriceListSourceFile`, `PriceListLoadedAt`.

Relate `PartKey` to `DimPart` and `PriceListDateKey` to a role-played
`Price List Date`. Sort `PriceListType` by `PriceListTypeSortOrder`.

### `bi.vw_FactCustomerPartPrice`

Current operational default-price book at one row per active
`CustomerKey + PartKey + SiteKey + SellingUM + PriceListDateKey`. It is limited
to active customers and current published parts; it is not transaction history.

- **Keys/context:** `CustomerKey`, `PartKey`, `SiteKey`, `PriceListDateKey`,
  `PriceListEffectiveDate`, `SellingUM`, `CurrencyID`.
- **Resolved result:** `PricingSourceRank`, `PricingSource`,
  `EffectiveDefaultUnitPrice`, `IsMissingPrice`.
- **Audit candidates:** `CustomerDefaultUnitPrice`,
  `DiscountDefaultUnitPrice`, `MarketDefaultUnitPrice`,
  `PartDefaultUnitPrice`.

Resolution is the first non-null default price in this order:
`CUSTOMER_PRICE -> DISCOUNT_PRICE -> MARKET_PRICE ->
PART_SITE_VIEW.UNIT_PRICE`. Zero is a valid price. The fact uses the part stock
UM; all current published parts are EA. Quantity breaks are not expanded because
none is populated in production today.

Relate it single-direction from `DimCustomer`, `DimPart`, `DimSite`, and the
role-played `Price List Date`. Never relate it to an order, shipment, invoice, or
published-price fact. Use `SELECTEDVALUE(EffectiveDefaultUnitPrice)` in a single
customer/part/site context; do not sum any unit-price field.

`DimCustomer` already supplies `DiscountCode`, `MarketID`, `CurrencyID`,
`PriceGroup`, `CarmsCustomerGroup`, and `CarmsCustomerSubGroup`. `DimPart`
already supplies the `Z_PRODUCT_DETAIL` attributes, so neither set is duplicated
on the pricing facts.
