/*============================================================================
  20260908120000_help_and_support.sql — in-app help articles and a support
  inbox, for the wider rollout.

  Why
  ---
  One admin cannot field "how do I…" questions by phone for the whole field.
  Two things make that tractable: written how-tos the rep can read first, and
  a question box that lands in the database (not a mailbox) so every ask is
  visible, answerable in the portal, and re-readable by the rep who asked.

  What
  ----
  1. help_articles   — admin-authored how-to / best-practice content, in a
                       light Markdown the frontend renders itself. Reps read
                       published rows; admins manage all rows.
  2. support_requests — one row per question a rep asks. Carries the page
                       they were on and browser context, captured by the
                       client, so the answer needs no "which screen?" reply.
  3. support_messages — the thread under a request: the original ask, admin
                       replies, rep follow-ups. A trigger stamps whether the
                       author was an admin (reps cannot read admin profiles)
                       and moves the request between open / answered.

  Access
  ------
  A rep sees only their own requests and the messages under them. Admins see
  everything. The view-as read-only trigger is re-swept at the end so an admin
  "viewing as" a rep cannot post in that rep's name.

  Idempotent; safe to re-run.
============================================================================*/

--------------------------------------------------------------------------
-- 1. help_articles
--------------------------------------------------------------------------
create table if not exists public.help_articles (
    id          bigint generated always as identity primary key,
    slug        text not null unique
                check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    title       text not null check (length(title) between 1 and 160),
    -- Short line under the title in the list. Optional.
    summary     text,
    -- Light Markdown: headings, paragraphs, bold, lists, links.
    body        text not null default '',
    category    text not null default 'How to'
                check (length(category) between 1 and 60),
    sort_order  int  not null default 100,
    published   boolean not null default false,
    created_by  uuid references public.profiles (user_id),
    updated_by  uuid references public.profiles (user_id),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);
alter table public.help_articles enable row level security;

create index if not exists idx_help_articles_published
  on public.help_articles (published, category, sort_order);

create or replace function public.touch_help_article()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

drop trigger if exists trg_help_articles_touch on public.help_articles;
create trigger trg_help_articles_touch
  before update on public.help_articles
  for each row execute function public.touch_help_article();

drop policy if exists "read published help" on public.help_articles;
create policy "read published help" on public.help_articles
  for select to authenticated
  using (published or (select public.is_admin()));

drop policy if exists "admin writes help" on public.help_articles;
create policy "admin writes help" on public.help_articles
  for insert to authenticated
  with check ((select public.is_admin()));

drop policy if exists "admin updates help" on public.help_articles;
create policy "admin updates help" on public.help_articles
  for update to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

drop policy if exists "admin deletes help" on public.help_articles;
create policy "admin deletes help" on public.help_articles
  for delete to authenticated
  using ((select public.is_admin()));

revoke all on public.help_articles from anon, public;
grant select, insert, update, delete on public.help_articles to authenticated;

--------------------------------------------------------------------------
-- 2. support_requests
--------------------------------------------------------------------------
create table if not exists public.support_requests (
    id          bigint generated always as identity primary key,
    user_id     uuid not null default auth.uid()
                references public.profiles (user_id) on delete cascade,
    subject     text not null check (length(subject) between 1 and 200),
    category    text not null default 'question'
                check (category in ('question', 'problem', 'idea')),
    -- Route path the rep was on when they asked ("/accounts/12345").
    page_path   text,
    -- Client-captured: user agent, viewport, app build. Diagnostic only.
    context     jsonb not null default '{}'::jsonb,
    status      text not null default 'open'
                check (status in ('open', 'answered', 'closed')),
    created_at  timestamptz not null default now(),
    -- Bumped by every message; the queue sorts on it.
    updated_at  timestamptz not null default now()
);
alter table public.support_requests enable row level security;

create index if not exists idx_support_requests_user
  on public.support_requests (user_id, updated_at desc);
create index if not exists idx_support_requests_status
  on public.support_requests (status, updated_at desc);

drop policy if exists "own support requests" on public.support_requests;
create policy "own support requests" on public.support_requests
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "ask a question" on public.support_requests;
create policy "ask a question" on public.support_requests
  for insert to authenticated
  with check (user_id = (select auth.uid()));

-- The requester can close / reopen their own; admins can change any. Column
-- edits beyond status are harmless (it is the rep's own text) so this is not
-- narrowed further.
drop policy if exists "update support requests" on public.support_requests;
create policy "update support requests" on public.support_requests
  for update to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()))
  with check (user_id = (select auth.uid()) or (select public.is_admin()));

drop policy if exists "admin deletes support requests" on public.support_requests;
create policy "admin deletes support requests" on public.support_requests
  for delete to authenticated
  using ((select public.is_admin()));

