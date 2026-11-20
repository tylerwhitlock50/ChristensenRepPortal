/*============================================================================
  20261120_rep_resources.sql — RLS assertions for public.rep_resources,
  my_rep_group_vendor_ids() and the rep-resources Storage bucket
  (migration 20261120120000).

  Same harness rules as 20260817_price_lists.sql: runs in a transaction and
  ROLLS BACK, creates throwaway auth users, run against dev — never prod.

      psql "$DATABASE_URL" -f supabase/tests/20261120_rep_resources.sql

  A clean run prints "ALL REP RESOURCE TESTS PASSED"; any error is a failure.

  What is at stake: unlike the price-list sheets, a resource can be meant
  for one agency or one account (an account's own price list). So the READ
  side matters here as much as the write side: a rep must not see, or sign
  a URL for, another agency's or another rep's account's file.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep_a',     'aaaaaaaa-1120-4120-8120-112011201120'),
  ('rep_b',     'bbbbbbbb-1120-4120-8120-112011201120'),
  ('principal', 'cccccccc-1120-4120-8120-112011201120'),
  ('inside',    'dddddddd-1120-4120-8120-112011201120'),
  ('admin',     'eeeeeeee-1120-4120-8120-112011201120'),
  ('gone',      'ffffffff-1120-4120-8120-112011201120');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@resources.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

-- Two agencies: RRT ONE (rep A, and its principal), RRT TWO (rep B).
update public.profiles set sales_rep_key = 'RRT REPA'
  where user_id = (select id from t_user where label = 'rep_a');
update public.profiles set sales_rep_key = 'RRT REPB'
  where user_id = (select id from t_user where label = 'rep_b');
update public.profiles set rep_group_vendor_id = 'RRT ONE'
  where user_id = (select id from t_user where label = 'principal');
update public.profiles set role = 'order_entry'
  where user_id = (select id from t_user where label = 'inside');
update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');
-- A deactivated rep in agency ONE: belongs to no agency any more.
update public.profiles set sales_rep_key = 'RRT REPA', active = false
  where user_id = (select id from t_user where label = 'gone');

insert into erp.dim_sales_rep (sales_rep_key, sales_rep_name, vendor_id) values
  ('RRT REPA', 'Rep Alpha', 'RRT ONE'),
  ('RRT REPB', 'Rep Bravo', 'RRT TWO');

insert into erp.dim_customer (customer_key, customer_id, customer_name,
                              assigned_sales_rep_id, assigned_sales_rep_name,
                              active_flag, internal_customer_flag)
values ('RRT-A1', 'RRT A1', 'Resource Dealer A', 'RRT REPA', 'Rep Alpha', 'Y', 'N'),
       ('RRT-B1', 'RRT B1', 'Resource Dealer B', 'RRT REPB', 'Rep Bravo', 'Y', 'N');

-- Five files, one per audience shape, inserted as postgres (fixture setup,
-- not a policy probe). Titles carry the audience.
insert into public.rep_resources
  (title, category, rep_group_vendor_id, customer_key, storage_path, file_name)
values
  ('RRT everyone',    'program',    null,      null,     'program/everyone.pdf',  'everyone.pdf'),
  ('RRT agency one',  'price_list', 'RRT ONE', null,     'price_list/one.xlsx',   'one.xlsx'),
  ('RRT agency two',  'price_list', 'RRT TWO', null,     'price_list/two.xlsx',   'two.xlsx'),
  ('RRT account A1',  'price_list', null,      'RRT-A1', 'price_list/a1.xlsx',    'a1.xlsx'),
  ('RRT account B1',  'price_list', null,      'RRT-B1', 'price_list/b1.xlsx',    'b1.xlsx');

insert into storage.buckets (id, name, public)
values ('rep-resources', 'rep-resources', false)
on conflict (id) do nothing;

insert into storage.objects (bucket_id, name)
select 'rep-resources', storage_path from public.rep_resources where title like 'RRT %';

-- An object with no row: an upload whose metadata insert never landed.
insert into storage.objects (bucket_id, name)
values ('rep-resources', 'other/orphan.pdf');

-- Local harness only: its stubbed storage.objects has neither RLS enabled
-- nor grants (the real platform has both). On dev these ALTERs fail with
-- insufficient_privilege, and there the real config is already in place.
do $$
begin
  begin
    alter table storage.objects enable row level security;
    grant usage on schema storage to authenticated;
    grant select, insert, update, delete on storage.objects to authenticated;
  exception when insufficient_privilege then
    raise notice 'storage.objects is platform-managed here; using live config';
  end;
end $$;

--------------------------------------------------------------------------
-- Helpers
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

create or replace function pg_temp.assert_fails(p_sql text, p_what text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    raise notice 'ok  % (rejected: %)', p_what, sqlerrm;
    return;
  end;
  raise exception 'FAILED: % — statement succeeded but should have been rejected', p_what;
end $$;

create or replace function pg_temp.visible() returns text
language sql as $$
  select coalesce(string_agg(title, ', ' order by title), '')
  from public.rep_resources where title like 'RRT %'
$$;

create or replace function pg_temp.visible_objects() returns text
language sql as $$
  select coalesce(string_agg(name, ', ' order by name), '')
  from storage.objects where bucket_id = 'rep-resources'
$$;

--------------------------------------------------------------------------
-- 1. my_rep_group_vendor_ids()
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(
  (select array_agg(v) from public.my_rep_group_vendor_ids() v) = array['RRT ONE'],
  'a rep belongs to the agency their rep row bills through');

select pg_temp.become('principal');
select pg_temp.assert(
  (select array_agg(v) from public.my_rep_group_vendor_ids() v) = array['RRT ONE'],
  'a principal belongs to their own agency');

select pg_temp.become('inside');
select pg_temp.assert(
  not exists (select 1 from public.my_rep_group_vendor_ids()),
  'inside sales belongs to no agency (their role lets them through instead)');

select pg_temp.become('gone');
select pg_temp.assert(
  not exists (select 1 from public.my_rep_group_vendor_ids()),
  'a deactivated rep belongs to no agency');

--------------------------------------------------------------------------
-- 2. Who reads which row
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(
  pg_temp.visible() = 'RRT account A1, RRT agency one, RRT everyone',
  'rep A sees everyone''s file, their agency''s, and their own account''s');

select pg_temp.become('rep_b');
select pg_temp.assert(
  pg_temp.visible() = 'RRT account B1, RRT agency two, RRT everyone',
  'rep B sees none of agency one''s or rep A''s account files');

select pg_temp.become('principal');
select pg_temp.assert(
  pg_temp.visible() = 'RRT account A1, RRT agency one, RRT everyone',
  'a principal sees their agency''s files and their agency book''s account files');

select pg_temp.become('inside');
select pg_temp.assert(
  (select count(*) from public.rep_resources where title like 'RRT %') = 5,
  'inside sales sees every file');

select pg_temp.become('admin');
select pg_temp.assert(
  (select count(*) from public.rep_resources where title like 'RRT %') = 5,
  'an admin sees every file');

select pg_temp.become('gone');
select pg_temp.assert(
  pg_temp.visible() = 'RRT everyone',
  'a deactivated rep keeps only what every signed-in user sees');

--------------------------------------------------------------------------
-- 3. Storage follows the rows: no signed URL for a file you can't see.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert(
  pg_temp.visible_objects() = 'price_list/a1.xlsx, price_list/one.xlsx, program/everyone.pdf',
  'rep A reads exactly the objects behind the rows they see');

select pg_temp.become('rep_b');
select pg_temp.assert(
  not exists (select 1 from storage.objects
              where bucket_id = 'rep-resources'
                and name in ('price_list/a1.xlsx', 'price_list/one.xlsx', 'other/orphan.pdf')),
  'rep B cannot read agency one''s, rep A''s account''s or an orphaned object');

select pg_temp.become('admin');
select pg_temp.assert(
  exists (select 1 from storage.objects
          where bucket_id = 'rep-resources' and name = 'other/orphan.pdf'),
  'an admin reads an object that has no row (to clean it up)');

--------------------------------------------------------------------------
-- 4. Only admins write — the table and the bucket.
--------------------------------------------------------------------------
select pg_temp.become('rep_a');
select pg_temp.assert_fails(
  $q$ insert into public.rep_resources (title, storage_path, file_name)
      values ('RRT rogue', 'other/rogue.pdf', 'rogue.pdf') $q$,
  'a rep cannot publish a resource');

select pg_temp.assert_fails(
  $q$ insert into storage.objects (bucket_id, name)
      values ('rep-resources', 'other/rogue.pdf') $q$,
  'a rep cannot upload into the rep-resources bucket');

update public.rep_resources set title = 'RRT hijacked' where title = 'RRT everyone';
select pg_temp.assert(
  (select count(*) from public.rep_resources where title = 'RRT hijacked') = 0,
  'a rep''s update of a resource hits zero rows');

delete from public.rep_resources where title = 'RRT everyone';
select pg_temp.assert(
  (select count(*) from public.rep_resources where title = 'RRT everyone') = 1,
  'a rep''s delete of a resource hits zero rows');

select pg_temp.become('inside');
select pg_temp.assert_fails(
  $q$ insert into public.rep_resources (title, storage_path, file_name)
      values ('RRT inside', 'other/inside.pdf', 'inside.pdf') $q$,
  'inside sales cannot publish a resource');

select pg_temp.become('admin');
insert into public.rep_resources (title, category, customer_key, storage_path, file_name)
values ('RRT admin authored', 'price_list', 'RRT-B1', 'price_list/admin.xlsx', 'admin.xlsx');
insert into storage.objects (bucket_id, name) values ('rep-resources', 'price_list/admin.xlsx');
select pg_temp.assert(
  (select count(*) from public.rep_resources where title = 'RRT admin authored') = 1,
  'an admin publishes a resource and uploads its object');

select pg_temp.become('rep_b');
select pg_temp.assert(
  exists (select 1 from storage.objects
          where bucket_id = 'rep-resources' and name = 'price_list/admin.xlsx'),
  'the new account file reaches the rep whose book holds the account');

select pg_temp.become('rep_a');
select pg_temp.assert(
  not exists (select 1 from public.rep_resources where title = 'RRT admin authored'),
  'and nobody else');

--------------------------------------------------------------------------
-- 5. Constraints hold whoever writes.
--------------------------------------------------------------------------
select pg_temp.become('admin');

select pg_temp.assert_fails(
  $q$ insert into public.rep_resources
        (title, rep_group_vendor_id, customer_key, storage_path, file_name)
      values ('RRT both', 'RRT ONE', 'RRT-A1', 'other/both.pdf', 'both.pdf') $q$,
  'a file cannot be scoped to an agency AND an account');

select pg_temp.assert_fails(
  $q$ insert into public.rep_resources
        (title, rep_group_vendor_id, storage_path, file_name)
      values ('RRT padded', ' RRT ONE ', 'other/padded.pdf', 'padded.pdf') $q$,
  'a padded agency id (which would match no rep) is rejected');

select pg_temp.assert_fails(
  $q$ insert into public.rep_resources (title, category, storage_path, file_name)
      values ('RRT odd', 'secret', 'other/odd.pdf', 'odd.pdf') $q$,
  'an unknown category is rejected');

select pg_temp.assert_fails(
  $q$ insert into public.rep_resources (title, storage_path, file_name)
      values ('   ', 'other/blank.pdf', 'blank.pdf') $q$,
  'a blank title is rejected');

select pg_temp.assert_fails(
  $q$ insert into public.rep_resources (title, storage_path, file_name)
      values ('RRT dup', 'program/everyone.pdf', 'dup.pdf') $q$,
  'two rows cannot point at one object');

reset role;

do $$ begin raise notice 'ALL REP RESOURCE TESTS PASSED'; end $$;

rollback;
