/*============================================================================
  _local_harness.sql — stand up a bare Postgres so the migrations and the
  test files in this directory can run WITHOUT a Supabase project.

  Not part of the product schema. Nothing here is deployed anywhere; it only
  recreates the pieces of the Supabase platform that the migrations assume
  already exist. Leading underscore so it does not read as a test.

      # one-time, from the repo root
      initdb -D /var/tmp/pgdata -U postgres --auth=trust
      pg_ctl -D /var/tmp/pgdata -o '-p 5433 -k /var/tmp' -l /var/tmp/pgdata/log start

      PSQL="psql -h /var/tmp -p 5433 -U postgres"
      $PSQL -f supabase/tests/_local_harness.sql
      for f in $(ls supabase/migrations/); do
        $PSQL -v ON_ERROR_STOP=1 -q -f "supabase/migrations/$f" || echo "FAIL $f"
      done
      $PSQL -f supabase/tests/_local_harness_grants.sql
      $PSQL -f supabase/tests/035_order_lookup.sql

  NOTE for anyone editing this header: Postgres block comments NEST, so a
  literal slash-star sequence inside one opens a second comment that the
  closing star-slash then only half closes. A shell glob written as
  migrations/<star>.sql is exactly that sequence. Keep globs out of comments.

  Why this is worth having: 035's lookup_orders() is the first CROSS-ACCOUNT
  rep-facing read in the app, and its RLS is the only thing standing between
  a rep and another rep's order book. That deserves to be executable on a
  laptop, not just reasoned about in review.

  It also catches things review does not. Writing 035 the obvious way —
  appending columns to the inner subquery of v_account_recent_order_headers —
  produces "cannot change name of view column rn to customer_po_number",
  because 018's outer `select h.*, row_number() … as rn` puts rn last. That
  is invisible on the page and instant here.
============================================================================*/

--------------------------------------------------------------------------
-- Roles Supabase provides.
--------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role;
  end if;
  /* On Supabase service_role carries BYPASSRLS — it is how the ETL and the
     nightly jobs write past every policy in 007/010. It is a role ATTRIBUTE,
     not a grant, so `grant … to service_role` in _local_harness_grants.sql
     cannot stand in for it: without this, anything asserting job-path
     behaviour fails on an RLS violation that would never happen in
     production. Needs superuser, which the setup in this file's header has. */
  alter role service_role bypassrls;
end $$;

--------------------------------------------------------------------------
-- auth schema: just enough for handle_new_user() and auth.uid().
--------------------------------------------------------------------------
create schema if not exists auth;

create table if not exists auth.users (
    instance_id        uuid,
    id                 uuid primary key,
    aud                text,
    role               text,
    email              text,
    encrypted_password text,
    email_confirmed_at timestamptz,
    created_at         timestamptz,
    updated_at         timestamptz,
    raw_app_meta_data  jsonb,
    raw_user_meta_data jsonb,
    is_super_admin     boolean
);

/* The real auth.uid() reads the request's JWT claims, and the test files
   disagree about how they set them: 010_access_rules.sql sets the whole
   `request.jwt.claims` JSON blob (what PostgREST actually sends), while
   others set `request.jwt.claim.sub` directly. Reading only the latter made
   auth.uid() null throughout 010 on this harness, which does not error — it
   silently resolves an empty book and fails at the first assertion that
   expects rows. Accept both. */
create or replace function auth.uid() returns uuid
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::json ->> 'sub'
  )::uuid
$$;

--------------------------------------------------------------------------
-- storage schema: 009 creates a bucket and policies over storage.objects.
--------------------------------------------------------------------------
create schema if not exists storage;

create table if not exists storage.buckets (
    id                 text primary key,
    name               text,
    public             boolean,
    file_size_limit    bigint,
    allowed_mime_types text[]
);

create table if not exists storage.objects (
    id         uuid primary key default gen_random_uuid(),
    bucket_id  text,
    name       text,
    owner      uuid,
    created_at timestamptz default now(),
    updated_at timestamptz default now(),
    metadata   jsonb
);

/* Splits an object path into segments; the photo policies key on the first
   segment being the customer_key. */
create or replace function storage.foldername(name text) returns text[]
language sql immutable as $$
  select string_to_array(name, '/')
$$;

create extension if not exists pgcrypto;