revoke all on public.support_requests from anon, public;
grant select, insert, update, delete on public.support_requests to authenticated;

--------------------------------------------------------------------------
-- 3. support_messages
--------------------------------------------------------------------------
create table if not exists public.support_messages (
    id          bigint generated always as identity primary key,
    request_id  bigint not null
                references public.support_requests (id) on delete cascade,
    author_id   uuid not null default auth.uid()
                references public.profiles (user_id) on delete cascade,
    -- Stamped by trigger. A rep cannot read the admin's profile row, so the
    -- thread needs this to label "Support" vs "You" without a join.
    from_admin  boolean not null default false,
    body        text not null check (length(body) between 1 and 8000),
    created_at  timestamptz not null default now()
);
alter table public.support_messages enable row level security;

create index if not exists idx_support_messages_request
  on public.support_messages (request_id, created_at);

/*
  Before insert: record who is answering, and move the request along.
    admin posts on an open request      → answered
    requester posts on an answered or
    closed one                          → open   (they had a follow-up)
  Either way the request's updated_at moves so it rises in the queue. The
  update runs as the caller, so RLS on support_requests still applies —
  which is what we want: you can only bump a request you can see.
*/
create or replace function public.on_support_message()
returns trigger
language plpgsql
set search_path to ''
as $$
declare
  req_user uuid;
  req_status text;
begin
  new.from_admin := public.is_admin();

  select user_id, status into req_user, req_status
    from public.support_requests where id = new.request_id;

  if new.from_admin and new.author_id <> req_user and req_status = 'open' then
    update public.support_requests
       set status = 'answered', updated_at = now()
     where id = new.request_id;
  elsif new.author_id = req_user and req_status in ('answered', 'closed') then
    update public.support_requests
       set status = 'open', updated_at = now()
     where id = new.request_id;
  else
    update public.support_requests
       set updated_at = now()
     where id = new.request_id;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_support_messages_insert on public.support_messages;
create trigger trg_support_messages_insert
  before insert on public.support_messages
  for each row execute function public.on_support_message();

drop policy if exists "read thread" on public.support_messages;
create policy "read thread" on public.support_messages
  for select to authenticated
  using (exists (
    select 1 from public.support_requests r
     where r.id = support_messages.request_id
       and (r.user_id = (select auth.uid()) or (select public.is_admin()))
  ));

drop policy if exists "post to thread" on public.support_messages;
create policy "post to thread" on public.support_messages
  for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and exists (
      select 1 from public.support_requests r
       where r.id = support_messages.request_id
         and (r.user_id = (select auth.uid()) or (select public.is_admin()))
    )
  );

-- Supabase's default privileges hand `authenticated` ALL on every new table;
-- a thread message is append-only, so take the rest back explicitly (RLS has
-- no update/delete policy either, but the grant should say what we mean).
revoke all on public.support_messages from anon, public;
revoke update, delete, truncate, references, trigger on public.support_messages from authenticated;
grant select, insert on public.support_messages to authenticated;

revoke execute on function public.touch_help_article()  from public, anon;
revoke execute on function public.on_support_message()  from public, anon;

--------------------------------------------------------------------------
-- 4. View-as is read-only here too (same sweep as 20260901190200).
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

--------------------------------------------------------------------------
-- 5. Starter articles. Only inserted where the slug is new, so an admin's
--    edits in the portal survive a re-run.
--------------------------------------------------------------------------
insert into public.help_articles (slug, title, summary, category, sort_order, published, body)
values
('getting-started', 'Getting started', 'What the portal is for and the three things to check every morning.', 'Start here', 10, true,
$md$
The Rep Portal is a read-only window onto your territory: what shipped, what is on order, what is owed, and where the opportunities are. Nothing you do here changes an order in the ERP.

## The three-minute morning

1. **Overview** — the morning briefing. Territory health, the AI sales brief, biggest movers, and accounts worth a look today.
2. **Find** — the fastest way to answer "where's my order?" when a dealer calls.
3. **Accounts** — every account in your book, sorted by what matters. Tap one for the full picture.

## When is the data current?

The warehouse loads every evening at about 5 PM Mountain. The **Data through** stamp on the Overview tells you the newest invoice date loaded. Anything that shipped after that shows up tomorrow.

## Signing in on a phone

The portal works in the phone browser. Add it to your home screen (Share → Add to Home Screen on iPhone, the ⋮ menu → Add to Home screen on Android) and it opens like an app.
$md$),

