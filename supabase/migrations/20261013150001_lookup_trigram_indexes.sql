/*============================================================================
  20261013150001_lookup_trigram_indexes.sql — lookup_orders() stops reading
  every order line in the book.

  Why
  ---
  lookup_orders() (035) matches the term anywhere in the number:

      o.order_id                                    ilike '%' || t || '%'
      o.customer_po_number                          ilike '%' || t || '%'
      coalesce(s.tracking_number, s.waybill_number) ilike '%' || t || '%'

  A leading wildcard cannot use a btree, so 035's partial btree indexes sit
  idle and every lookup scans ~501k order lines and ~529k shipment lines
  (and 030 measured that RLS alone does not narrow a rep's scan). That is
  the "Where's my order?" call, with the dealer on the line.

  What
  ----
  pg_trgm, installed the Supabase way (schema `extensions`), and three GIN
  trigram indexes whose expressions are EXACTLY the three predicates above,
  so the planner can answer each with a bitmap index scan (and the OR of
  the first two with a BitmapOr). MIN_LOOKUP_LENGTH is 3 in the client, which
  is one trigram — the smallest term a trigram index can serve.

  lookup_orders() itself is untouched: same body, same signature, same
  SECURITY INVOKER. supabase/tests/20261013_order_lookup_lines.sql EXPLAINs
  the function's own body and requires all three indexes in the plan.

  Measured on a local copy seeded with 500k order lines and 500k shipment
  lines (auto_explain of the real function call, no planner settings
  touched): the planner picks all three indexes on its own — a BitmapOr of
  the two order-line indexes, a bitmap scan on the tracking index — and a
  lookup by order number, PO or tracking number fell from 0.5–1.1 s to
  3–13 ms. Straight after a nightly load, before autovacuum has flushed
  GIN's fast-update pending list (up to 4 MB per index, read on every
  probe), it measured 20–30 ms.

  Cost, honestly
  --------------
  - Lock: one-off, in this migration. CREATE INDEX (not CONCURRENTLY — a
    migration runs in a transaction) takes a SHARE lock: readers carry on,
    writers wait. The only writer is the 5 PM Mountain ETL, so apply this
    outside that window.
  - Build: about a second per index at 500k rows locally.
  - Nightly: the loader swaps each fact table with DELETE + INSERT, so the
    three indexes are maintained row by row inside that swap transaction
    (GIN's fast-update pending list batches it). Locally at 500k rows the
    fact_order_line swap went from 15 s to 20 s and fact_shipment_line from
    14 s to 19 s. Readers are not blocked by any of it — the swap holds
    ROW EXCLUSIVE, and the extra seconds sit in the ETL's own transaction.
  - Disk: 6 MB + 5 MB + 12 MB at 500k rows each.

  Partial on purpose for the two columns that are mostly NULL. Each lookup
  predicate is a strict operator on the indexed expression, which implies
  "is not null", so the planner proves the partial predicate by itself.
============================================================================*/

-- Supabase keeps extensions out of `public` in a schema of their own. A
-- local harness database has no such schema; create it so the same file
-- runs everywhere. A no-op on Supabase, where it already exists.
create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

-- The operator class is looked up where the extension actually lives: a
-- project that enabled pg_trgm from the dashboard before this migration
-- may have it somewhere other than `extensions`, and `create extension if
-- not exists` leaves it there.
do $$
declare
  ops text;
begin
  select quote_ident(n.nspname) || '.gin_trgm_ops'
    into strict ops
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
  where e.extname = 'pg_trgm';

  -- order_id: never null (part of the primary key).
  execute format(
    'create index if not exists idx_fol_order_id_trgm '
    'on erp.fact_order_line using gin (order_id %s)', ops);

  execute format(
    'create index if not exists idx_fol_po_number_trgm '
    'on erp.fact_order_line using gin (customer_po_number %s) '
    'where customer_po_number is not null', ops);

  -- The expression must match lookup_orders() character for character —
  -- coalesce(tracking_number, waybill_number) — or the planner will not
  -- connect the two.
  execute format(
    'create index if not exists idx_fsl_tracking_trgm '
    'on erp.fact_shipment_line using gin ((coalesce(tracking_number, waybill_number)) %s) '
    'where coalesce(tracking_number, waybill_number) is not null', ops);
end;
$$;

comment on index erp.idx_fol_order_id_trgm is
  'Trigram index for lookup_orders() — order_id ILIKE ''%term%'' (20261013150001).';
comment on index erp.idx_fol_po_number_trgm is
  'Trigram index for lookup_orders() — customer_po_number ILIKE ''%term%'' (20261013150001).';
comment on index erp.idx_fsl_tracking_trgm is
  'Trigram index for lookup_orders() — coalesce(tracking_number, waybill_number) '
  'ILIKE ''%term%''. The expression must stay identical to the function''s '
  'predicate (20261013150001).';
