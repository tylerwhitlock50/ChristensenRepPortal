/*============================================================================
  20261028_help_getting_started_refresh.sql — assertions for
    20261028100000_help_getting_started_refresh.sql
      public.help_articles  'getting-started': "When is the data current?"
                            'find-an-order':   the "nothing comes up" tip

  Runs in a transaction and ROLLS BACK. Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261028_help_getting_started_refresh.sql
      (or: etl/run_sql_guard.py <migration> <this file>, from etl/)

  A clean run prints "ALL GETTING STARTED REFRESH TESTS PASSED".

  Each update is guarded by its seeded sentence (position(...) > 0), so an
  admin-edited article and a second run are both no-ops. With the sentence
  gone after the first run, the "gone" assertions below are also what make a
  re-run match nothing.
============================================================================*/

begin;

\set ON_ERROR_STOP on

create or replace function pg_temp.assert(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAILED: %', p_what; end if;
  raise notice 'ok  %', p_what;
end $$;

select pg_temp.assert(
  (select count(*) from public.help_articles
    where slug in ('getting-started', 'find-an-order') and published) = 2,
  'both articles are still there, published');

--------------------------------------------------------------------------
-- getting-started
--------------------------------------------------------------------------
select pg_temp.assert(
  (select position('every evening at about 5 PM' in body) = 0
     from public.help_articles where slug = 'getting-started'),
  'getting-started: the once-a-day sentence is gone');

select pg_temp.assert(
  (select bool_and(position(lower(p) in lower(body)) > 0)
     from public.help_articles,
          unnest(array['every 15 minutes', 'every hour', '4:30 AM', 'All times are Mountain',
                        'Invoiced through Oct 27, 2026', 'Stock as of',
                        'Why the portal and Tableau numbers differ']) p
    where slug = 'getting-started'),
  'getting-started: the refresh tiers, the stamp as it reads, and the Tableau article');

select pg_temp.assert(
  (select bool_and(position(p in body) > 0)
     from public.help_articles,
          unnest(array['## The three-minute morning', '## When is the data current?',
                        '## Signing in on a phone']) p
    where slug = 'getting-started'),
  'getting-started: the rest of the article is intact');

--------------------------------------------------------------------------
-- find-an-order
--------------------------------------------------------------------------
select pg_temp.assert(
  (select position('Data through' in body) = 0 and position('until tonight' in body) = 0
     from public.help_articles where slug = 'find-an-order'),
  'find-an-order: no "Data through" stamp and no "until tonight"');

select pg_temp.assert(
  (select bool_and(position(lower(p) in lower(body)) > 0)
     from public.help_articles,
          unnest(array['newer than the last load', 'every hour', '4:30 AM', '*Loaded* time']) p
    where slug = 'find-an-order'),
  'find-an-order: the tip gives the hourly loads and where to see the last one');

select pg_temp.assert(
  (select bool_and(position(p in body) > 0)
     from public.help_articles,
          unnest(array['## Tips', 'Partial numbers work.',
                        'Find searches your whole book']) p
    where slug = 'find-an-order'),
  'find-an-order: the other tips are intact');

do $$ begin raise notice 'ALL GETTING STARTED REFRESH TESTS PASSED'; end $$;

rollback;
