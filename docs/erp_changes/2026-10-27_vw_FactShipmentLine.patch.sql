/*============================================================================
  PATCH  : bi.vw_FactShipmentLine — tracking number joins on the ORDER line
  For    : the owner of the bi.* views (Power BI project)
  From   : Tyler / Rep Portal, 2026-10-27. Read 2026-10-27_bi_view_changes.md
           (same folder) first; it has the evidence and the expected numbers.

  THIS IS NOT A COMPLETE VIEW. It is three find-and-replace edits, written
  against the Rep Portal's copy of the view (docs/bi_schema/
  vw_FactShipmentLine.sql), which may be out of date (all bi views were
  redeployed 2026-09-17; the portal's SQL login has no VIEW DEFINITION).
  Apply the edits to the LIVE definition from your project.

  The output column list (names, order, types) stays EXACTLY the same:
  TrackingNumber is still nvarchar(254), still column 13.

  STATUS: done in the 2026-10-26 redeploy (see 2026-10-27_bi_view_changes.md
  item 2). docs/bi_schema was re-synced from power-bi-model 1a9e94e on
  2026-10-31, so the FIND blocks below no longer occur in our copy.
============================================================================*/


/*----------------------------------------------------------------------------
  EDIT 1 of 3 — the tracking join. Replace the comment and the LEFT JOIN.

  FIND:

-- VMSHPENT UDF-0000028 is defined on tblShpLineItem, so both the packlist and
-- shipper-line number are required. Current source data is unique at this key;
-- validation check B2a guards that assumption so this join cannot fan out.
LEFT JOIN dbo.USER_DEF_FIELDS AS trk
    ON trk.PROGRAM_ID  = N'VMSHPENT'
   AND trk.ID          = N'UDF-0000028'
   AND trk.DOCUMENT_ID = sl.PACKLIST_ID
   AND trk.LINE_NO     = sl.LINE_NO

  REPLACE WITH:
----------------------------------------------------------------------------*/
-- VMSHPENT UDF-0000028 (ship-entry tracking number) is stored per packlist and
-- CUSTOMER-ORDER line: DOCUMENT_ID = PACKLIST_ID, LINE_NO = CUST_ORDER_LINE_NO,
-- not the packlist line number, whatever its tblShpLineItem definition
-- suggests. Verified 2026-10-26: PL-289884 ships order lines 3 and 4 on
-- packlist lines 1 and 2, and its two UDF rows sit on LINE_NO 3 and 4.
-- Pre-aggregated to ONE row per (packlist, order line) before the join, so it
-- cannot fan out the packlist-line grain even if a second UDF row for the same
-- key ever appears (another DEL_LINE_NO, a re-key). MAX skips the NULLs that
-- blank and placeholder '0' values become, so a real number always wins.
-- Lines with no order line (misc / freight) get NULL, as before.
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


/*----------------------------------------------------------------------------
  EDIT 2 of 3 — the select-list expression (the cleaning moved into the
  derived table above; same output type, nvarchar(254)).

  FIND:
    NULLIF(NULLIF(LTRIM(RTRIM(trk.STRING_VAL)), N''), N'0') AS TrackingNumber,

  REPLACE WITH:
----------------------------------------------------------------------------*/
    trk.TrackingNumber                    AS TrackingNumber,


/*----------------------------------------------------------------------------
  EDIT 3 of 3 — the header comment, which states the wrong key.

  FIND:
    - Tracking number is the VMSHPENT shipper-line UDF UDF-0000028. Its UDF
      definition targets TABLE_ID = 'tblShpLineItem', so the value joins on
      (DOCUMENT_ID, LINE_NO) = (SHIPPER_LINE.PACKLIST_ID, SHIPPER_LINE.LINE_NO).
      Blank and placeholder '0' values are exposed as NULL. This is distinct
      from the packlist-header SHIPPER.WAYBILL_NUMBER.

  REPLACE WITH:
    - Tracking number is the VMSHPENT ship-entry UDF UDF-0000028. Visual stores
      it per packlist and CUSTOMER-ORDER line, so it joins on
      (DOCUMENT_ID, LINE_NO) = (SHIPPER_LINE.PACKLIST_ID,
      SHIPPER_LINE.CUST_ORDER_LINE_NO), NOT the packlist LINE_NO (the UDF's
      tblShpLineItem definition is misleading; verified 2026-10-26 on
      PL-289884). Pre-aggregated to one value per key, so it cannot fan out.
      Blank and placeholder '0' values are exposed as NULL. This is distinct
      from the packlist-header SHIPPER.WAYBILL_NUMBER.

  Also update, outside the view:
    - validation check B2a, if it asserts uniqueness on (packlist, packlist
      line): the key it must hold on is now (DOCUMENT_ID, LINE_NO) of the UDF
      rows, which the join above enforces anyway;
    - the semantic-model note "Tracking is line-level … on the exact
      (PacklistID, LineNum) key": it is keyed by (PacklistID, OrderLineNo).
----------------------------------------------------------------------------*/