('money-words', 'Revenue, bookings, backlog — three words that are not interchangeable', 'Get these right and every number on the portal reads correctly.', 'Start here', 20, true,
$md$
Every dollar figure on the portal is one of three things. They are never added together.

- **Revenue (invoiced)** — shipped and billed. This is what "sales" and "YTD" mean everywhere here. Goals are measured against revenue.
- **Bookings (order value)** — placed, not yet shipped. A big booking is good news but it is not revenue yet.
- **Backlog** — the unshipped remainder of open orders. Money owed to you, not earned. On the portal, *backlog* means lines past their promise date; *open orders* means everything still owed.

## Why it matters

A dealer who says "we bought $40k from you this year" is usually quoting bookings. Your goal progress is invoiced revenue. If the two disagree, look at the account's open orders — the gap is usually sitting in backlog.

All figures are US dollars and calendar year to date unless the screen says otherwise.
$md$),

('find-an-order', 'Find an order in ten seconds', 'Search by the dealer''s PO, our order number, or a tracking number.', 'How to', 30, true,
$md$
Open **Find** in the nav bar and type any one of:

- the dealer's **PO number** (what they wrote on the order),
- our **order number** (SO…),
- a **UPS tracking number** (1Z…).

You get the order header, every line with its ship status, and the shipments with tracking links. Tap a tracking number to open it on ups.com.

## Tips

- Partial numbers work. Three or four digits of a PO is usually enough.
- Find searches your whole book, so you do not need to know which account it was.
- If nothing comes up, check the **Data through** date — an order entered this afternoon will not be loaded until tonight.
$md$),

('account-page', 'Reading an account page', 'Summary, revenue trend, orders, backlog, what they buy, and who to call.', 'How to', 40, true,
$md$
Open **Accounts**, search by name, city or customer number, and tap the account.

## Top to bottom

- **Summary** — YTD revenue against last year, the goal and whether they are on pace, and the last order and shipment dates.
- **Revenue chart** — month by month, this year over last. Look for the months that went quiet.
- **Ready to ship / On backorder** — what is owed to them right now and what is waiting on stock.
- **Recent orders and shipments** — tap a row for the lines and the tracking.
- **What they buy** — SKU-level sales, and the gaps: products their peers stock and they do not. This is your opening for the next visit.
- **Contacts** — who to call. Keep these current; it saves the next person a lookup.

## Goal pace

Pace is seasonal, not straight-line. An account that did most of its buying in the fall can be "behind" in June on days and still on pace. The on-track badge already accounts for that.
$md$),

('sales-intel', 'Sales Intel: SKU sales, backlog, ATS, global', 'The territory-wide views for planning a week or prepping a visit.', 'How to', 50, true,
$md$
**Intel** in the nav bar holds the territory-wide views.

- **SKU Sales** — best sellers across your book, and per-account gaps. Pick one account to see what they are missing compared with similar dealers.
- **Backlog** — every open line by SKU, filterable by account. Use it before you call a dealer who is asking "when?".
- **ATS (available to sell)** — what is in stock right now, in units. A quick check before you promise a delivery.
- **Global** — company-wide product movement, in units only, so you can see which families are trending beyond your territory.
- **Price Lists** — current sheets, downloadable.

Every grid has a filter box; try a chambering or a family name, not just a SKU.
$md$),

('connect-claude', 'Ask Claude about your territory', 'Connect the portal to Claude and ask questions in plain English.', 'How to', 60, true,
$md$
The account menu (your initials, top right) has **Connect Claude**. It creates a personal token that lets Claude read your territory data — only your accounts, read-only.

1. Open the account menu → **Connect Claude**.
2. Give the token a name (the device you will use it on) and create it.
3. Copy the token now — it is shown once. Follow the on-page instructions to add it to Claude.

Then ask things like "which of my accounts are behind on pace?" or "what did Smith Outdoors buy last quarter?".

Lost a token? Revoke it on the same page and create a new one.
$md$),

('reset-password', 'Locked out or forgot your password', 'Reset it yourself from the sign-in screen.', 'How to', 70, true,
$md$
On the sign-in screen, tap **Forgot your password?**, enter your email, and follow the link in the message you receive. You will pick a new password and sign in again.

If the email never arrives, check spam, then ask a question here and an admin will reset it for you.
$md$),

('ask-for-help', 'Asking a question or reporting a problem', 'Use the question box on this page — it is the fastest route to an answer.', 'Start here', 80, true,
$md$
Scroll down on this page to **Ask a question**. Pick whether it is a question, a problem, or an idea, and describe it. The page you were on and your device details are attached automatically, so you do not need to explain which screen.

Your questions and their answers stay under **Your questions** on this page — you will see the reply here, and you can follow up in the same thread.

For a problem, the most useful things to include are the account or order number you were looking at and what you expected to see.
$md$)
on conflict (slug) do nothing;
