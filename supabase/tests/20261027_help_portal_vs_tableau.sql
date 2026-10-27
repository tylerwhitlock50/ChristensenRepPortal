/*============================================================================
  20261027_help_portal_vs_tableau.sql — assertions for
    20261027090700_help_portal_vs_tableau.sql
      public.help_articles  slug 'portal-vs-tableau-numbers'

  Runs in a transaction and ROLLS BACK. Dev only.

      psql "$DATABASE_URL" -f supabase/tests/20261027_help_portal_vs_tableau.sql

  A clean run prints "ALL PORTAL VS TABLEAU HELP TESTS PASSED".
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
    where slug = 'portal-vs-tableau-numbers'
      and title = 'Why the portal and Tableau numbers differ'
      and published) = 1,
  'the article exists under the slug the frontend links to, published');

-- Each point the article must make, by a phrase that carries it.
select pg_temp.assert(
  (select bool_and(position(lower(p) in lower(body)) > 0)
     from public.help_articles,
          unnest(array['invoiced', 'shipped value', 'never revenue', 'credit memos',
                        'cancelled orders', 'same days last year', 'goal %',
                        'released, firmed and hold', 'R01–R09', 'whole dollars',
                        'Midway USA', 'every 15 minutes', 'every hour',
                        '4:30 AM']) p
    where slug = 'portal-vs-tableau-numbers'),
  'body covers revenue, shipped value, cancelled orders, YoY, goal %, open orders, '
  'stock, rounding, the Midway example and the refresh times');

-- Readable by a signed-in rep (published + RLS "read published help").
select set_config('request.jwt.claims',
                  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
set local role authenticated;

select pg_temp.assert(
  (select count(*) from public.help_articles where slug = 'portal-vs-tableau-numbers') = 1,
  'authenticated can read it');

reset role;

do $$ begin raise notice 'ALL PORTAL VS TABLEAU HELP TESTS PASSED'; end $$;

rollback;
