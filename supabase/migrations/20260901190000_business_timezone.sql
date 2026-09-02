/*============================================================================
  20260901190000_business_timezone.sql — the database's "today" is Mountain.

  Why
  ---
  Every rollup window, signal, goal-year and freshness view is written in
  terms of current_date, and current_date is evaluated in the session's
  TimeZone — which was UTC. The nightly ETL fires at 5 PM Mountain, which
  under MST is 00:00 UTC the next day: from November to March every
  refresh computed "tomorrow" (days_since_order +1, prior-YTD one day wider
  than YTD), and on 31 December at 5 PM the year rolled — revenue_ytd and
  bookings_ytd reset to $0 for the whole book, ERP goals rolled to the new
  year — while reps were still closing the year. Request-time views had
  the same skew for any rep working after 5 PM Mountain.

  What
  ----
  Set TimeZone at the database level (every new connection — the ETL, the
  deployer, edge functions) and on the PostgREST roles (PostgREST applies
  pg_db_role_setting entries with SET LOCAL on every request, the same
  mechanism the 8s statement_timeout uses). now() is unchanged in absolute
  terms; only date-typed derivations (current_date, ::date, date_trunc on a
  timestamptz) move to Mountain time, which is the calendar the business
  runs on. timestamptz values serialize with a -06/-07 offset instead of
  +00; every consumer parses ISO offsets.

  The company runs on one calendar, so this is a single setting rather than
  a business_today() helper threaded through forty functions.
============================================================================*/

alter database postgres set timezone to 'America/Denver';

alter role authenticated set timezone to 'America/Denver';
alter role anon          set timezone to 'America/Denver';
alter role authenticator set timezone to 'America/Denver';

-- The refresh is the one function whose windows are load-bearing for every
-- other read; pin it so it cannot be run from a UTC session by mistake
-- (a psql from a laptop, a one-off dashboard call).
alter function public.refresh_territory_rollups() set timezone to 'America/Denver';

-- PostgREST caches role settings with its schema cache.
notify pgrst, 'reload config';
