/*============================================================================
  024_intel_views.sql — RLS assertions for the data-first restructure
  (migrations 024–028): territory/intel views, the global-aggregates
  function, feature flags, and the AI Actions tables.

  Same harness rules as 010_access_rules.sql: runs in a transaction and
  ROLLS BACK, creates throwaway auth users, run against dev — never prod.

      psql "$DATABASE_URL" -f supabase/tests/024_intel_views.sql

  A clean run prints "ALL INTEL TESTS PASSED"; any error is a failure.
============================================================================*/

begin;

\set ON_ERROR_STOP on

--------------------------------------------------------------------------
-- Fixtures — throwaway ERP rows seeded (and rolled back) by the test, same
-- as 010/016: a two-account rep with current-year invoice lines, plus a
-- foreign account with revenue of its own so the isolation probes and the
-- "global exceeds the book" check both have something to bite on. Expected
-- numbers are recomputed from the data below, so the file runs on the bare
-- _local_harness.sql cluster and on dev alike.
--------------------------------------------------------------------------
create temporary table t_fix (name text primary key, val text) on commit drop;
insert into t_fix (name, val) values
  ('rep_key', 'INT REPA');

insert into erp.dim_customer
  (customer_key, customer_id, customer_name, assigned_sales_rep_id,
   customer_type, active_flag)
values
  ('INT-CUST-A1', 'INT-CUST-A1', 'Intel Dealer A1', 'INT REPA', 'INT-DEALER', 'Y'),
  ('INT-CUST-A2', 'INT-CUST-A2', 'Intel Dealer A2', 'INT REPA', 'INT-DEALER', 'Y'),
  ('INT-CUST-F1', 'INT-CUST-F1', 'Intel Dealer F1', 'INT REPF', 'INT-DEALER', 'Y');

insert into erp.dim_part (part_key, part_id, part_description)
values ('INTPK-1', 'INT-PART-1', 'Intel part one'),
       ('INTPK-2', 'INT-PART-2', 'Intel part two');

-- Current-year revenue: 1650 / 19 units on the rep's book, 1000 / 20 units
-- on the foreign account.
insert into erp.fact_invoice_line
  (invoice_entity_id, invoice_id, invoice_line_no, customer_key, part_key,
   invoice_qty, revenue, is_memo, invoice_date_key)
values
  ('INT-E', 'INT-INV-1', 1, 'INT-CUST-A1', 'INTPK-1', 10, 1000.00, false,
   to_char(current_date, 'YYYYMMDD')::int),
  ('INT-E', 'INT-INV-1', 2, 'INT-CUST-A1', 'INTPK-2',  5,  250.00, false,
   to_char(current_date, 'YYYYMMDD')::int),
  ('INT-E', 'INT-INV-2', 1, 'INT-CUST-A2', 'INTPK-1',  4,  400.00, false,
   to_char(current_date, 'YYYYMMDD')::int),
  ('INT-E', 'INT-INV-3', 1, 'INT-CUST-F1', 'INTPK-2', 20, 1000.00, false,
   to_char(current_date, 'YYYYMMDD')::int);

-- The territory views read the 030 rollup tables, not the facts — rebuild
-- them so tonight's "ETL already ran" precondition holds for the seed rows.
select * from public.refresh_territory_rollups();

create temporary table t_user (label text primary key, id uuid) on commit drop;
insert into t_user (label, id) values
  ('rep',   'aaaaaaaa-1111-4111-8111-111111111111'),
  ('other', 'bbbbbbbb-2222-4222-8222-222222222222'),
  ('admin', 'cccccccc-3333-4333-8333-333333333333');

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at,
  raw_app_meta_data, raw_user_meta_data, is_super_admin
)
select '00000000-0000-0000-0000-000000000000', u.id,
       'authenticated', 'authenticated', u.label || '@intel.test', '',
       now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false
from t_user u;

update public.profiles p set sales_rep_key = (select val from t_fix where name='rep_key')
  where p.user_id = (select id from t_user where label='rep');
-- 'other' keeps null keys: an authenticated user with an EMPTY book.
update public.profiles p set role = 'admin'
  where p.user_id = (select id from t_user where label='admin');

