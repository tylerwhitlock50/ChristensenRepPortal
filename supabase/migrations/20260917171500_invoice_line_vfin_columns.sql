/*============================================================================
  20260917171500_invoice_line_vfin_columns.sql — land the four columns
  bi.vw_FactInvoiceLine grew on 2026-09-17.

  Why
  ---
  The source view was restated at 17:08 Mountain on 2026-09-17 to sign
  credit memos from VFIN and to classify the revenue GL account. It now
  emits RawVfinAmount, RevenueSignBasis, RevenueAccountClass and
  IsRevenueAccount. The loader copies by source column name
  (push_to_supabase.py), so that night's load failed with

      column "raw_vfin_amount" of relation "fact_invoice_line" does not exist

  and, because a table failed, the post-load rollup refresh was skipped.
  The live table was untouched (the failure is in the staging COPY).

  What the view change means for `revenue`
  ----------------------------------------
  raw_vfin_amount is what `revenue` used to be: the unsigned VFIN amount.
  `revenue` is now signed — memo lines come through negative (basis
  'VECA signed memo' / 'VFIN memo polarity'). Ordinary invoice lines are
  unchanged (basis 'VFIN invoice amount', revenue = raw_vfin_amount).
  Every rollup already filters `is_memo is not true`, so rep-facing revenue
  does not move; anything that sums `revenue` WITHOUT that filter now nets
  credits where it used to add them.

  Grants
  ------
  fact_invoice_line is column-granted (20260901190300), so new columns are
  NOT readable by authenticated until granted. Deliberately left that way:
  nothing in the app reads them yet, and GL account classification is not
  obviously rep-facing. Grant by name when a caller needs one.

  Types match 002/014 convention: numeric / text / boolean, all nullable.
============================================================================*/

alter table erp.fact_invoice_line
  add column if not exists raw_vfin_amount       numeric,
  add column if not exists revenue_sign_basis    text,
  add column if not exists revenue_account_class text,
  add column if not exists is_revenue_account    boolean;

comment on column erp.fact_invoice_line.raw_vfin_amount is
  'Unsigned VFIN invoice-line amount — what `revenue` was before the '
  '2026-09-17 view restatement. `revenue` is this, signed per revenue_sign_basis.';
comment on column erp.fact_invoice_line.revenue_sign_basis is
  'How `revenue` got its sign: ''VFIN invoice amount'' (ordinary line, as-is), '
  '''VECA signed memo'' or ''VFIN memo polarity'' (credit memo, negated).';
comment on column erp.fact_invoice_line.revenue_account_class is
  'GL class of revenue_account_id (REV, LIAB, EXP, ASSET).';
comment on column erp.fact_invoice_line.is_revenue_account is
  'True when revenue_account_id is a REV-class GL account.';
