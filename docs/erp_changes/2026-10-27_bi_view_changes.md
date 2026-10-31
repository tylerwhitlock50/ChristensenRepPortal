# bi.* view changes requested for the Rep Portal (2026-10-27)

**To:** the owner of the `bi.*` views in VECA (Power BI project)
**From:** Tyler, prepared with the Rep Portal build
**Status:** requested only. Nothing has been changed on SQL Server; the portal team does not edit these views.

> **Status update, 2026-10-31: items 1 and 3 are in the Power BI project's source, not yet
> deployed.** power-bi-model commit `1a9e94e` makes both changes as requested. Its README lists
> the views as "pending redeploy", so the live views still behave as described below until
> the owner deploys and runs V1-a, V3 and the column-list fingerprint.
>
> - **Item 1:** `vw_FactAvailableToSell` uses `LIKE N'R0[1-9]%'` and publishes
>   `ExcludedLocationPattern = 'NOT R0[1-9]%'`. The header comment and the inventory
>   semantic-model note now state the R01–R09 rule. Per that view's header, the SQL Toolbox
>   query `domains/sales/ats_finished_goods.sql` still defaults to `R10%` only.
> - **Item 3:** `vw_DimCustomer.TaxIDNumber` is `CAST(NULL AS nvarchar(25))` and
>   `vw_DimCustomerContact.Salutation` is `CAST(NULL AS nvarchar(60))`. Both are named in the
>   views' "deliberately excluded" header notes.
>   - The same commit also makes `bi.vw_DimVendor.TaxIDNumber` NULL (the "related" question
>     at the end of item 3).
>   - `IsTaxIDRedacted` now flags an SSN-style token anywhere in the source value, so more
>     customers may show 1.
>   - `YearlySalesGoal` now strips `$` and `,` before parsing.
> - **Column lists are unchanged** (names, order, types), so the portal needs no migration
>   for any of this.
> - **Item 2's two follow-ups** were done in the earlier commit `b5bb587`: validation B2a
>   now checks the (packlist, order line) key, and the semantic-model line says
>   `(PacklistID, OrderLineNo)`.
> - **The portal's copies in `docs/bi_schema/` were re-synced from `1a9e94e`** on
>   2026-10-31. They now show the patched source, which is ahead of what is deployed, so the
>   FIND blocks in the patch files no longer occur in them. The history below is unchanged.

The Rep Portal loads ten of your `bi.vw_*` views into its own database. This note asks for
two small fixes now, confirms a third that your 2026-10-26 redeploy already made, sets one
standing rule, and parks two additions for later. None of the fixes changes a view's output
column list.

**Your 2026-10-26 16:59 redeploy** (every `bi` view, `sys.views.modify_date`) already did part
of this, checked from our side the same evening:

- `vw_FactShipmentLine` now finds tracking on the order line: PL-289884 returns
  `1ZK348C30343430266` on both lines, and 15,362 of 18,056 packlists shipped in 2026 (85%) carry
  a tracking number. **Item 2 is done**; it is kept below only for its validation queries.
- `vw_DimCustomer` added `IsTaxIDRedacted` and redacts 4 customers' `TaxIDNumber`; 285 still
  carry one. Item 3 still asks for all of them.
- `vw_FactShipmentLine` added `StoredReceivableAmount` and now computes `ShippedRevenue`.
  The two new columns failed the portal's 5 PM load until it added them (see item 4).

| # | View | Change | Output columns | When |
|---|---|---|---|---|
| 1 | `bi.vw_FactAvailableToSell` | Sellable stock = SHIPPING locations **R01–R09 only** | unchanged | as soon as practical |
| 2 | `bi.vw_FactShipmentLine` | Tracking-number UDF joins on the **order line**, not the packlist line | unchanged | **done** 2026-10-26 |
| 3 | `bi.vw_DimCustomer`, `bi.vw_DimCustomerContact` | Return `TaxIDNumber` and `Salutation` as typed NULLs | unchanged | as soon as practical |
| 4 | every view the portal loads | Rule: tell Tyler **before** any column change | n/a | standing |
| 5 | `bi.vw_FactOrderLine` | Add `WantDate`, `MiscReference` | adds 2 | **only when Tyler asks** |

The same edits, as find-and-replace blocks, are in the patch files next to this note:

