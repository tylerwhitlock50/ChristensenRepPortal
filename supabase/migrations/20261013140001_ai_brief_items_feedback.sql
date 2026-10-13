/*============================================================================
  20261013140001_ai_brief_items_feedback.sql
  Purpose: Tappable territory-brief headlines, and a thumbs signal on AI
           output.

  1. ai_briefs.items
  ------------------
  ai-brief now asks the model for strict JSON: the same prose `content` as
  before (HEADLINES block + paragraphs — the deployed frontend parses that
  and keeps working), plus a structured copy of the headlines, each tagged
  with the ONE account it is about:

      { "headlines": [ { "text": "...", "customer_key": "C1001" | null,
                         "account_name": "Fixture Outfitters" | null } ] }

  Every customer_key is checked server-side against the keys that were in
  the context the model saw; anything else is nulled before it is stored, so
  a chip can only ever link to an account in the caller's own book.
  account_name comes from that same context, never from the model.

  Nullable, no backfill: existing rows have no items and render as prose.
  No grant or policy changes — ai_briefs has table-level grants (028).

  2. public.ai_feedback
  ---------------------
  "Helpful" / "Something's wrong" under an AI brief. One row per vote, per
  user. The admin read is the point: helpful/wrong per surface and
  prompt_version is the first usefulness signal the AI layer has had.

    surface         'territory_brief' | 'account_summary'
    subject_key     '' for the territory brief, the customer_key for an
                    account summary
    prompt_version  the version that wrote the brief being judged

  RLS: a user reads and writes their own rows; admins read all. An
  account_summary vote must be about an account the caller can see
  (has_account_access — view-as aware, 20260816140000). Writes are refused
  while an admin is viewing as a rep (the 20260901190200 trigger, attached
  below because the sweep only covers tables that existed when it ran).
  Users may change their vote or add a note (update own row); nobody deletes.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Structured headlines.
--------------------------------------------------------------------------
alter table public.ai_briefs
  add column if not exists items jsonb;

comment on column public.ai_briefs.items is
  'Structured copy of the brief''s headlines: {"headlines": [{"text", '
  '"customer_key", "account_name"}]}. customer_key is validated against the '
  'generation context (never trusted from the model); null when the brief was '
  'written before 20261013140001 or the headline is not about one account.';

--------------------------------------------------------------------------
-- 2. Feedback.
--------------------------------------------------------------------------
create table if not exists public.ai_feedback (
    id              bigint generated always as identity primary key,
    user_id         uuid not null default auth.uid()
                    references public.profiles (user_id) on delete cascade,
    surface         text not null
                    check (surface in ('territory_brief', 'account_summary')),
    subject_key     text not null default '',
    prompt_version  text,
    verdict         text not null check (verdict in ('helpful', 'wrong')),
    note            text check (note is null or char_length(note) <= 1000),
    created_at      timestamptz not null default now()
);
alter table public.ai_feedback enable row level security;

-- The card asks "did I already vote on this brief?": own rows for one
-- surface + subject, newest first. Also covers the FK.
create index if not exists idx_ai_feedback_user_subject
  on public.ai_feedback (user_id, surface, subject_key, created_at desc);
-- The admin rollup: verdicts per surface and prompt version.
create index if not exists idx_ai_feedback_surface_version
  on public.ai_feedback (surface, prompt_version);

drop policy if exists "read own ai feedback" on public.ai_feedback;
create policy "read own ai feedback" on public.ai_feedback
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "write own ai feedback" on public.ai_feedback;
create policy "write own ai feedback" on public.ai_feedback
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and (surface = 'territory_brief' or public.has_account_access(subject_key))
  );

drop policy if exists "update own ai feedback" on public.ai_feedback;
create policy "update own ai feedback" on public.ai_feedback
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- authenticated too: the platform's default privileges hand it ALL on a new
-- public table, and the column grant below means nothing next to a
-- table-wide UPDATE (it would let a vote's surface or subject be rewritten
-- after the insert check). Same shape as support_messages (20260908).
revoke all on public.ai_feedback from anon, public, authenticated;
grant select, insert on public.ai_feedback to authenticated;
-- A changed mind or an added note; the rest of the row is the record.
grant update (verdict, note) on public.ai_feedback to authenticated;

drop trigger if exists trg_ai_feedback_no_write_while_viewing_as on public.ai_feedback;
create trigger trg_ai_feedback_no_write_while_viewing_as
  before insert or update or delete on public.ai_feedback
  for each row execute function public.block_writes_while_impersonating();

comment on table public.ai_feedback is
  'Thumbs on AI output: one row per vote (helpful | wrong, optional note) '
  'per user, surface (territory_brief | account_summary), subject and '
  'prompt_version. Own rows read/write; admins read all. Read-only while '
  'viewing as a rep.';
