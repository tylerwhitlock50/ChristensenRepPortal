/*============================================================================
  20261027_sensitive_column_lockdown.sql — assertions for
    20261027090000_sensitive_column_lockdown.sql
      erp.dim_customer.tax_id_number         nulled, CHECK keeps it NULL
      erp.dim_customer_contact.salutation    nulled, CHECK keeps it NULL
      grants                                 unchanged (select=* still works)

  Same harness rules as the other files here: runs in a transaction and
  ROLLS BACK, creates throwaway users and ERP rows, dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261027_sensitive_column_lockdown.sql
      (or: etl/run_sql_guard.py <migration> <this file>, from etl/)

  A clean run prints "ALL SENSITIVE COLUMN LOCKDOWN TESTS PASSED".
============================================================================*/

begin;

\set ON_ERROR_STOP on

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'aaaaaaaa-9090-4090-8090-909090909090'),
  ('admin', 'cccccccc-9191-4191-8191-919191919191');
grant select on t_user to authenticated;

create or replace function pg_temp.become(p_label text) returns void
language plpgsql as $$
declare uid uuid;
begin
  select id into uid from t_user where label = p_label;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

/* The statement must fail with check_violation (23514). */
create or replace function pg_temp.assert_check_violation(p_sql text, p_what text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when check_violation then
    raise notice 'ok  % (%)', p_what, sqlerrm;
    return;
  end;
  raise exception 'FAILED: % — ran without a check violation: %', p_what, p_sql;
end $$;

--------------------------------------------------------------------------
-- 1. The stored values are gone (before any fixture is written).
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) from erp.dim_customer where tax_id_number is not null) = 0,
  'no tax_id_number value is stored');

select pg_temp.assert(
  (select count(*) from erp.dim_customer_contact where salutation is not null) = 0,
  'no salutation value is stored');

--------------------------------------------------------------------------
-- 2. The constraints exist, are validated, and refuse a value.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) from pg_constraint
    where contype = 'c' and convalidated
      and (conrelid, conname) in (
        ('erp.dim_customer'::regclass,         'dim_customer_tax_id_number_not_stored'),
        ('erp.dim_customer_contact'::regclass, 'dim_customer_contact_salutation_not_stored'))) = 2,
  'both NOT-STORED check constraints exist and are validated');

select pg_temp.assert_check_violation(
  $q$insert into erp.dim_customer (customer_key, customer_id, customer_name, tax_id_number)
     values ('SL-X1', 'SL-X1', 'Lockdown X', '000-00-0000')$q$,
  'a tax_id_number value cannot be inserted');

select pg_temp.assert_check_violation(
  $q$insert into erp.dim_customer_contact (customer_contact_key, customer_key, contact_id, salutation)
     values ('SL-X1|C1', 'SL-X1', 'C1', 'Mr')$q$,
  'a salutation value cannot be inserted');

--------------------------------------------------------------------------
-- 3. Grants are untouched: an installed PWA that still reads
--    erp.dim_customer with select('*') keeps working.
--------------------------------------------------------------------------
select pg_temp.assert(
  has_table_privilege('authenticated', 'erp.dim_customer', 'select')
  and has_table_privilege('authenticated', 'erp.dim_customer_contact', 'select'),
  'authenticated keeps table-level SELECT on both tables');

-- Fixtures: a rep with one account and one contact, another rep's account.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@lockdown.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set sales_rep_key = 'SL REPA'
  where user_id = (select id from t_user where label = 'rep');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, active_flag, internal_customer_flag)
values ('SL-A1', 'SL-A1', 'Lockdown A One', 'SL REPA', 'Y', 'N'),
       ('SL-B1', 'SL-B1', 'Lockdown B One', 'SL REPB', 'Y', 'N');

insert into erp.dim_customer_contact (customer_contact_key, customer_key, contact_id,
                                      first_name, last_name, email, contact_active_flag)
values ('SL-A1|C1', 'SL-A1', 'C1', 'Ada', 'Buyer', 'ada@lockdown.test', 'Y'),
       ('SL-B1|C1', 'SL-B1', 'C1', 'Bo',  'Buyer', 'bo@lockdown.test',  'Y');

select pg_temp.become('rep');

select pg_temp.assert(
  (select array_agg(c.customer_key || ':' || coalesce(c.tax_id_number, 'null'))
     from (select * from erp.dim_customer where customer_key like 'SL-%') c)
    = array['SL-A1:null'],
  'a rep''s select * on dim_customer works, RLS still scopes it, tax_id_number is null');

select pg_temp.assert(
  (select array_agg(c.first_name || ':' || coalesce(c.salutation, 'null'))
     from (select * from erp.dim_customer_contact where customer_key like 'SL-%') c)
    = array['Ada:null'],
  'a rep''s select * on dim_customer_contact works, RLS still scopes it, salutation is null');

select pg_temp.assert(
  (select array_agg(display_name || '|' || source)
     from public.v_account_contacts where customer_key like 'SL-%')
    = array['Ada Buyer|erp'],
  'v_account_contacts still works for a rep');

select pg_temp.become('admin');
select pg_temp.assert(
  (select array_agg(customer_key order by customer_key)
     from erp.dim_customer where customer_key like 'SL-%') = array['SL-A1', 'SL-B1'],
  'an admin still reads every account (RLS unchanged)');

reset role;

do $$ begin raise notice 'ALL SENSITIVE COLUMN LOCKDOWN TESTS PASSED'; end $$;

rollback;