- `2026-10-27_vw_FactAvailableToSell.patch.sql`
- `2026-10-27_vw_FactShipmentLine.patch.sql` (already applied in substance; reference only)
- `2026-10-27_sensitive_fields.patch.sql`

## Before you start: apply to the live definitions

- **The patches are written against the portal's copies of your views** (`docs/bi_schema/*.sql`
  in the portal repo). Those copies may be stale. Every `bi` view was redeployed on
  2026-09-17 (`sys.views.modify_date` about 17:08), and the portal's SQL login has no VIEW
  DEFINITION, so we cannot read the live text.
  **Make each edit in the live definition from your project.** Do not paste a whole view from
  our copy over yours.
- **What we could check from our side** (sql-toolbox login, read-only, 2026-10-26):
  - The live column lists of the four views match our copies: names, order and types, from
    `sys.columns`.
  - Every FIND block in the patch files occurs exactly once in our copies.
  - For views 1 and 2, we described the patched SELECT with
    `sys.dm_exec_describe_first_result_set` and compared it with the live view. The result was
    24/24 and 41/41 columns, with **0 name, type or nullability differences**.
  - For view 3, the typed NULLs have exactly the live types: `nvarchar(25)` and `nvarchar(60)`.
- **Column-list fingerprint.** Run this before and after your change. The numbers must not
  move; these are the values after your 2026-10-26 16:59 redeploy:

  ```sql
  SELECT OBJECT_NAME(c.object_id) AS view_name, COUNT(*) AS columns,
         CHECKSUM_AGG(CHECKSUM(c.column_id, c.name, c.user_type_id, c.max_length,
                               c.precision, c.scale, c.is_nullable)) AS column_list_checksum
  FROM sys.columns AS c
  WHERE c.object_id IN (OBJECT_ID('bi.vw_FactAvailableToSell'), OBJECT_ID('bi.vw_FactShipmentLine'),
                        OBJECT_ID('bi.vw_DimCustomer'), OBJECT_ID('bi.vw_DimCustomerContact'))
  GROUP BY c.object_id
  ORDER BY 1;
  -- vw_DimCustomer          66    297413874
  -- vw_DimCustomerContact   35   2134847609
  -- vw_FactAvailableToSell  24    365908050
  -- vw_FactShipmentLine     42    837224377
  ```

- **Expected numbers** below were taken 2026-10-26 around 4:35 PM Mountain. Stock, orders and
  shipments keep moving, so expect small drift. The *shape* of each before/after is what matters.
- **Optional ask:** `GRANT VIEW DEFINITION ON SCHEMA::bi TO <portal SQL login>`. With it, the
  portal could keep its copies in sync and check changes like these itself.

---

## 1. ATS: sellable stock is SHIPPING locations R01–R09 only (`bi.vw_FactAvailableToSell`)

**Business rule (Tyler, 2026-10-26).** Domestic reps can sell only stock that sits in the
SHIPPING warehouse's rack locations R01–R09 (today 21 of them hold stock, R01S02 … R08S04).
Everything else in SHIPPING is reserved and must not count toward Available To Sell:

- R10 (staging)
- R11 (components)
- INTERNATIONAL
- STAGE, STAGE1, STAGE2, STAGE3
- SHELF PREP, TOP SHELF, SHIPPING, SHIPPING RFBMRK (all currently zero)

**Current rule:** SHIPPING minus `LOCATION_ID LIKE N'R10%'`.
**New rule:** SHIPPING and `LOCATION_ID LIKE N'R0[1-9]%'`.

The test is positive, not a list of exclusions, so a new location is reserved until someone
decides it is sellable. `R0[1-9]` does not match R10 or R11.

### Keep the column list identical

A new column would break the portal's ATS load (every 15 minutes on weekdays) until the portal
adds that column first. So two existing columns are repurposed:

| Column | Old meaning | New meaning |
|---|---|---|
| `ExcludedStagingQty` | SHIPPING qty in `R10%` | **all** SHIPPING qty outside R01–R09 (the name predates the rule) |
| `ExcludedLocationPattern` (nvarchar(15)) | `'R10%'` | `'NOT R0[1-9]%'` (12 characters), read as "every location not like R0[1-9]% is excluded" |

`ShippingOnHandBeforeExclusionsQty = ShippingOnHandQty + ExcludedStagingQty` still holds on
every row. The two CASEs are exact complements, so a NULL `LOCATION_ID` falls on the excluded
side.

