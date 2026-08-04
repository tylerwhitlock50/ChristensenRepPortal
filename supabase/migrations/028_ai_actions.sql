/*============================================================================
  028_ai_actions.sql
  Purpose: Storage for the AI Actions layer — the "analyst on every screen".

  Product rule (CEO, Aug 2026): AI interactions are DETERMINISTIC ACTIONS
  (Explain Territory, Explain Backorders, …), not free-form chat. Each
  action is a fixed prompt over the data the user is currently viewing:
  cheap, cacheable, predictable. The ai-brief Edge Function holds the
  whitelisted action registry; this migration gives every current and
  future action one cache table and one usage ledger.

  ai_summaries stays exactly as it is: the account brief is cached PER
  ACCOUNT and shared by everyone who can see that account — that sharing is
  a feature (one generation serves the rep, their group, and the admin).
  Everything else is per-USER (a territory is "the caller's book", which
  differs by caller), hence the (user_id, action, subject_key) key here.
============================================================================*/

--------------------------------------------------------------------------
-- ai_briefs — one cached brief per (user, action, subject).
--   action       registry key, e.g. 'territory.brief'; later
--                'territory.revenue', 'account.buying_pattern', 'intel.backlog'
--   subject_key  '' for territory-scoped actions, a customer_key or other
--                subject id where the action targets one entity. NOT NULL
--                with a '' default so it can participate in the PK.
--------------------------------------------------------------------------
create table if not exists public.ai_briefs (
    user_id        uuid not null references public.profiles (user_id) on delete cascade,
    action         text not null,
    subject_key    text not null default '',
    content        text not null,
    model          text,
    context_hash   text,
    prompt_version text,
    generated_at   timestamptz not null default now(),
    primary key (user_id, action, subject_key)
);
alter table public.ai_briefs enable row level security;

-- Own rows only (admins see all, matching every self-scoped table in 010).
-- The Edge Function writes with the CALLER's JWT — never service_role — so
-- these policies are the entire authorization story.
create policy "own ai briefs" on public.ai_briefs
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
create policy "write own ai briefs" on public.ai_briefs
  for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "update own ai briefs" on public.ai_briefs
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

revoke all on public.ai_briefs from anon, public;
grant select, insert, update on public.ai_briefs to authenticated;

comment on table public.ai_briefs is
  'Cached AI Action output per (user, action, subject). context_hash makes '
  'regeneration free when the underlying data has not changed; '
  'prompt_version ties each brief to the prompt module that produced it.';

--------------------------------------------------------------------------
-- ai_usage_events — one row per PAID generation, across every AI endpoint.
--
-- This is the honest daily-cap counter that ai-account-summary could not
-- have: its cap counted distinct ai_summaries rows per user per day (one
-- row per account, so regenerations of the same account were invisible).
-- Both Edge Functions now insert here on every OpenAI call and count here
-- for the cap. Insert-only; nobody updates or deletes usage history.
--------------------------------------------------------------------------
create table if not exists public.ai_usage_events (
    id         bigint generated always as identity primary key,
    user_id    uuid not null references public.profiles (user_id) on delete cascade,
    action     text not null,      -- 'territory.brief', 'account.summary', …
    created_at timestamptz not null default now()
);
alter table public.ai_usage_events enable row level security;
create index if not exists idx_ai_usage_user_time
  on public.ai_usage_events (user_id, created_at desc);

create policy "own ai usage" on public.ai_usage_events
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));
create policy "log own ai usage" on public.ai_usage_events
  for insert to authenticated
  with check (user_id = (select auth.uid()));

revoke all on public.ai_usage_events from anon, public;
grant select, insert on public.ai_usage_events to authenticated;

comment on table public.ai_usage_events is
  'One row per paid AI generation, all endpoints. The daily cap in the '
  'Edge Functions counts rows here per user per UTC day.';
