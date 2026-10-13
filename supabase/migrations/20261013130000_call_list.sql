/*============================================================================
  20261013130000_call_list.sql — the rep's reactions to "Worth a call today",
  and the switch for the quick call log.

  Why
  ---
  The Overview's call list is account_signals ordered by score: the nightly
  ranking 019/020 already compute, finally on the rep's front door. Without
  memory it shows the same accounts every morning, including the one the rep
  rang yesterday and the one that is closed for the winter. A reaction is
  the rep telling the list "not today": it hides that account from THEIR
  list for a while, and nothing else.

  Deliberately not a recommendation row, and not an outcome. Observations
  are not work (CEO direction, see 024's header and ai-brief/prompts.ts):
  nothing here opens, closes or assigns anything, the nightly score does not
  read it, and an admin sees reactions only as feedback on the ranking. The
  client applies the windows — on_it 3 days, handled 14, not_relevant 45 —
  so they can be tuned without a migration.

  What
  ----
  1. public.call_list_feedback — append-only, one row per reaction. A rep
     inserts and reads their own rows for accounts in their book, and may
     delete their own (the "Undo" right after a tap). Admins read all.
     Reads follow the view-as identity, writes do not: the view-as trigger
     (re-swept below) refuses every write while an admin is viewing as a rep.
  2. app_settings 'feature.quick_log' seeded OFF: after a Call tap from the
     list, offer "Reached them / Left a message / No answer" when the rep
     comes back to the app, logged as a public.actions row.

  Backward compatible: a new table and a new settings row. Nothing existing
  changes shape; the deployed frontend, edge functions and MCP server never
  read either. Idempotent; safe to re-run.
============================================================================*/

--------------------------------------------------------------------------
-- 1. call_list_feedback
--------------------------------------------------------------------------
create table if not exists public.call_list_feedback (
    id            bigint generated always as identity primary key,
    user_id       uuid not null default auth.uid()
                  references public.profiles (user_id) on delete cascade,
    -- erp.dim_customer.customer_key, no FK (the erp schema is reloaded
    -- wholesale), same as account_deactivations (023).
    customer_key  text not null,
    reaction      text not null
                  check (reaction in ('on_it', 'handled', 'not_relevant')),
    reason        text
                  check (reason in ('seasonal', 'store_closed', 'buys_elsewhere',
                                    'wrong_data', 'other')),
    note          text check (note is null or length(note) <= 500),
    created_at    timestamptz not null default now(),
    -- A reason explains "not relevant" and nothing else.
    constraint call_list_feedback_reason_only_when_not_relevant
      check (reason is null or reaction = 'not_relevant')
);
alter table public.call_list_feedback enable row level security;

comment on table public.call_list_feedback is
  'A rep''s reaction to an account on the Overview''s "Worth a call today" '
  'list. Hides it from that rep''s list for a while (windows applied by the '
  'client); assigns, closes and scores nothing. Append-only, own rows.';
comment on column public.call_list_feedback.reason is
  'Only with reaction = not_relevant. Vocabulary mirrored in '
  'frontend/src/composables/useCallList.ts (CALL_LIST_REASONS).';

-- The client's read: my reactions, newest first, inside the longest window.
-- Leads with user_id, so it also serves the FK and every policy predicate.
create index if not exists idx_call_list_feedback_user
  on public.call_list_feedback (user_id, created_at desc);

-- Same predicate shape as account_signals (019) and account_deactivations
-- (023): scalar subqueries so is_admin() and effective_user_id() are
-- InitPlans, my_customer_keys() uncorrelated. Both resolve the view-as
-- identity, so an admin viewing as a rep reads that rep's reactions.
drop policy if exists "read own call list feedback" on public.call_list_feedback;
create policy "read own call list feedback" on public.call_list_feedback
  for select to authenticated
  using (
    (select public.is_admin())
    or (
      user_id = (select public.effective_user_id())
      and customer_key in (select public.my_customer_keys())
    )
  );

-- Writes resolve through auth.uid(), never the acting identity: nobody can
-- author a reaction as somebody else, view-as or not.
drop policy if exists "react to own book" on public.call_list_feedback;
create policy "react to own book" on public.call_list_feedback
  for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and ((select public.is_admin())
         or customer_key in (select public.my_customer_keys()))
  );

-- Undo. Own rows only; there is no update path — a changed mind is a new row.
drop policy if exists "undo own call list feedback" on public.call_list_feedback;
create policy "undo own call list feedback" on public.call_list_feedback
  for delete to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.call_list_feedback from anon, public;
revoke all on public.call_list_feedback from authenticated;
grant select, insert, delete on public.call_list_feedback to authenticated;

--------------------------------------------------------------------------
-- 2. The quick call log switch. Off, like every capture feature (024).
--------------------------------------------------------------------------
insert into public.app_settings (setting_key, enabled, description) values
  ('feature.quick_log', false,
   'After a Call tap on the Overview call list, offer "Reached them / Left a message / No answer" when the rep comes back, logged as a call')
on conflict (setting_key) do nothing;

--------------------------------------------------------------------------
-- 3. View-as is read-only here too (same sweep as 20260901190200).
--------------------------------------------------------------------------
do $$
declare
  t record;
begin
  for t in
    select tablename
    from pg_tables
    where schemaname = 'public'
      and rowsecurity
      and tablename not in ('impersonation', 'impersonation_events',
                            'login_events', 'job_runs')
    order by tablename
  loop
    execute format(
      'drop trigger if exists trg_%1$s_no_write_while_viewing_as on public.%1$I',
      t.tablename);
    execute format(
      'create trigger trg_%1$s_no_write_while_viewing_as '
      'before insert or update or delete on public.%1$I '
      'for each row execute function public.block_writes_while_impersonating()',
      t.tablename);
  end loop;
end;
$$;