### Exact replacement expressions (all in the `ShippingOnHand` CTE, plus one constant)

```sql
-- ShippingOnHandQty  (was: WHEN pl.LOCATION_ID LIKE N'R10%' THEN 0 ELSE ISNULL(pl.QTY, 0))
SUM(CASE
        WHEN pl.LOCATION_ID LIKE N'R0[1-9]%' THEN ISNULL(pl.QTY, 0)
        ELSE 0
    END) AS ShippingOnHandQty,

-- ExcludedStagingQty (was: WHEN pl.LOCATION_ID LIKE N'R10%' THEN ISNULL(pl.QTY, 0) ELSE 0)
SUM(CASE
        WHEN pl.LOCATION_ID LIKE N'R0[1-9]%' THEN 0
        ELSE ISNULL(pl.QTY, 0)
    END) AS ExcludedStagingQty

-- HAVING, second term (was the R10% CASE): same expression as ExcludedStagingQty
HAVING SUM(ISNULL(pl.QTY, 0)) <> 0
    OR SUM(CASE
               WHEN pl.LOCATION_ID LIKE N'R0[1-9]%' THEN 0
               ELSE ISNULL(pl.QTY, 0)
           END) <> 0

-- Final SELECT (was: CAST(N'R10%' AS nvarchar(15)) AS ExcludedLocationPattern,)
CAST(N'NOT R0[1-9]%' AS nvarchar(15)) AS ExcludedLocationPattern,
```

Also update the two header-comment lines that say "outside R10 staging" and "R10% locations are
staging". The patch file has the wording. Nothing else in the view changes: open demand, the
credit split, the supply-link diagnostics and the signed ATS all stay as they are.

### Expected before/after

"After" is the patched SELECT run live against VECA. "In stock" means `AvailableToSellQty > 0`,
which is how both the portal and Tableau count it.

| Measure | Before (live view) | After (patched) |
|---|---|---|
| View rows | 802 | 802 |
| SKUs in stock | **66** | **23** |
| … rifles (all but the 4 `FG-BARACT` barreled actions) | n/a | **19** |
| Units available (sum of positive ATS) | **273** | **100** |
| `IsOversold = 1` rows | 695 | 724 |
| `SUM(ShippingOnHandBeforeExclusionsQty)` | 727 | 727 |
| `SUM(ShippingOnHandQty)` (sellable) | 707 | 186 |
| `SUM(ExcludedStagingQty)` | 20 | 541 |
| `ExcludedLocationPattern` | `R10%` | `NOT R0[1-9]%` |
| Rows where before-exclusions ≠ sellable + excluded | 0 | 0 |

The 541 excluded units after the change sit in these locations:

- INTERNATIONAL: 186
- STAGE1: 238
- R11: 93
- R10: 20
- STAGE3: 3
- STAGE: 1

The 43 SKUs that drop out of "in stock" are:

- 24 `FG-STOCK` (stocks held in R11)
- 3 component parts held in INTERNATIONAL
- 16 rifles whose surplus over open orders is held in INTERNATIONAL

The 23 SKUs in stock after the change, by product code:

| ProductCode | SKUs in stock | Units |
|---|---|---|
| EVOKE | 4 | 8 |
| FG-BARACT | 4 | 10 |
| MESA | 1 | 1 |
| MESA FFT | 1 | 6 |
| MESA-LR | 1 | 1 |
| MPR PRO | 1 | 2 |
| MPR RIMFIRE | 1 | 1 |
| RIDGELINE FFT | 8 | 69 |
| RIDGELINE SCOUT | 1 | 1 |
| TRAVERSE | 1 | 1 |

**Cross-check against Tableau.** Tableau's rep list ("ATS LIST", SALES REP DASHBOARDS, extract
refreshed 1:09 PM on 2026-10-26) shows **24 SKUs / 83 units**. It shows rifles only, because
its product-code filter hides barreled actions. All 19 rifles above are on Tableau's list.
Tableau's other 5 are explained by timing and by demand, not by location:

- Two were issued out of stock after the extract (2:31 PM and 3:32 PM).
- Three have the same on-hand stock under the old and new location rules. They differ only in
  how much open-order demand Tableau's own query subtracts.

**Your Power BI ATS reports will show the same drop.** That is intended: it is the business
rule. Two other places still describe the R10-only rule and should change with the view:

