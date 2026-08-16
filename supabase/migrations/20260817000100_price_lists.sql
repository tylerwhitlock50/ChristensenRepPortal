/*============================================================================
  20260817000100_price_lists.sql
  Purpose: Price lists — both halves of the feature.

  1. public.price_list_files — metadata for the APPROVED, downloadable Excel
     sheets (one per customer type). The files themselves live in the new
     private `price-lists` Storage bucket; this table is what the always-on
     Price Lists page renders. Reps download via signed URLs, admins upload.

  2. public.price_lists + public.price_list_items — the STRUCTURED pricing
     the order writer reads. Populated by admin CSV upload, not by the ETL:
     these are the *approved published* prices (what the Excel sheets say),
     deliberately app-owned so specials can exist before/without any ERP
     representation. Keyed by erp.dim_part.part_id (the human part number an
     admin's spreadsheet actually contains), NOT the part_key surrogate.

     A list is either:
       - general  (is_special=false): the standard pricing for ONE
         customer_type (erp.dim_customer.customer_type). Required type.
       - special  (is_special=true): a promo list, optionally scoped to one
         customer_type (null = offered to every type), optionally carrying a
         buy-X-get-Y config. The promo is ALWAYS settled as a prorated
         percent off the qualifying lines — never free goods:
             multiples = floor(total_qty / (buy+get))
             pct       = 100 * multiples * get / total_qty
         The SQL implementation lives in submit_order() (20260817000200);
         the TS twin in frontend/src/lib/orderPricing.ts is preview-only.

  Visibility: every signed-in user can read every list, item and file row —
  the same decision as the downloadable sheets, because they are the same
  information. Writes are admin-only everywhere.

  Overlapping effective ranges for one customer_type are ALLOWED: forbidding
  them needs an exclusion constraint that fights the legitimate "new list
  starts tomorrow" workflow. The admin UI warns; the rep picks among all
  effective lists (effective_price_lists() below is the single source of
  the "which lists apply" rule).
============================================================================*/

--------------------------------------------------------------------------
-- price_lists — one row per published list (general or special)
--------------------------------------------------------------------------
create table if not exists public.price_lists (
    id             bigint generated always as identity primary key,
    name           text not null,
    -- erp.dim_customer.customer_type. Null is legal ONLY on a special and
    -- means "offered to every customer type".
    customer_type  text,
    is_special     boolean not null default false,
    effective_from date not null,
    effective_to   date,                       -- null = open-ended
    promo_buy_qty  int check (promo_buy_qty > 0),
    promo_get_qty  int check (promo_get_qty > 0),
    active         boolean not null default true,
    notes          text,
    created_by     uuid references public.profiles (user_id),
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now(),
    constraint general_needs_type check (is_special or customer_type is not null),
    constraint promo_pair         check ((promo_buy_qty is null) = (promo_get_qty is null)),
    constraint promo_special_only check (promo_buy_qty is null or is_special),
    constraint sane_range         check (effective_to is null or effective_to >= effective_from)
);
alter table public.price_lists enable row level security;

create index if not exists idx_price_lists_type on public.price_lists (customer_type);
create index if not exists idx_price_lists_active_special
  on public.price_lists (is_special) where active;

drop trigger if exists trg_price_lists_touch on public.price_lists;
create trigger trg_price_lists_touch before update on public.price_lists
  for each row execute function public.touch_updated_at();

--------------------------------------------------------------------------
-- price_list_items — the SKUs and published unit prices on one list
--------------------------------------------------------------------------
create table if not exists public.price_list_items (
    id             bigint generated always as identity primary key,
    price_list_id  bigint not null references public.price_lists (id) on delete cascade,
    part_id        text not null,              -- erp.dim_part.part_id (human SKU)
    description    text,
    unit_price     numeric(12,2) not null check (unit_price >= 0),
    unique (price_list_id, part_id)
);
alter table public.price_list_items enable row level security;

create index if not exists idx_price_list_items_list
  on public.price_list_items (price_list_id);

--------------------------------------------------------------------------
-- price_list_files — metadata for the downloadable approved sheets
--------------------------------------------------------------------------
create table if not exists public.price_list_files (
    id            bigint generated always as identity primary key,
    customer_type text not null,
    title         text not null,
    storage_path  text not null unique,        -- '<slug>/<uuid>.<ext>' in price-lists bucket
    file_name     text not null,               -- original name, for the download attribute
    file_size     bigint,
    uploaded_by   uuid references public.profiles (user_id),
    uploaded_at   timestamptz not null default now()
);
alter table public.price_list_files enable row level security;

