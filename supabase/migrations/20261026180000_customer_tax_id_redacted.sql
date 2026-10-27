/*============================================================================
  20261026180000_customer_tax_id_redacted.sql — land the column
  bi.vw_DimCustomer grew on 2026-10-26.

  Why
  ---
  The source view now redacts TaxIDNumber for some customers and emits
  IsTaxIDRedacted (bit) to say which. The loader copies by source column
  name (push_to_supabase.py), so the 17:00 load failed with

      column "is_tax_id_redacted" of relation "dim_customer" does not exist

  The live table was untouched (the failure is in the staging COPY). The next
  full load replaces tax_id_number with the redacted values — the loader is
  DELETE + INSERT, so no old values linger.

  Grants
  ------
  dim_customer is granted to authenticated table-wide, not by column, so the
  new column is readable under the existing RLS without a grant.

  bit -> boolean, nullable, like the other bit columns the loader lands.
============================================================================*/

alter table erp.dim_customer
  add column if not exists is_tax_id_redacted boolean;

comment on column erp.dim_customer.is_tax_id_redacted is
  'True when the ERP view redacted tax_id_number for this customer.';