- the inventory semantic-model note ("excluding locations matching `R10%`")
- the SQL Toolbox query `domains/sales/ats_finished_goods.sql`, if it is meant to keep matching
  this view

### Validation queries

```sql
-- V1-a. Headline. Before: 66 / 273 / 'R10%'.  After: 23 / 100 / 'NOT R0[1-9]%', 0 non-reconciling rows.
SELECT COUNT(*) AS view_rows,
       SUM(CASE WHEN AvailableToSellQty > 0 THEN 1 ELSE 0 END)                  AS skus_in_stock,
       SUM(CASE WHEN AvailableToSellQty > 0 THEN AvailableToSellQty ELSE 0 END) AS units_available,
       SUM(CASE WHEN IsOversold = 1 THEN 1 ELSE 0 END)                          AS oversold_rows,
       SUM(ShippingOnHandBeforeExclusionsQty) AS shipping_all_locations,
       SUM(ShippingOnHandQty)                 AS sellable_r01_r09,
       SUM(ExcludedStagingQty)                AS excluded,
       SUM(CASE WHEN ShippingOnHandBeforeExclusionsQty
                     <> ShippingOnHandQty + ExcludedStagingQty THEN 1 ELSE 0 END) AS rows_not_reconciling,
       MIN(ExcludedLocationPattern) AS pattern_min,
       MAX(ExcludedLocationPattern) AS pattern_max
FROM bi.vw_FactAvailableToSell;

-- V1-b. Independent recompute from PART_LOCATION. After the change, r01_r09_qty must equal
-- SUM(ShippingOnHandQty) and other_shipping_qty must equal SUM(ExcludedStagingQty) from V1-a
-- (2026-10-26: 186 and 541).
SELECT SUM(CASE WHEN pl.LOCATION_ID LIKE N'R0[1-9]%' THEN pl.QTY ELSE 0 END) AS r01_r09_qty,
       SUM(CASE WHEN pl.LOCATION_ID LIKE N'R0[1-9]%' THEN 0 ELSE pl.QTY END) AS other_shipping_qty
FROM dbo.PART_LOCATION AS pl
WHERE pl.WAREHOUSE_ID = N'SHIPPING';

-- V1-c. In stock by product code (expected after: the table above).
SELECT p.ProductCode, COUNT(*) AS skus_in_stock, SUM(a.AvailableToSellQty) AS units
FROM bi.vw_FactAvailableToSell AS a
LEFT JOIN bi.vw_DimPart AS p ON p.PartKey = a.PartKey
WHERE a.AvailableToSellQty > 0
GROUP BY p.ProductCode
ORDER BY p.ProductCode;
```

---

## 2. Tracking number joins on the order line (`bi.vw_FactShipmentLine`)

> **Done in your 2026-10-26 16:59 redeploy** (PL-289884 now returns its tracking number; 85% of
> 2026 packlists carry one). Nothing to change. The validation queries below still apply.

**The bug.** The view joins ship-entry UDF `UDF-0000028` (`PROGRAM_ID = 'VMSHPENT'`) with
`trk.DOCUMENT_ID = sl.PACKLIST_ID AND trk.LINE_NO = sl.LINE_NO`. Visual stores the value per
packlist and **customer-order line**: `LINE_NO` holds `SHIPPER_LINE.CUST_ORDER_LINE_NO`, not the
packlist line number.

Example: packlist **PL-289884** ships order lines 3 and 4 on packlist lines 1 and 2. Its two UDF
rows sit on `LINE_NO` 3 and 4, both `1ZK348C30343430266`. The live view returns NULL tracking
on both lines.

The old join only matched when a packlist line number happened to equal its order line number.
The header comment and the join comment state the wrong key and need correcting too.

**The fix.**

- Join `trk.LINE_NO = sl.CUST_ORDER_LINE_NO`.
- Pre-aggregate the UDF to one row per `(DOCUMENT_ID, LINE_NO)` first, so the join can never fan
  out the packlist-line grain. This is the same pattern as `DemandSupplyLinkByLine` in the ATS
  view.
- Move the existing blank/`'0'` cleaning inside the aggregate. `MAX` skips the NULLs those
  become, so a real tracking number always wins.

Replace the tracking `LEFT JOIN` (and its comment) with:

