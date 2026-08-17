/*============================================================================
  035_order_lookup.sql — RLS assertions for the order/PO/tracking lookup
  (migration 035) and the contact-preference flags (034).

  Same harness rules as 010_access_rules.sql / 024_intel_views.sql: runs in a
  transaction and ROLLS BACK, creates throwaway auth users and throwaway ERP
  rows, run against dev — never prod.

      psql "$DATABASE_URL" -f supabase/tests/035_order_lookup.sql

  A clean run prints "ALL LOOKUP TESTS PASSED"; any error is a failure.

  What is actually at stake here
  -----------------------------
  lookup_orders() is the app's first CROSS-ACCOUNT read: every other rep-facing
  query is anchored to one customer_key that the caller already navigated to.
  This one takes a free-text term and searches the whole order history. If its
  RLS is wrong, a rep types a competitor dealer's PO number and reads their
  order book — PRD acceptance criterion #1 failing in the most direct way
  available. Hence the cross-tenant probes below are the point of this file,
  not an afterthought.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures. Self-contained ERP rows rather than the pinned live book, so
-- the assertions are exact counts rather than "greater than zero".
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a', 'aaaaaaaa-4444-4444-8444-444444444444'),
  ('rep_b', 'bbbbbbbb-5555-4555-8555-555555555555'),
  ('admin', 'cccccccc-6666-4666-8666-666666666666');

-- become() reads this table while already acting as `authenticated`, so the
-- fixture table has to be readable by that role too.
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@lookup.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'LOOKUP REPA'
  where user_id = (select id from t_user where label='rep_a');
update public.profiles set sales_rep_key = 'LOOKUP REPB'
  where user_id = (select id from t_user where label='rep_b');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label='admin');

-- One account per rep. Same PO number and same-looking order ids on both, so
-- a leak shows up as a row count rather than needing a careful eyeball.
insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag)
values ('LKUP-A', 'LKUP-A', 'Rep A Dealer', 'LOOKUP REPA', 'Y'),
       ('LKUP-B', 'LKUP-B', 'Rep B Dealer', 'LOOKUP REPB', 'Y');

insert into erp.fact_order_line
  (order_id, line_num, customer_key, customer_po_number, order_date_key,
   promise_date_key, desired_ship_date_key, bookings, order_qty,
   backlog_qty, backlog_amount, is_backlog_line, order_state)
values
  ('LKUPSO-A', 1, 'LKUP-A', 'SHARED-PO-777', 20260701, 20260901, 20260815,
   1000, 2, 2, 1000, true, 'Released'),
  ('LKUPSO-A', 2, 'LKUP-A', 'SECOND-PO-888', 20260701, 20260905, 20260818,
    250, 1, 0,    0, false, 'Released'),
  ('LKUPSO-B', 1, 'LKUP-B', 'SHARED-PO-777', 20260702, 20260902, 20260816,
    900, 3, 3,  900, true, 'Released');

insert into erp.fact_shipment_line
  (packlist_id, line_num, order_id, customer_key, tracking_number,
   ship_date_key, shipped_qty, shipped_revenue)
values ('LKUPPL-A', 1, 'LKUPSO-A', 'LKUP-A', '1ZLOOKUPAAA', 20260710, 1, 500),
       ('LKUPPL-B', 1, 'LKUPSO-B', 'LKUP-B', '1ZLOOKUPBBB', 20260711, 1, 400);

-- ERP contacts for the 034 assertions: one freely contactable, one the ERP
-- has explicitly flagged on both channels.
insert into erp.dim_customer_contact
  (customer_contact_key, customer_key, contact_id, contact_name, phone, mobile,
   email, do_not_call_phone_flag, do_not_call_mobile_flag, do_not_email_flag,
   primary_contact_flag, contact_active_flag)
values
  ('LKUPC-1', 'LKUP-A', 'C1', 'Callable Buyer', '801-555-0100', null,
   'ok@dealer.test',  'N', 'N', 'N', 'Y', 'Y'),
  ('LKUPC-2', 'LKUP-A', 'C2', 'Do Not Call Buyer', '801-555-0199', null,
   'no@dealer.test',  'Y', 'N', 'Y', 'N', 'Y'),
  -- Landline blank, mobile present and flagged: the view shows the mobile, so
  -- the MOBILE flag must govern. A blanket OR would also pass this row, which
  -- is why the next fixture exists.
  ('LKUPC-3', 'LKUP-A', 'C3', 'Mobile Only Flagged', '', '801-555-0177',
   null, 'N', 'Y', 'N', 'N', 'Y'),
  -- Landline present and allowed, mobile flagged. The view shows the
  -- LANDLINE, so this contact must NOT be flagged. This is the row a blanket
  -- OR of the two flags gets wrong.
  ('LKUPC-4', 'LKUP-A', 'C4', 'Desk Ok Cell Not', '801-555-0155', '801-555-0166',
   null, 'N', 'Y', 'N', 'N', 'Y');

--------------------------------------------------------------------------
-- Helper: become a given user as the `authenticated` role.
--------------------------------------------------------------------------
create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  select id into uid from t_user where label = p_label;
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not p_ok then
    raise exception 'FAILED: %', p_what;
  end if;
  raise notice 'ok  %', p_what;
end $$;

--------------------------------------------------------------------------
-- 1. Rep A: sees only their own order, by every search route.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');

select pg_temp.assert(
  (select count(*) from public.lookup_orders('SHARED-PO-777')) = 1,
  'rep A searching a PO number shared with rep B gets exactly one row');

select pg_temp.assert(
  (select customer_key from public.lookup_orders('SHARED-PO-777')) = 'LKUP-A',
  'and that row is rep A''s own account');

select pg_temp.assert(
  (select count(*) from public.lookup_orders('LKUPSO-B')) = 0,
  'rep A cannot reach rep B''s order by its order number');

select pg_temp.assert(
  (select count(*) from public.lookup_orders('1ZLOOKUPBBB')) = 0,
  'rep A cannot reach rep B''s order by its tracking number');

select pg_temp.assert(
  (select tracking_numbers from public.lookup_orders('LKUPSO-A')) = '1ZLOOKUPAAA',
  'rep A does get their own tracking number');

--------------------------------------------------------------------------
-- 2. matched_on tells the rep WHY a row came back.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select matched_on from public.lookup_orders('LKUPSO-A')) = 'order',
  'searching an order number reports matched_on = order');

select pg_temp.assert(
  (select matched_on from public.lookup_orders('SECOND-PO-888')) = 'po',
  'searching a PO number reports matched_on = po');

select pg_temp.assert(
  (select matched_on from public.lookup_orders('1ZLOOKUPAAA')) = 'tracking',
  'searching a tracking number reports matched_on = tracking');

--------------------------------------------------------------------------
-- 3. Measures are not smeared by the shipment-side join. LKUPSO-A has two
--    lines (1000 + 250) and one shipment line; bookings must stay 1250.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select bookings from public.lookup_orders('LKUPSO-A')) = 1250,
  'bookings are not double-counted through the tracking join');

select pg_temp.assert(
  (select line_count from public.lookup_orders('LKUPSO-A')) = 2,
  'line_count is not inflated by the tracking join');

--------------------------------------------------------------------------
-- 4. Consolidated POs: both numbers are shown, not one of them.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select customer_po_number from public.lookup_orders('LKUPSO-A'))
    like '%SHARED-PO-777%',
  'a consolidated order shows its first PO number');
select pg_temp.assert(
  (select customer_po_number from public.lookup_orders('LKUPSO-A'))
    like '%SECOND-PO-888%',
  'a consolidated order shows its second PO number too');

--------------------------------------------------------------------------
-- 5. An empty or whitespace term returns nothing rather than the book.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) from public.lookup_orders('   ')) = 0,
  'a blank search term returns no rows');
select pg_temp.assert(
  (select count(*) from public.lookup_orders('')) = 0,
  'an empty search term returns no rows');

--------------------------------------------------------------------------
-- 6. The uncapped header view still scopes to the caller's book.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) from public.v_account_recent_order_headers
    where customer_key = 'LKUP-B') = 0,
  'rep A gets zero header rows for rep B''s account');

--------------------------------------------------------------------------
-- 7. Migration 034 — do-not-contact flags, including the case a blanket OR
--    of the two phone flags would get wrong.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select do_not_call from public.v_account_contacts
    where contact_key = 'erp-LKUPC-1') = false,
  'an unflagged contact is not marked do-not-call');

select pg_temp.assert(
  (select do_not_call from public.v_account_contacts
    where contact_key = 'erp-LKUPC-2') = true,
  'a landline-flagged contact IS marked do-not-call');

select pg_temp.assert(
  (select do_not_email from public.v_account_contacts
    where contact_key = 'erp-LKUPC-2') = true,
  'a do-not-email contact is marked do-not-email');

select pg_temp.assert(
  (select do_not_call from public.v_account_contacts
    where contact_key = 'erp-LKUPC-3') = true,
  'mobile-only contact takes the MOBILE flag (the shown number)');

select pg_temp.assert(
  (select do_not_call from public.v_account_contacts
    where contact_key = 'erp-LKUPC-4') = false,
  'landline shown + only the cell flagged => NOT do-not-call (a blanket OR fails here)');

--------------------------------------------------------------------------
-- 8. Rep B sees the mirror image, and the empty-book user sees nothing.
--------------------------------------------------------------------------
select pg_temp.become('rep_b');

select pg_temp.assert(
  (select customer_key from public.lookup_orders('SHARED-PO-777')) = 'LKUP-B',
  'rep B searching the same PO gets only their own order');

select pg_temp.assert(
  (select count(*) from public.lookup_orders('1ZLOOKUPAAA')) = 0,
  'rep B cannot reach rep A''s order by tracking number');

select pg_temp.assert(
  (select count(*) from public.v_account_contacts
    where customer_key = 'LKUP-A') = 0,
  'rep B sees none of rep A''s contacts');

--------------------------------------------------------------------------
-- 9. Admin sees both sides — proving the zeros above are RLS, not a broken
--    query that returns nothing for everyone.
--------------------------------------------------------------------------
select pg_temp.become('admin');

select pg_temp.assert(
  (select count(*) from public.lookup_orders('SHARED-PO-777')) = 2,
  'admin searching the shared PO gets both accounts'' orders');

select pg_temp.assert(
  (select count(*) from public.v_account_contacts
    where customer_key = 'LKUP-A') = 4,
  'admin sees every ERP contact on the account');

reset role;

do $$ begin raise notice 'ALL LOOKUP TESTS PASSED'; end $$;

rollback;
