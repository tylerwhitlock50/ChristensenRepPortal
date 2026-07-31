/*============================================================================
  Object : bi.vw_DimDate
  Source : GENERATED (not sourced from Visual). No ERP dependency.
  Grain  : One row per calendar day, plus one "Unknown" sentinel row.
  Keys   : DateKey int (yyyymmdd, e.g. 20260101) is the relationship key.
           [Date] (date) is the real date column required by Power BI's
           "Mark as date table" + time intelligence.
  Notes  : - Range: 2008-01-01 .. 2034-12-31. Floor is 2008 because facts carry
             history back to 2008 (earliest InvoiceDate 2008-03-07); a real fact
             date before the floor orphans (neither in range nor the 19000101
             sentinel) and drops from time-based reports. Horizon runs a few
             years PAST today so future-dated promise/desired-ship/MRP dates
             still resolve.
           - Sentinel row DateKey = 19000101 catches NULL fact dates wrapped
             with COALESCE(..., 19000101) so those rows don't silently drop.
           - This ONE physical view is referenced as multiple role-playing
             tables in each model (Order Date, Promise Date, etc.). Mark
             EVERY role table as a date table, not just the primary.
           - Built with a stacked-CTE tally (no recursion / MAXRECURSION),
             so it is safe inside a view definition.
============================================================================*/
CREATE OR ALTER VIEW bi.vw_DimDate
AS
WITH
  -- Stacked cross joins: 10^5 = 100,000 candidate rows (~273 years of days) —
  -- far more than the calendar window needs, so the range can never silently
  -- truncate for lack of tally rows. The WHERE in cal caps the actual span.
  d0 AS (SELECT 0 AS n UNION ALL SELECT 0 UNION ALL SELECT 0 UNION ALL SELECT 0 UNION ALL SELECT 0
         UNION ALL SELECT 0 UNION ALL SELECT 0 UNION ALL SELECT 0 UNION ALL SELECT 0 UNION ALL SELECT 0),
  tally AS (
      SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) - 1 AS n
      FROM d0 a CROSS JOIN d0 b CROSS JOIN d0 c CROSS JOIN d0 e CROSS JOIN d0 g
  ),
  -- Calendar window. Base date is 2008-01-01: the facts carry history back to
  -- 2008 (earliest InvoiceDate 2008-03-07), and any real fact date BEFORE the
  -- floor orphans on its DimDate role (it is neither in range nor the 19000101
  -- sentinel), silently dropping that row from time-based reports. Horizon runs
  -- to 2034-12-31 so future-dated promise/ship keys still resolve. Adjust the
  -- base date / horizon here if the range needs to extend; everything
  -- downstream is derived from [Date].
  cal AS (
      SELECT CAST(DATEADD(DAY, n, '2008-01-01') AS date) AS [Date]
      FROM tally
      WHERE DATEADD(DAY, n, '2008-01-01') <= '2034-12-31'
  )
SELECT
    CAST(CONVERT(char(8), [Date], 112) AS int)              AS DateKey,
    [Date],
    YEAR([Date])                                            AS [Year],
    DATEPART(QUARTER, [Date])                               AS [Quarter],
    'Q' + CAST(DATEPART(QUARTER, [Date]) AS varchar(1))     AS QuarterName,
    MONTH([Date])                                           AS MonthNumber,
    DATENAME(MONTH, [Date])                                 AS MonthName,
    LEFT(DATENAME(MONTH, [Date]), 3)                        AS MonthShortName,
    -- Sortable yyyymm for "Sort by column" on MonthYear in Power BI.
    (YEAR([Date]) * 100) + MONTH([Date])                    AS YearMonthNumber,
    LEFT(DATENAME(MONTH, [Date]), 3) + ' ' + CAST(YEAR([Date]) AS varchar(4)) AS MonthYear,
    DAY([Date])                                             AS DayOfMonth,
    DATEPART(DAYOFYEAR, [Date])                             AS DayOfYear,
    DATEPART(WEEKDAY, [Date])                               AS DayOfWeekNumber,
    DATENAME(WEEKDAY, [Date])                               AS DayName,
    DATEPART(ISO_WEEK, [Date])                              AS ISOWeek,
    CAST(CASE WHEN DATEPART(WEEKDAY, [Date]) IN (1, 7) THEN 1 ELSE 0 END AS bit) AS IsWeekend,
    CAST(0 AS bit)                                          AS IsUnknownDate
FROM cal

UNION ALL

-- Unknown / sentinel row for NULL fact dates.
SELECT
    19000101         AS DateKey,
    NULL             AS [Date],
    NULL             AS [Year],
    NULL             AS [Quarter],
    'Unknown'        AS QuarterName,
    NULL             AS MonthNumber,
    'Unknown'        AS MonthName,
    'Unknown'        AS MonthShortName,
    NULL             AS YearMonthNumber,
    'Unknown'        AS MonthYear,
    NULL             AS DayOfMonth,
    NULL             AS DayOfYear,
    NULL             AS DayOfWeekNumber,
    'Unknown'        AS DayName,
    NULL             AS ISOWeek,
    CAST(0 AS bit)   AS IsWeekend,
    CAST(1 AS bit)   AS IsUnknownDate;
GO