```sql
-- VMSHPENT UDF-0000028 (ship-entry tracking number) is stored per packlist and
-- CUSTOMER-ORDER line: DOCUMENT_ID = PACKLIST_ID, LINE_NO = CUST_ORDER_LINE_NO,
-- not the packlist line number. Pre-aggregated to ONE row per key so the join
-- cannot fan out the packlist-line grain.
LEFT JOIN (
    SELECT
        u.DOCUMENT_ID,
        u.LINE_NO,
        MAX(NULLIF(NULLIF(LTRIM(RTRIM(u.STRING_VAL)), N''), N'0')) AS TrackingNumber
    FROM dbo.USER_DEF_FIELDS AS u
    WHERE u.PROGRAM_ID = N'VMSHPENT'
      AND u.ID         = N'UDF-0000028'
    GROUP BY
        u.DOCUMENT_ID,
        u.LINE_NO
) AS trk
    ON trk.DOCUMENT_ID = sl.PACKLIST_ID
   AND trk.LINE_NO     = sl.CUST_ORDER_LINE_NO
```

Then change the select-list line:

```sql
-- was: NULLIF(NULLIF(LTRIM(RTRIM(trk.STRING_VAL)), N''), N'0') AS TrackingNumber,
trk.TrackingNumber                    AS TrackingNumber,
```

`TrackingNumber` stays column 13, `nvarchar(254)`, nullable. The patch file has the corrected
header-comment wording.

**Also update** two things outside the view:

- Your validation check B2a, if it asserts uniqueness on (packlist, packlist line).
- The semantic-model line "Tracking is line-level … on the exact (PacklistID, LineNum) key".
  The key is (PacklistID, OrderLineNo).

### Why there is no row multiplication

- **On the UDF side.** `UDF-0000028` has about 395,200 rows, and every `(DOCUMENT_ID, LINE_NO)`
  pair is distinct. `DEL_LINE_NO` is NULL on all of them. Unique index `X_USER_DEF_FIELDS_0` is on
  `(PROGRAM_ID, ID, DOCUMENT_ID, LINE_NO, DEL_LINE_NO)`. The pre-aggregation makes the join
  one-to-one by construction anyway, even if a second row per key ever appears.
- **On the shipper side.** No packlist ships the same order line on two packlist lines today:
  `(PACKLIST_ID, CUST_ORDER_LINE_NO)` is unique in `SHIPPER_LINE`. If one ever did, both packlist
  lines would get the same tracking number. That is correct, and it adds no rows.
- **Proven live.** The patched view returns the same row count as the live view, and the same
  number of distinct `(PacklistID, LineNum)`.

| Measure | Before (live view) | After (patched) |
|---|---|---|
| View rows, all time | 495,106 | **495,106** |
| Distinct `(PacklistID, LineNum)` | 495,106 | **495,106** |
| Lines with a `TrackingNumber`, all time | 191,525 | 368,281 |
| Packlists shipped since 2026-07-01 with at least one tracking number | 1,750 of 6,779 (**25.8%**) | 4,860 of 6,779 (**71.7%**) |
| Lines shipped since 2026-07-01 with tracking | 2,353 of 9,408 | 6,024 of 9,408 |
| PL-289884 | NULL, NULL | `1ZK348C30343430266` on both lines |

**History that changes.** Since 2026-07-01, no line loses or changes a value. Across all time:

- **191,450 lines keep the same value.**
- **44 lines (2018 to Aug 2025) change value.** The old join had picked up a different order
  line's number on the same packlist.
- **31 lines lose a value.** 24 of them are single-line packlists shipped 14–15 May 2024, where
  the UDF was stored against line 1. The other 7 range from 2021 to Jan 2026.

We recommend accepting the 31. A fallback to the packlist line number would reintroduce the
coincidental matches the fix removes.

**What still has no tracking** (since July) is mostly packlists where the ship-entry UDF was
never filled:

- USPS: 1,165 of 1,170 packlists
- UPS services: about 340 (UPS 249, UPS/ECONOMY 47, 2ND DAY AIR 38, NEXT DAY AIR 10)

That gap is a data-entry matter, not the view. Please do **not** switch the source to
`Z_UPS_SHIPMENTS`: it covers UPS only.

### Validation queries

