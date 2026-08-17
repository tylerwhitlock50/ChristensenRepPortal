/*============================================================================
  20260817_price_lists.sql — RLS assertions for the price-list tables,
  effective_price_lists(), and the price-lists Storage bucket
  (migration 20260817000100).

  Same harness rules as 010_access_rules.sql / 035_order_lookup.sql: runs in
  a transaction and ROLLS BACK, creates throwaway auth users, run against
  dev — never prod.

      psql "$DATABASE_URL" -f supabase/tests/20260817_price_lists.sql

  A clean run prints "ALL PRICE LIST TESTS PASSED"; any error is a failure.

  What is at stake: price lists are readable by every signed-in user by
  DESIGN (they are the same information as the downloadable sheets), so the
  risk here is not a read leak — it is a WRITE hole. A rep who can insert a
  price list row or a bucket object can publish prices. Hence the write
  probes are the point of this file.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------
create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'aaaaaaaa-1111-4111-8111-111111111111'),
  ('admin', 'bbbbbbbb-2222-4222-8222-222222222222');
grant select on t_user to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@pricelist.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles set role = 'admin'
  where user_id = (select id from t_user where label = 'admin');

-- Lists inserted as postgres (fixture setup, not a policy probe): one live
-- general, one live typed special with a promo, one live untyped special,
-- one EXPIRED general, one INACTIVE special. Names carry the expectation.
create temporary table t_pl (label text primary key, id bigint) on commit drop;
grant select on t_pl to authenticated;

with ins as (
  insert into public.price_lists
    (name, customer_type, is_special, effective_from, effective_to,
     promo_buy_qty, promo_get_qty, active)
  values
    ('PLT general dealer',   'PLT-DEALER', false, current_date - 30, null,             null, null, true),
    ('PLT special dealer',   'PLT-DEALER', true,  current_date - 7,  current_date + 7, 10,   2,    true),
    ('PLT special anytype',  null,         true,  current_date - 7,  current_date + 7, null, null, true),
    ('PLT expired general',  'PLT-DEALER', false, current_date - 90, current_date - 1, null, null, true),
    ('PLT inactive special', 'PLT-DEALER', true,  current_date - 7,  null,             null, null, false)
  returning id, name
)
insert into t_pl select name, id from ins;

insert into public.price_list_items (price_list_id, part_id, description, unit_price)
values ((select id from t_pl where label = 'PLT general dealer'), 'PLT-PART-1', 'Test part', 100.00);

insert into public.price_list_files (customer_type, title, storage_path, file_name)
values ('PLT-DEALER', 'Dealer price list', 'plt-dealer/test.xlsx', 'dealer.xlsx');

insert into storage.buckets (id, name, public)
values ('price-lists', 'price-lists', false)
on conflict (id) do nothing;

-- Local harness only: its stubbed storage.objects has neither RLS enabled
-- nor grants (the real platform has both). On dev these ALTERs fail with
-- insufficient_privilege — storage.objects belongs to the platform — and
-- that is fine: there the real config is already in place.
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

--------------------------------------------------------------------------
-- 1. Reps read everything; that is the design.
--------------------------------------------------------------------------
select pg_temp.become('rep');

select pg_temp.assert(
  (select count(*) from public.price_lists where name like 'PLT %') = 5,
  'rep reads every price list row');

select pg_temp.assert(
  (select count(*) from public.price_list_items where part_id = 'PLT-PART-1') = 1,
  'rep reads price list items');

select pg_temp.assert(
  (select count(*) from public.price_list_files where customer_type = 'PLT-DEALER') = 1,
  'rep reads price list file metadata');

--------------------------------------------------------------------------
-- 2. Reps write nothing.
--------------------------------------------------------------------------
select pg_temp.assert_fails(
  $q$ insert into public.price_lists (name, customer_type, is_special, effective_from)
      values ('PLT rogue list', 'PLT-DEALER', false, current_date) $q$,
  'rep cannot insert a price list');

select pg_temp.assert_fails(
  format($q$ insert into public.price_list_items (price_list_id, part_id, unit_price)
             values (%s, 'PLT-ROGUE', 1.00) $q$,
         (select id from t_pl where label = 'PLT general dealer')),
  'rep cannot insert a price list item');

select pg_temp.assert_fails(
  $q$ insert into public.price_list_files (customer_type, title, storage_path, file_name)
      values ('PLT-DEALER', 'rogue', 'plt-dealer/rogue.xlsx', 'rogue.xlsx') $q$,
  'rep cannot insert price list file metadata');

-- Updates filtered out by RLS affect zero rows rather than raising.
update public.price_lists set name = 'PLT hijacked'
  where name = 'PLT general dealer';
select pg_temp.assert(
  (select count(*) from public.price_lists where name = 'PLT hijacked') = 0,
  'rep update of a price list hits zero rows');

--------------------------------------------------------------------------
-- 3. effective_price_lists() — the eligibility rule.
--------------------------------------------------------------------------
select pg_temp.assert(
  (select count(*) from public.effective_price_lists('PLT-DEALER')) = 3,
  'DEALER type resolves to general + typed special + untyped special');

select pg_temp.assert(
  not exists (select 1 from public.effective_price_lists('PLT-DEALER')
              where name in ('PLT expired general', 'PLT inactive special')),
  'expired and inactive lists are never effective');

select pg_temp.assert(
  (select count(*) from public.effective_price_lists('PLT-OTHERTYPE')) = 1
  and (select name from public.effective_price_lists('PLT-OTHERTYPE'))
      = 'PLT special anytype',
  'an unrelated type resolves to only the untyped special');

select pg_temp.assert(
  (select count(*) from public.effective_price_lists(null)) = 1
  and (select name from public.effective_price_lists(null)) = 'PLT special anytype',
  'a customer with no type gets no general list (fail closed), only untyped specials');

select pg_temp.assert(
  (select count(*) from public.effective_price_lists('PLT-DEALER', current_date - 15)) = 2
  and exists (select 1 from public.effective_price_lists('PLT-DEALER', current_date - 15)
              where name = 'PLT expired general'),
  'as-of date honours effective ranges (the now-expired list was live then)');

--------------------------------------------------------------------------
-- 4. Storage: everyone reads the bucket, only admins write it.
--------------------------------------------------------------------------
select pg_temp.assert_fails(
  $q$ insert into storage.objects (bucket_id, name)
      values ('price-lists', 'plt-dealer/rogue.xlsx') $q$,
  'rep cannot upload into the price-lists bucket');

select pg_temp.become('admin');

insert into storage.objects (bucket_id, name) values ('price-lists', 'plt-dealer/test.xlsx');
select pg_temp.assert(true, 'admin uploads into the price-lists bucket');

select pg_temp.become('rep');
select pg_temp.assert(
  (select count(*) from storage.objects
    where bucket_id = 'price-lists' and name = 'plt-dealer/test.xlsx') = 1,
  'rep reads (and can therefore sign URLs for) price list objects');

--------------------------------------------------------------------------
-- 5. Admin writes work — proving the rep rejections above are RLS, not a
--    broken table.
--------------------------------------------------------------------------
select pg_temp.become('admin');

insert into public.price_lists (name, customer_type, is_special, effective_from)
values ('PLT admin authored', 'PLT-DEALER', false, current_date);
select pg_temp.assert(
  (select count(*) from public.price_lists where name = 'PLT admin authored') = 1,
  'admin inserts a price list');

--------------------------------------------------------------------------
-- 6. The table constraints hold regardless of role.
--------------------------------------------------------------------------
select pg_temp.assert_fails(
  $q$ insert into public.price_lists (name, customer_type, is_special, effective_from)
      values ('PLT bad general', null, false, current_date) $q$,
  'a general list without a customer type is rejected');

select pg_temp.assert_fails(
  $q$ insert into public.price_lists
        (name, customer_type, is_special, effective_from, promo_buy_qty, promo_get_qty)
      values ('PLT bad promo', 'PLT-DEALER', false, current_date, 5, 1) $q$,
  'a promo on a non-special list is rejected');

select pg_temp.assert_fails(
  $q$ insert into public.price_lists
        (name, customer_type, is_special, effective_from, promo_buy_qty)
      values ('PLT half promo', 'PLT-DEALER', true, current_date, 5) $q$,
  'a buy qty without a get qty is rejected');

reset role;

do $$ begin raise notice 'ALL PRICE LIST TESTS PASSED'; end $$;

rollback;
