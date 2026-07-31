/*============================================================================
  004_app_crm.sql
  Purpose: Lightweight CRM writables — contacts, notes, photos, personal
           follow-up tasks. All keyed to erp customer_key (no FK across
           schemas by design: the erp side is truncate-and-loaded).
============================================================================*/

--------------------------------------------------------------------------
-- contacts — buyer/staff contact info kept current by reps
--------------------------------------------------------------------------
create table if not exists public.contacts (
    id            bigint generated always as identity primary key,
    customer_key  text not null,
    name          text not null,
    title         text,
    phone         text,
    email         text,
    is_primary    boolean not null default false,
    notes         text,                  -- relationship notes (interests, etc.)
    created_by    uuid not null default auth.uid() references public.profiles (user_id),
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);
alter table public.contacts enable row level security;
create index if not exists idx_contacts_customer on public.contacts (customer_key);

--------------------------------------------------------------------------
-- notes — free-text chronological account notes
--------------------------------------------------------------------------
create table if not exists public.notes (
    id            bigint generated always as identity primary key,
    customer_key  text not null,
    body          text not null,
    created_by    uuid not null default auth.uid() references public.profiles (user_id),
    created_at    timestamptz not null default now()
);
alter table public.notes enable row level security;
create index if not exists idx_notes_customer on public.notes (customer_key, created_at desc);

--------------------------------------------------------------------------
-- photos — metadata rows; binaries live in Storage bucket `account-photos`
--------------------------------------------------------------------------
create table if not exists public.photos (
    id            bigint generated always as identity primary key,
    customer_key  text not null,
    visit_id      bigint,                -- set when taken during a visit (FK added in 005)
    storage_path  text not null,         -- path inside the account-photos bucket
    category      text check (category in ('storefront','counter','display','endcap','competition','other')),
    caption       text,
    created_by    uuid not null default auth.uid() references public.profiles (user_id),
    created_at    timestamptz not null default now()
);
alter table public.photos enable row level security;
create index if not exists idx_photos_customer on public.photos (customer_key, created_at desc);

--------------------------------------------------------------------------
-- tasks — personal follow-ups reps create for themselves (distinct from
-- system/admin recommendations, which reps cannot create)
--------------------------------------------------------------------------
create table if not exists public.tasks (
    id            bigint generated always as identity primary key,
    customer_key  text,
    user_id       uuid not null default auth.uid() references public.profiles (user_id),
    title         text not null,
    due_date      date,
    status        text not null default 'open' check (status in ('open','done','cancelled')),
    created_at    timestamptz not null default now(),
    completed_at  timestamptz
);
alter table public.tasks enable row level security;
create index if not exists idx_tasks_user on public.tasks (user_id, status, due_date);

-- updated_at maintenance
create or replace function public.touch_updated_at()
returns trigger language plpgsql
as $$ begin new.updated_at := now(); return new; end; $$;

drop trigger if exists trg_contacts_touch on public.contacts;
create trigger trg_contacts_touch before update on public.contacts
  for each row execute function public.touch_updated_at();
