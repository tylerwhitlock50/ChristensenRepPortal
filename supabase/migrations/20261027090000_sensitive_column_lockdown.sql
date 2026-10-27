/*============================================================================
  20261027090000_sensitive_column_lockdown.sql — two ERP columns that carried
  sensitive values to every signed-in rep.

  Why
  ---
  The 2026-10-26 Tableau benchmark found two fields reps could read and
  nothing in the app uses:

    erp.dim_customer_contact.salutation   one row holds a 16-digit,
                                           Luhn-valid number (a card number
                                           typed into the wrong ERP field)
    erp.dim_customer.tax_id_number        285 customers have one; some are
                                           SSN-formatted

  007 granted table-level SELECT on both tables to authenticated, and `erp`
  is an exposed PostgREST schema, so GET /rest/v1/dim_customer?select=
  tax_id_number worked with any rep JWT (RLS limited it to the rep's book,
  which is not the point). The only references in the repo are the landing
  DDL (002/032) and views.yml; no view, function or screen reads either one.

  What (three layers; this file is two of them)
  ----
  1. The stored values are nulled, so they are gone from Supabase.
  2. A CHECK constraint keeps each column NULL. Nothing can land a value
     again: a loader still on the old code fails that table's load loudly
     (check_violation on the swap INSERT — etl_stage tables are created
     LIKE … INCLUDING DEFAULTS, without CHECKs, so the COPY itself passes)
     instead of quietly bringing the values back.
  3. (Not here — etl/views.yml `exclude_columns`.) The loader stops landing
     both columns. The ERP side (bi.* views return NULL under the same
     names) is a separate note to the BI developer,
     docs/erp_changes/2026-10-27_bi_view_changes.md; on 2026-10-26 the
     developer already began redacting TaxIDNumber (is_tax_id_redacted,
     20261026180000).

  Grants are deliberately NOT touched. Column-level SELECT (revoke the
  table, grant every other column by name) was the first draft: it makes
  `select=*` on either table "permission denied", and the installed PWA
  (registerType 'prompt') keeps an old bundle whose account page reads
  erp.dim_customer with select('*') until each rep taps Refresh. With no
  values stored and none able to land, a column grant hides nothing, so
  this file costs no deploy ordering against the frontend.

  The loader must be on the exclude_columns code before this is applied,
  or the next dim_customer / dim_customer_contact load fails (see 2).

  Locks: ALTER TABLE … ADD CONSTRAINT takes ACCESS EXCLUSIVE on each table
  while it validates — a scan of a few thousand rows.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The values themselves.
--------------------------------------------------------------------------
update erp.dim_customer
   set tax_id_number = null
 where tax_id_number is not null;

update erp.dim_customer_contact
   set salutation = null
 where salutation is not null;

--------------------------------------------------------------------------
-- 2. And they stay gone.
--------------------------------------------------------------------------
alter table erp.dim_customer
  drop constraint if exists dim_customer_tax_id_number_not_stored;
alter table erp.dim_customer
  add constraint dim_customer_tax_id_number_not_stored
  check (tax_id_number is null);

alter table erp.dim_customer_contact
  drop constraint if exists dim_customer_contact_salutation_not_stored;
alter table erp.dim_customer_contact
  add constraint dim_customer_contact_salutation_not_stored
  check (salutation is null);

comment on column erp.dim_customer.tax_id_number is
  'Not stored (20261027090000): always NULL (CHECK '
  'dim_customer_tax_id_number_not_stored), excluded from the load '
  '(views.yml exclude_columns). Kept only so bi.vw_DimCustomer''s column '
  'list still lines up.';
comment on column erp.dim_customer_contact.salutation is
  'Not stored (20261027090000): always NULL (CHECK '
  'dim_customer_contact_salutation_not_stored), excluded from the load '
  '(views.yml exclude_columns). Kept only so bi.vw_DimCustomerContact''s '
  'column list still lines up.';
