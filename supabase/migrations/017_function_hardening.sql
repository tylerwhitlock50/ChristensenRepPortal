/*============================================================================
  017_function_hardening.sql

  Why: the Supabase database linter flags two classes of finding across
  functions created in 004, 005, 008 and 016. Neither is exploitable today,
  but both are cheap to close and both get harder to reason about as the
  function list grows.

    0028/0029 — SECURITY DEFINER functions executable by anon/authenticated.
    0011      — functions with a role-mutable search_path.

  Nothing here changes behaviour. Every statement was verified against this
  database in a rolled-back transaction before being written: the profile
  placeholder guard still rejects WEB and still allows an ordinary rep key,
  the close stamp still sets closed_at, the mission visit guard still raises
  mission_requires_visit, and erp.key_to_date still computes
  fact_order_line.desired_ship_date (including the 19000101 null sentinel).

  Deliberately NOT touched
  ------------------------
  public.rls_auto_enable() is flagged by the same lint but is not ours — it
  is not created by any migration in this directory; it is the platform's
  auto-enable-RLS event trigger. Leave platform objects to the platform.

  auth_leaked_password_protection is also outstanding. It is a dashboard
  setting (Auth → Providers → Password), not SQL, so it cannot be fixed here.
============================================================================*/

--------------------------------------------------------------------------
-- 1. Trigger functions: revoke EXECUTE entirely.
--
-- All seven `returns trigger`. PostgreSQL checks EXECUTE on a trigger
-- function at CREATE TRIGGER time, NOT when the trigger fires, so revoking
-- cannot break the triggers that depend on them — verified by firing
-- touch_updated_at as `authenticated` with the grant already revoked.
--
-- They were reachable at /rest/v1/rpc/<name> only because PostgREST exposes
-- everything in the `public` schema with a default PUBLIC grant. A trigger
-- function called that way errors rather than doing damage (it has no NEW/OLD
-- record), so this is defence in depth, not a live hole — but four of them
-- are SECURITY DEFINER, and a definer function should never be reachable by
-- a path nobody intended.
--------------------------------------------------------------------------
revoke execute on function public.enforce_mission_visit()      from public, anon, authenticated;
revoke execute on function public.handle_new_user()            from public, anon, authenticated;
revoke execute on function public.sync_profile_email()         from public, anon, authenticated;
revoke execute on function public.mark_recommendation_acted()  from public, anon, authenticated;
revoke execute on function public.guard_profile_rep_key()      from public, anon, authenticated;
revoke execute on function public.stamp_recommendation_close() from public, anon, authenticated;
revoke execute on function public.touch_updated_at()           from public, anon, authenticated;

--------------------------------------------------------------------------
-- 2. SECURITY DEFINER helpers: drop anon, keep authenticated.
--
-- These three ARE called as RPCs and must keep working:
--   is_admin()            — admin-create-user, admin-update-user edge fns
--   has_account_access()  — ai-account-summary edge fn
--   log_login()           — frontend session store, after sign-in
--
-- Every caller is signed in by definition, so anon needs none of them.
-- log_login() is the one that mattered: as anon it would have written a
-- login_events row with a null user_id, polluting the execution metrics
-- that 016 was protecting when it dropped the "log own login" policy.
--
-- Checked before writing: no RLS policy granted to anon or PUBLIC calls any
-- of these, so nothing degrades from a clean `false` into a permission error.
-- my_customer_keys(), placeholder_rep_keys() and create_mission() already
-- carry no anon grant and are left alone.
--------------------------------------------------------------------------
revoke execute on function public.is_admin()                    from public, anon;
revoke execute on function public.has_account_access(text)      from public, anon;
revoke execute on function public.log_login()                   from public, anon;

--------------------------------------------------------------------------
-- 3. Pin search_path on the four functions still missing it.
--
-- `''` rather than `public` because every body is already fully
-- schema-qualified (public.placeholder_rep_keys, auth.uid) or uses only
-- pg_catalog builtins (make_date, now, coalesce), which resolve regardless.
-- Matches placeholder_rep_keys() from 010, which is already pinned this way.
--
-- key_to_date is IMMUTABLE and backs the generated column
-- erp.fact_order_line.desired_ship_date. ALTER FUNCTION ... SET does not
-- change the body or volatility, so the generated-column dependency is
-- unaffected; confirmed by regenerating the column in a probe table.
--------------------------------------------------------------------------
alter function erp.key_to_date(integer)             set search_path = '';
alter function public.guard_profile_rep_key()       set search_path = '';
alter function public.stamp_recommendation_close()  set search_path = '';
alter function public.touch_updated_at()            set search_path = '';