```sql
-- V2-a. Grain and coverage. view_rows = distinct_packlist_lines before AND after;
-- lines_with_tracking 191,525 -> ~368,281.
SELECT COUNT_BIG(*) AS view_rows,
       COUNT_BIG(DISTINCT CONCAT(PacklistID, N'|', LineNum)) AS distinct_packlist_lines,
       SUM(CASE WHEN TrackingNumber IS NOT NULL THEN 1 ELSE 0 END) AS lines_with_tracking
FROM bi.vw_FactShipmentLine;

-- V2-b. Must return no rows.
SELECT PacklistID, LineNum, COUNT(*) AS n
FROM bi.vw_FactShipmentLine
GROUP BY PacklistID, LineNum
HAVING COUNT(*) > 1;

-- V2-c. Packlist coverage since 2026-07-01: ~25.8% -> ~71.7%.
SELECT COUNT(*) AS packlists, SUM(has_trk) AS with_tracking,
       CAST(100.0 * SUM(has_trk) / COUNT(*) AS decimal(5,1)) AS pct
FROM (SELECT PacklistID,
             MAX(CASE WHEN TrackingNumber IS NOT NULL THEN 1 ELSE 0 END) AS has_trk
      FROM bi.vw_FactShipmentLine
      WHERE ShipDateKey >= 20260701
      GROUP BY PacklistID) AS p;

-- V2-d. The example: both lines -> 1ZK348C30343430266 after the change.
SELECT PacklistID, LineNum, OrderLineNo, TrackingNumber
FROM bi.vw_FactShipmentLine
WHERE PacklistID = N'PL-289884'
ORDER BY LineNum;

-- V2-e. The UDF key assumption: udf_rows = distinct_keys (both 395,224 on 2026-10-26).
SELECT COUNT(*) AS udf_rows,
       COUNT(DISTINCT CONCAT(DOCUMENT_ID, N'|', LINE_NO)) AS distinct_keys
FROM dbo.USER_DEF_FIELDS
WHERE PROGRAM_ID = N'VMSHPENT' AND ID = N'UDF-0000028';
```

---

## 3. Stop publishing two sensitive fields

A review of the portal's copy of these views found sensitive personal data in two free-text
fields: payment-card-like and SSN-style numbers. Tyler is cleaning the ERP records himself.
On the portal side, in the same release as this note:

- the portal stops loading both columns
- the copies already stored are blanked, and a constraint keeps them blank

Your redeploy already redacts `TaxIDNumber` for 4 customers (`IsTaxIDRedacted = 1`). The ask is
the same for every row; keep `IsTaxIDRedacted` as it is (the portal now loads it).

They should not leave the ERP for BI use either.

| View | Column (position) | Replace `c.<col> AS …` with |
|---|---|---|
| `bi.vw_DimCustomer` | `TaxIDNumber` (43 of 65) | `CAST(NULL AS nvarchar(25)) AS TaxIDNumber,` |
| `bi.vw_DimCustomerContact` | `Salutation` (12 of 35) | `CAST(NULL AS nvarchar(60)) AS Salutation,` |

The column names, positions, types and nullability stay the same, so nothing that selects them
breaks. They just come back NULL. The types match the source columns (`CUSTOMER.TAX_ID_NUMBER`
nvarchar(25), `CONTACT.SALUTATION` nvarchar(60)). Please also add both fields to the views'
"deliberately excluded" header notes.

**What Power BI loses.** Today 285 customer rows carry a `TaxIDNumber` and 9,653 contact rows
carry a `Salutation`. `Salutation` is widely filled and mostly distinct free text (about 7,400
different values), so a mail merge or contact report could be using it. `Honorific` is
untouched. Before you apply the change:

- **Search your Power BI model** (PBIP / TMDL / measures) for `TaxIDNumber` and `Salutation`.
  We cannot see it.
- **Tableau:** its Catalog lists `vw_DimCustomer` and `vw_DimCustomerContact` with 0 downstream
  workbooks (checked 2026-10-26).
- **Inside VECA:** we could not check, because we have no VIEW DEFINITION. With your access, run
  the query below. It looks for modules that read either view, rather than for the column
  names: the database collation is case-insensitive, so a search for `Salutation` would also
  return the 25 or so Visual `dbo` views that expose a `SALUTATION` column, and `TaxIDNumber`
  also appears in `bi.vw_DimVendor`.

  ```sql
  -- Modules that read bi.vw_DimCustomer or bi.vw_DimCustomerContact. Expect no rows;
  -- for any row, check whether it uses TaxIDNumber or Salutation.
  SELECT OBJECT_SCHEMA_NAME(m.object_id) AS schema_name, OBJECT_NAME(m.object_id) AS object_name
  FROM sys.sql_modules AS m
  WHERE m.definition LIKE N'%vw[_]DimCustomer%'   -- also matches vw_DimCustomerContact
    AND m.object_id NOT IN (OBJECT_ID(N'bi.vw_DimCustomer'), OBJECT_ID(N'bi.vw_DimCustomerContact'));
  ```

