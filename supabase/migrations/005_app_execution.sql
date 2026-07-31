/*============================================================================
  005_app_execution.sql
  Purpose: The execution loop — recommendations (system/admin generated,
           outcome required to close), actions logged against them, and the
           GoSpotCheck-style structured visit survey. Plus rule_settings so
           thresholds are tunable without code changes.
============================================================================*/

--------------------------------------------------------------------------
-- rule_settings — one row per recommendation rule; params drive the
-- nightly generator (008). Editable by admin only.
--------------------------------------------------------------------------
create table if not exists public.rule_settings (
    rule_key     text primary key,
    description  text not null,
    enabled      boolean not null default true,
    params       jsonb not null default '{}'::jsonb,
    updated_at   timestamptz not null default now()
);
alter table public.rule_settings enable row level security;

insert into public.rule_settings (rule_key, description, params) values
  ('no_order_days',  'No order in N days (accounts with history going quiet)',
   '{"days": 120, "min_trailing_12m_revenue": 5000}'),
  ('yoy_decline',    'YTD revenue down more than X% vs same period last year',
   '{"decline_pct": 30, "min_prior_ytd_revenue": 10000}')
on conflict (rule_key) do nothing;

--------------------------------------------------------------------------
-- recommendations — the unit of directed work. Reps do NOT create these;
-- the nightly job (rule_key set) or the admin (source='admin') does.
-- Closing REQUIRES an outcome (enforced by check constraint).
--------------------------------------------------------------------------
create table if not exists public.recommendations (
    id            bigint generated always as identity primary key,
    customer_key  text not null,
    source        text not null default 'system' check (source in ('system','admin')),
    rule_key      text references public.rule_settings (rule_key),
    title         text not null,
    reason        text,                  -- plain-English why (shown to the rep)
    priority      text not null default 'normal' check (priority in ('high','normal','low')),
    due_date      date,
    status        text not null default 'open'
                  check (status in ('open','acted','closed','dismissed')),
    outcome       text
                  check (outcome in ('order_received','inventory_issue','competitor',
                                     'customer_shrinking','seasonal','false_positive',
                                     'could_not_contact')),
    outcome_note  text,
    created_by    uuid references public.profiles (user_id),  -- null for system
    created_at    timestamptz not null default now(),
    closed_by     uuid references public.profiles (user_id),
    closed_at     timestamptz,
    -- terminal states require an outcome; dismissed implies false_positive-ish
    constraint recommendations_outcome_on_close
      check (status not in ('closed','dismissed') or outcome is not null)
);
alter table public.recommendations enable row level security;
create index if not exists idx_recs_customer on public.recommendations (customer_key, status);
create index if not exists idx_recs_status on public.recommendations (status, priority, due_date);
-- Idempotency: at most ONE open system recommendation per (customer, rule)
create unique index if not exists uq_recs_open_rule
  on public.recommendations (customer_key, rule_key)
  where status = 'open' and source = 'system';

--------------------------------------------------------------------------
-- actions — what a rep actually did (call / visit / email), optionally
-- resolving a recommendation
--------------------------------------------------------------------------
create table if not exists public.actions (
    id                 bigint generated always as identity primary key,
    customer_key       text not null,
    recommendation_id  bigint references public.recommendations (id) on delete set null,
    user_id            uuid not null default auth.uid() references public.profiles (user_id),
    action_type        text not null check (action_type in ('call','visit','email','other')),
    action_date        date not null default current_date,
    note               text,
    created_at         timestamptz not null default now()
);
alter table public.actions enable row level security;
create index if not exists idx_actions_customer on public.actions (customer_key, action_date desc);
create index if not exists idx_actions_user on public.actions (user_id, action_date desc);
create index if not exists idx_actions_rec on public.actions (recommendation_id);

--------------------------------------------------------------------------
-- visits — structured GoSpotCheck-style survey, linked to an action
--------------------------------------------------------------------------
create table if not exists public.visits (
    id               bigint generated always as identity primary key,
    action_id        bigint references public.actions (id) on delete cascade,
    customer_key     text not null,
    user_id          uuid not null default auth.uid() references public.profiles (user_id),
    visit_type       text not null check (visit_type in ('in_person','phone','email')),
    visit_date       date not null default current_date,
    inventory_level  text check (inventory_level in ('empty','low','good','overstock')),
    store_condition  smallint check (store_condition between 1 and 5),
    display_quality  smallint check (display_quality between 1 and 5),
    staff_knowledge  smallint check (staff_knowledge between 1 and 5),
    store_traffic    text check (store_traffic in ('poor','average','busy')),
    competitor_promos text check (competitor_promos in ('none','some','heavy')),
    competition_seen text[] not null default '{}',   -- brand checkboxes
    comments         text,
    created_at       timestamptz not null default now()
);
alter table public.visits enable row level security;
create index if not exists idx_visits_customer on public.visits (customer_key, visit_date desc);

-- photos.visit_id FK (photos table created in 004 before visits existed)
alter table public.photos
  drop constraint if exists photos_visit_id_fkey,
  add constraint photos_visit_id_fkey
    foreign key (visit_id) references public.visits (id) on delete set null;

--------------------------------------------------------------------------
-- Auto-advance a recommendation to 'acted' when an action references it
--------------------------------------------------------------------------
create or replace function public.mark_recommendation_acted()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.recommendation_id is not null then
    update public.recommendations
       set status = 'acted'
     where id = new.recommendation_id and status = 'open';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_action_marks_acted on public.actions;
create trigger trg_action_marks_acted after insert on public.actions
  for each row execute function public.mark_recommendation_acted();

-- Stamp closed_by/closed_at when a recommendation reaches a terminal state
create or replace function public.stamp_recommendation_close()
returns trigger language plpgsql
as $$
begin
  if new.status in ('closed','dismissed') and old.status not in ('closed','dismissed') then
    new.closed_by := coalesce(new.closed_by, auth.uid());
    new.closed_at := coalesce(new.closed_at, now());
  end if;
  return new;
end;
$$;

drop trigger if exists trg_rec_close_stamp on public.recommendations;
create trigger trg_rec_close_stamp before update on public.recommendations
  for each row execute function public.stamp_recommendation_close();