-- An account outside the rep's book, for cross-tenant probes.
create temporary table t_keys (label text primary key, customer_key text) on commit drop;
insert into t_keys
select 'foreign', customer_key from erp.dim_customer
 where assigned_sales_rep_id is not null
   and assigned_sales_rep_id <> (select val from t_fix where name='rep_key')
 order by customer_key limit 1;

-- Superuser recomputation of the rep's territory SKU revenue and units
-- (current year), to compare against what the invoker view / definer
-- function hand the rep.
create temporary table t_expect (name text primary key, v numeric) on commit drop;
insert into t_expect
select 'rep_sku_revenue_ytd', coalesce(sum(f.revenue), 0)
from erp.fact_invoice_line f
join erp.dim_customer c on c.customer_key = f.customer_key
where c.assigned_sales_rep_id = (select val from t_fix where name='rep_key')
  and c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y'
  and f.is_memo is not true
  and f.invoice_date >= date_trunc('year', current_date)::date;

insert into t_expect
select 'rep_sku_qty_ytd', coalesce(sum(f.invoice_qty), 0)
from erp.fact_invoice_line f
join erp.dim_customer c on c.customer_key = f.customer_key
where c.assigned_sales_rep_id = (select val from t_fix where name='rep_key')
  and c.active_flag = 'Y'
  and coalesce(c.internal_customer_flag, 'N') <> 'Y'
  and f.is_memo is not true
  and f.invoice_date >= date_trunc('year', current_date)::date;

--------------------------------------------------------------------------
-- Harness
--------------------------------------------------------------------------
create or replace function pg_temp.as_user(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text,
                     true);
  execute 'set local role authenticated';
end;
$$;

create or replace function pg_temp.as_super() returns void
language plpgsql as $$
begin
  execute 'reset role';
end;
$$;

--------------------------------------------------------------------------
-- The assertions
--------------------------------------------------------------------------
do $$
declare
  u_rep     uuid := (select id from t_user where label='rep');
  u_other   uuid := (select id from t_user where label='other');
  u_admin   uuid := (select id from t_user where label='admin');
  k_foreign text := (select customer_key from t_keys where label='foreign');
  n int;
  v numeric;
  v_expected numeric := (select e.v from t_expect e where e.name='rep_sku_revenue_ytd');
  v_expected_qty numeric := (select e.v from t_expect e where e.name='rep_sku_qty_ytd');