--------------------------------------------------------------------------
-- RLS: everyone signed-in reads, admins write. InitPlan-wrapped per 010.
--------------------------------------------------------------------------
create policy "read price lists" on public.price_lists
  for select to authenticated using (true);
create policy "admin manages price lists" on public.price_lists
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "read price list items" on public.price_list_items
  for select to authenticated using (true);
create policy "admin manages price list items" on public.price_list_items
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

create policy "read price list files" on public.price_list_files
  for select to authenticated using (true);
create policy "admin manages price list files" on public.price_list_files
  for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

revoke all on public.price_lists      from anon, public;
revoke all on public.price_list_items from anon, public;
revoke all on public.price_list_files from anon, public;
grant select, insert, update, delete on public.price_lists      to authenticated;
grant select, insert, update, delete on public.price_list_items to authenticated;
grant select, insert, update, delete on public.price_list_files to authenticated;

comment on table public.price_lists is
  'Admin-published price lists the order writer sells from. General lists '
  'carry one customer_type''s standard pricing; specials optionally carry a '
  'buy-X-get-Y promo settled as a prorated percent off (never free goods).';
comment on table public.price_list_items is
  'SKU + published unit price on one list. part_id is erp.dim_part.part_id.';
comment on table public.price_list_files is
  'Metadata for the approved downloadable Excel sheets in the price-lists '
  'bucket. One file per customer type, admin-uploaded, rep-downloaded.';

--------------------------------------------------------------------------
-- effective_price_lists() — THE rule for "which lists apply to this
-- customer type on this date". Used by the order-writer UI and re-checked
-- inside submit_order(), so the two can never drift.
--
-- A null p_customer_type (customer with no type in the ERP) matches only
-- specials that are themselves untyped — no general list ever resolves,
-- which is the fail-closed behaviour the writer UI surfaces as a blocking
-- notice.
--------------------------------------------------------------------------
create or replace function public.effective_price_lists(
  p_customer_type text,
  p_on            date default current_date
)
returns setof public.price_lists
language sql stable set search_path = public
as $$
  select pl.*
  from public.price_lists pl
  where pl.active
    and pl.effective_from <= p_on
    and (pl.effective_to is null or pl.effective_to >= p_on)
    and (
      (not pl.is_special and pl.customer_type = p_customer_type)
      or (pl.is_special
          and (pl.customer_type is null or pl.customer_type = p_customer_type))
    )
  order by pl.is_special, pl.effective_from desc, pl.id;
$$;

revoke execute on function public.effective_price_lists(text, date) from public, anon;
grant execute on function public.effective_price_lists(text, date) to authenticated;

comment on function public.effective_price_lists(text, date) is
  'Active price lists in effective range for a customer type: its general '
  'list(s) plus specials scoped to it or to every type. Single source of '
  'the eligibility rule for the writer UI and submit_order().';

--------------------------------------------------------------------------
-- Storage: private bucket for the approved sheets. Signed URLs only
-- (private bucket → getPublicUrl 400s, same as account-photos).
--------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('price-lists', 'price-lists', false,
        20971520,                              -- 20 MB per sheet
        array['application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              'application/vnd.ms-excel',
              'text/csv',
              'application/pdf'])
on conflict (id) do nothing;

drop policy if exists "read price list files storage" on storage.objects;
create policy "read price list files storage" on storage.objects
  for select to authenticated
  using (bucket_id = 'price-lists');

drop policy if exists "admin uploads price list files" on storage.objects;
create policy "admin uploads price list files" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'price-lists' and (select public.is_admin()));

drop policy if exists "admin updates price list files" on storage.objects;
create policy "admin updates price list files" on storage.objects
  for update to authenticated
  using (bucket_id = 'price-lists' and (select public.is_admin()))
  with check (bucket_id = 'price-lists' and (select public.is_admin()));

drop policy if exists "admin deletes price list files" on storage.objects;
create policy "admin deletes price list files" on storage.objects
  for delete to authenticated
  using (bucket_id = 'price-lists' and (select public.is_admin()));