If a finance report genuinely needs the tax ID, give it a separate object with its own narrow
grant, rather than the shared customer dimension.

```sql
-- V3. Both 0 after the change (column types: re-run the fingerprint at the top).
SELECT (SELECT COUNT(*) FROM bi.vw_DimCustomer        WHERE TaxIDNumber IS NOT NULL) AS customers_with_tax_id,
       (SELECT COUNT(*) FROM bi.vw_DimCustomerContact WHERE Salutation  IS NOT NULL) AS contacts_with_salutation;
```

**Related, outside this request:** `bi.vw_DimVendor` also publishes a `TaxIDNumber` (column 37;
29 vendors have one, none in SSN format). The portal does not load vendors. Whether it gets the
same treatment is Tyler's call.

---

## 4. The rule for any column change in a view the portal loads

The portal reads each view with `SELECT *` and copies the columns **by name** into its own
tables. A column it has no place for fails that table's whole load: `column "x" of relation
"y" does not exist`. That table then stops refreshing in the portal until someone fixes it. The
same applies to a renamed column, and can apply to a changed type.

**Views the portal loads:**

- `vw_DimCustomer`
- `vw_DimShipTo`
- `vw_DimSalesRep`
- `vw_DimPart`
- `vw_DimCustomerContact`
- `vw_FactOrderLine`
- `vw_FactInvoiceLine`
- `vw_FactShipmentLine`
- `vw_FactInventoryOnHand`
- `vw_FactAvailableToSell`

On 2026-10-26 the redeploy added `IsTaxIDRedacted` and `StoredReceivableAmount` unannounced,
and both tables failed the 5 PM portal load until the portal added the columns by hand.

**Before you add, rename, drop or retype a column in one of them**, or change its grain or key:

1. **Tell Tyler first.** Give the exact column name and type. The portal derives its column name
   from yours (`TrackingNumber` becomes `tracking_number`), so the spelling matters.
2. The portal adds the column on its side and deploys.
3. You change the view.
4. Tyler runs a full portal load.

Also tell Tyler if a view starts reading a new database or schema. When
`vw_FactInvoiceLine` began reading VFIN on 2026-09-17, the portal's SQL login needed SELECT there.

**When the portal reads** (Mountain time, after the move to the BI server):

| Load | When | What it reads |
|---|---|---|
| Stock | every 15 minutes, weekdays 5:00 AM–5:45 PM | `vw_FactAvailableToSell` |
| Hourly | weekdays 6:05 AM–4:05 PM | `vw_DimCustomer`, `vw_DimPart`, `vw_FactOrderLine`, `vw_FactInvoiceLine`, `vw_FactShipmentLine` |
| Full | 4:30 AM daily, and 5:00 PM weekdays | all ten views |

Evenings after about 6 PM, or weekends away from 4:30 AM, are the quiet window for view changes.
Changes 1 and 3 add no columns and are safe at any time.

---

## 5. Later, not now (only when Tyler asks)

Each of these needs the portal's migration in place **first** (see section 4). Please do not
apply them until Tyler confirms that migration is live. Add both at the **end** of
`bi.vw_FactOrderLine`'s select list:

```sql
    -- Customer "want" date: the line's promised delivery date, else the order header's.
    -- Source columns are datetime with no time part (0 of 2,471 open lines have one),
    -- so date is lossless; confirm the type with Tyler when the portal migration is written.
    CAST(COALESCE(line.PROMISE_DEL_DATE, hdr.PROMISE_DEL_DATE) AS date) AS WantDate,
    line.MISC_REFERENCE                                                 AS MiscReference
```

As of 2026-10-26, among the 2,471 open backlog lines:

- 22 have a line-level `PROMISE_DEL_DATE`
- 2,388 take the header value
- 61 have neither
- 2,438 carry a `MISC_REFERENCE` (`nvarchar(120)`)

Questions: Tyler.
