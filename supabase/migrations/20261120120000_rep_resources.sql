/*============================================================================
  20261120120000_rep_resources.sql
  Purpose: Resources — the documents reps come to the portal to download.

  Reps asked for one place to get the files the office sends them by email
  today: price lists (the 2027 sheets, an account's own all-SKU list), the
  rewards program flyer, associate program documents. This is that place.

  1. public.rep_resources — one row per published file: a title, a short
     description, a category, who it is for, and where the object lives in
     the new private `rep-resources` Storage bucket. Any file type the bucket
     allows (PDF, Excel, Word, PowerPoint, CSV, images); the portal does not
     care what is inside.

  2. Who sees a row — exactly one of three audiences, set per file:
       - everyone          rep_group_vendor_id and customer_key both null
       - one agency        rep_group_vendor_id = an erp.dim_sales_rep.vendor_id:
                           the agency's principal and every rep billing
                           through it (my_rep_group_vendor_ids() below)
       - one account       customer_key = an erp.dim_customer.customer_key:
                           whoever has that account in their book, by the
                           same my_customer_keys() every other read uses (own
                           book, agency book, explicit grants, minus revokes)
     Admins and inside sales see every row. While an admin views as a rep,
     is_admin() answers for the rep, so the page shows what the rep sees.

  3. Storage: the bucket's read policy is the table's read policy — an
     object is readable when its row is (set-based, like order-documents in
     20261113090000), so a signed URL can only be minted for a file the
     caller may see. Writes are admin-only, in the table and in the bucket.

  4. The view-as and inside-sales read-only triggers, attached to the new
     table (the sweeps in 20260901190200 / 20261113090000 only cover tables
     that existed when they ran).

  The approved per-customer-type sheets (price_list_files, 20260817000100)
  are untouched: they keep their Intel → Price Lists page and the order
  writer keeps reading the structured price_lists. This table is for every
  other document.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The table
--------------------------------------------------------------------------
create table if not exists public.rep_resources (
    id                   bigint generated always as identity primary key,
    title                text not null,
    description          text,
    category             text not null default 'other',
    -- Audience. Both null = every signed-in user.
    rep_group_vendor_id  text,                 -- erp.dim_sales_rep.vendor_id
    customer_key         text,                 -- erp.dim_customer.customer_key
    storage_path         text not null unique, -- '<category>/<uuid>.<ext>' in rep-resources
    file_name            text not null,        -- original name, for the download attribute
    content_type         text,
    file_size            bigint check (file_size is null or file_size >= 0),
    uploaded_by          uuid references public.profiles (user_id),
    uploaded_at          timestamptz not null default now(),
    updated_at           timestamptz not null default now(),
    constraint rep_resources_title_present
      check (length(btrim(title)) between 1 and 200),
    constraint rep_resources_category_known
      check (category in ('price_list', 'program', 'marketing', 'training', 'other')),
    constraint rep_resources_one_audience
      check (rep_group_vendor_id is null or customer_key is null),
    -- A padded or empty agency id would match no rep and hide the file from
    -- everyone it was meant for, silently.
    constraint rep_resources_vendor_clean
      check (rep_group_vendor_id is null
             or (rep_group_vendor_id = btrim(rep_group_vendor_id) and rep_group_vendor_id <> '')),
    constraint rep_resources_customer_clean
      check (customer_key is null or customer_key <> '')
);
alter table public.rep_resources enable row level security;

create index if not exists idx_rep_resources_vendor
  on public.rep_resources (rep_group_vendor_id) where rep_group_vendor_id is not null;
create index if not exists idx_rep_resources_customer
  on public.rep_resources (customer_key) where customer_key is not null;

drop trigger if exists trg_rep_resources_touch on public.rep_resources;
create trigger trg_rep_resources_touch before update on public.rep_resources
  for each row execute function public.touch_updated_at();

comment on table public.rep_resources is
  'Documents published to reps (price lists, program flyers, training). One '
  'audience per row: everyone, one agency (rep_group_vendor_id) or one '
  'account (customer_key). Files live in the private rep-resources bucket. '
  '20261120120000.';

--------------------------------------------------------------------------
-- 2. my_rep_group_vendor_ids() — the agencies the effective user belongs to
--
-- A principal: their profile's rep_group_vendor_id. A rep: the vendor their
-- own ERP rep row bills through. Both, when a principal also carries a rep
-- code. Nothing for inside sales or an admin (the policy lets them through
-- on their role). security definer for the same reason my_visible_rep_keys()
-- is: erp.dim_sales_rep is not the rep's to read row by row.
--------------------------------------------------------------------------
create or replace function public.my_rep_group_vendor_ids()
returns setof text
language sql stable security definer set search_path = public, erp
as $$
  with me as (
    select p.sales_rep_key, btrim(p.rep_group_vendor_id) as rep_group_vendor_id
    from public.profiles p
    where p.user_id = public.effective_user_id()
      and p.active
  )
  select me.rep_group_vendor_id
  from me
  where me.rep_group_vendor_id is not null
    and me.rep_group_vendor_id <> ''

  union

  select btrim(sr.vendor_id)
  from me
  join erp.dim_sales_rep sr on sr.sales_rep_key = me.sales_rep_key
  where me.sales_rep_key is not null
    and sr.vendor_id is not null
    and btrim(sr.vendor_id) <> '';
$$;

revoke execute on function public.my_rep_group_vendor_ids() from public, anon;
grant execute on function public.my_rep_group_vendor_ids() to authenticated;

comment on function public.my_rep_group_vendor_ids() is
  'Agencies (erp vendor ids) the effective user belongs to: a principal''s '
  'rep_group_vendor_id and the vendor of their own rep row. Decides which '
  'agency-scoped rep_resources they see. 20261120120000.';

--------------------------------------------------------------------------
-- 3. RLS. InitPlan-wrapped role checks and set-based membership (010), so a
--    listing costs one evaluation of each helper, not one per row.
--------------------------------------------------------------------------
drop policy if exists "read rep resources" on public.rep_resources;
create policy "read rep resources" on public.rep_resources
  for select to authenticated
  using (
    (select public.is_admin())
    or (select public.is_order_entry())
    or (rep_group_vendor_id is null and customer_key is null)
    or rep_group_vendor_id in (select public.my_rep_group_vendor_ids())
    or customer_key in (select public.my_customer_keys())
  );

drop policy if exists "admin manages rep resources" on public.rep_resources;
create policy "admin manages rep resources" on public.rep_resources
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

revoke all on public.rep_resources from anon, public;
grant select, insert, update, delete on public.rep_resources to authenticated;

--------------------------------------------------------------------------
-- 4. View-as and inside sales are read-only here, like every other table.
--------------------------------------------------------------------------
drop trigger if exists trg_rep_resources_no_write_while_viewing_as on public.rep_resources;
create trigger trg_rep_resources_no_write_while_viewing_as
  before insert or update or delete on public.rep_resources
  for each row execute function public.block_writes_while_impersonating();

drop trigger if exists trg_rep_resources_read_only_role on public.rep_resources;
create trigger trg_rep_resources_read_only_role
  before insert or update or delete on public.rep_resources
  for each row execute function public.block_writes_for_read_only_role();

--------------------------------------------------------------------------
-- 5. Storage: a private bucket. Signed URLs only (getPublicUrl 400s).
--------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rep-resources', 'rep-resources', false,
        52428800,                              -- 50 MB per file (catalogs, decks)
        array['application/pdf',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              'application/vnd.ms-excel',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'application/msword',
              'application/vnd.openxmlformats-officedocument.presentationml.presentation',
              'application/vnd.ms-powerpoint',
              'text/csv', 'text/plain',
              'image/png', 'image/jpeg', 'image/webp',
              'application/zip'])
on conflict (id) do nothing;

-- An object is readable when its row is: the subquery runs under the
-- caller's RLS on rep_resources, once per statement (hashed subplan), never
-- once per object. An admin also reads objects with no row yet (the moment
-- between upload and insert) or no row any more (an orphan to sweep).
drop policy if exists "read rep resources storage" on storage.objects;
create policy "read rep resources storage" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'rep-resources'
    and ((select public.is_admin())
         or name in (select r.storage_path from public.rep_resources r))
  );

drop policy if exists "admin uploads rep resources" on storage.objects;
create policy "admin uploads rep resources" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'rep-resources' and (select public.is_admin()));

drop policy if exists "admin updates rep resources" on storage.objects;
create policy "admin updates rep resources" on storage.objects
  for update to authenticated
  using (bucket_id = 'rep-resources' and (select public.is_admin()))
  with check (bucket_id = 'rep-resources' and (select public.is_admin()));

drop policy if exists "admin deletes rep resources" on storage.objects;
create policy "admin deletes rep resources" on storage.objects
  for delete to authenticated
  using (bucket_id = 'rep-resources' and (select public.is_admin()));
