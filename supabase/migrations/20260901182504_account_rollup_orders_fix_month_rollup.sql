/*============================================================================
  20260901182504_account_rollup_orders_fix_month_rollup.sql — placeholder.

  This version number exists in supabase_migrations.schema_migrations
  because a hotfix was applied straight from the CLI on 2026-09-01 without
  a file in this folder: it restated refresh_territory_rollups() to put the
  erp.agg_customer_month block back after 20260901000100 dropped it.

  That restatement was itself incomplete (no first_invoice_date, no
  cancelled-order exclusion on bookings, no erp.agg_sku_month block) and is
  superseded in full by 20260901190100_rollup_restore.sql. This file is
  deliberately a no-op so the deployer's ledger and the CLI's agree on what
  ran, and so a fresh environment never executes the broken body.
============================================================================*/
select 1;