begin
  ----------------------------------------------------------------
  -- T1–T3: cross-tenant isolation on every customer-grained view.
  ----------------------------------------------------------------
  perform pg_temp.as_user(u_rep);

  select count(*) into n from public.v_territory_account_yoy
   where customer_key = k_foreign;
  if n <> 0 then
    raise exception 'T1 FAILED: v_territory_account_yoy leaked a foreign account';
  end if;
  raise notice 'T1 ok (territory view holds no foreign accounts)';

  select count(*) into n from public.v_sku_sales_by_account
   where customer_key = k_foreign;
  if n <> 0 then
    raise exception 'T2 FAILED: v_sku_sales_by_account leaked a foreign account';
  end if;
  raise notice 'T2 ok';

  select count(*) into n from public.v_backlog_by_sku
   where customer_key = k_foreign;
  if n <> 0 then
    raise exception 'T3 FAILED: v_backlog_by_sku leaked a foreign account';
  end if;
  raise notice 'T3 ok';

  ----------------------------------------------------------------
  -- T4: every account the territory view returns is in the rep's book.
  ----------------------------------------------------------------
  if exists (
    select 1 from public.v_territory_account_yoy t
    where t.customer_key not in (select public.my_customer_keys())
    limit 1
  ) then
    raise exception 'T4 FAILED: v_territory_account_yoy returned an account outside my_customer_keys()';
  end if;
  raise notice 'T4 ok (territory view ⊆ book)';

  ----------------------------------------------------------------
  -- T5: the rep's territory SKU totals equal a superuser recomputation
  -- over ONLY their book (proves the invoker rollup neither leaks nor
  -- drops rows).
  ----------------------------------------------------------------
  select coalesce(sum(revenue), 0) into v
  from public.v_territory_sku_sales
  where sales_year = extract(year from current_date)::int;

  if abs(coalesce(v, 0) - v_expected) > 1 then  -- rounding tolerance
    raise exception 'T5 FAILED: rep territory SKU revenue % <> recomputed %', v, v_expected;
  end if;
  raise notice 'T5 ok (territory SKU rollup matches the book: %)', v;

  ----------------------------------------------------------------
  -- T6: global aggregates work for a rep and expose no account identity.
  ----------------------------------------------------------------
  select count(*) into n from public.report_global_product_sales(12, 50);
  if n = 0 then
    raise exception 'T6 FAILED: report_global_product_sales returned nothing for a rep';
  end if;
  select coalesce(sum(qty), 0) into v from public.report_global_product_sales(12, 2000);
  if v < v_expected_qty then
    raise exception 'T6 FAILED: global units (%) below the rep''s own book (%) — not global', v, v_expected_qty;
  end if;
  raise notice 'T6 ok (global rows for a rep; units % >= book %)', v, v_expected_qty;

  -- Structural: the function's output columns must never include customer
  -- identifiers, nor any dollar figure (033 stripped revenue — reps get
  -- units and mix only). This fails the moment someone adds either back.
  if exists (
    select 1 from information_schema.parameters
    where specific_schema = 'public'
      and specific_name like 'report_global_product_sales%'
      and parameter_mode = 'OUT'
      and parameter_name ~* 'customer|revenue|amount|price|dollar'
  ) then
    raise exception 'T7 FAILED: report_global_product_sales exposes a customer or dollar column';
  end if;
  raise notice 'T7 ok (no customer or dollar columns in the global report)';

  ----------------------------------------------------------------
  -- T8: an empty-book user gets EMPTY territory intel, not an error.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  perform pg_temp.as_user(u_other);
  select count(*) into n from public.v_territory_account_yoy;
  if n <> 0 then
    raise exception 'T8 FAILED: empty-book user sees % territory rows', n;
  end if;
  raise notice 'T8 ok (empty book, empty territory)';

  ----------------------------------------------------------------
  -- T9–T10: app_settings — anyone reads, only admins write.
  ----------------------------------------------------------------
  select count(*) into n from public.app_settings;
  if n < 4 then
    raise exception 'T9 FAILED: expected the 4 seeded flags, saw %', n;
  end if;
  raise notice 'T9 ok (rep reads % flags)', n;

  update public.app_settings set enabled = true
   where setting_key = 'feature.tasks';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'T10 FAILED: a rep updated app_settings (% rows)', n;
  end if;
  raise notice 'T10 ok (rep update touches nothing)';

  perform pg_temp.as_super();
  perform pg_temp.as_user(u_admin);
  update public.app_settings set enabled = true
   where setting_key = 'feature.tasks';
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'T11 FAILED: admin update touched % rows', n;
  end if;
  raise notice 'T11 ok (admin flips a flag)';

  ----------------------------------------------------------------
  -- T12–T13: ai_briefs — own rows only.
  ----------------------------------------------------------------
  perform pg_temp.as_super();
  perform pg_temp.as_user(u_rep);
  insert into public.ai_briefs (user_id, action, content)
  values (u_rep, 'territory.brief', 'test brief');
  raise notice 'T12 ok (rep writes own brief)';

  begin
    insert into public.ai_briefs (user_id, action, content)
    values (u_other, 'territory.brief', 'forged brief');
    raise exception 'T13 FAILED: rep inserted a brief for another user';
  exception
    when insufficient_privilege or check_violation then
      raise notice 'T13 ok (cross-user brief insert rejected)';
  end;

  perform pg_temp.as_super();
  perform pg_temp.as_user(u_other);
  select count(*) into n from public.ai_briefs where user_id = u_rep;
  if n <> 0 then
    raise exception 'T14 FAILED: user sees another user''s briefs';
  end if;
  raise notice 'T14 ok (briefs are private)';

  ----------------------------------------------------------------
  -- T15: freshness + ATS list readable by any authenticated user.
  ----------------------------------------------------------------
  select count(*) into n from public.v_data_freshness;
  if n <> 1 then
    raise exception 'T15 FAILED: v_data_freshness returned % rows', n;
  end if;
  perform count(*) from public.v_ats_list;  -- empty until the feed lands; must not error
  raise notice 'T15 ok (freshness + ATS readable)';

  perform pg_temp.as_super();
  raise notice '--- ALL INTEL TESTS PASSED ---';
end;
$$;

rollback;
