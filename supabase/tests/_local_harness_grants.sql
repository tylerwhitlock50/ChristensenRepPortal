/*============================================================================
  _local_harness_grants.sql — apply AFTER the migrations, never before.

  Supabase ships default privileges that grant `authenticated` usage and
  execute across the public schema. Several migrations rely on that and
  therefore never write an explicit grant — public.is_admin() is the clearest
  example: 017_function_hardening.sql revokes it from `public` and `anon` and
  says nothing about `authenticated`, because the platform already granted it.

  A bare cluster has none of that, so without this file the tests fail with
  "permission denied for function is_admin" — a harness artifact, NOT a
  product bug. Resist the urge to "fix" it by adding grants to the migrations:
  that would be writing platform configuration into the product schema.

  Runs last because `grant … on all tables` only covers relations that already
  exist.
============================================================================*/

grant usage on schema public to authenticated, anon;
grant usage on schema erp    to authenticated;

-- The platform grants these; policies that reference auth.uid() directly —
-- e.g. `user_id = (select auth.uid())` on orders — evaluate it as the
-- calling role, so `authenticated` needs to reach it here too.
grant usage on schema auth to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;

grant select, insert, update, delete on all tables    in schema public to authenticated;
grant usage, select                  on all sequences in schema public to authenticated;
grant execute                        on all functions in schema public to authenticated;

grant select  on all tables    in schema erp to authenticated;
grant execute on all functions in schema erp to authenticated;

alter default privileges in schema public grant execute on functions to authenticated;

/* service_role is what the ETL and the nightly jobs connect as, and on
   Supabase it arrives with blanket grants plus BYPASSRLS. A bare cluster
   gives it nothing, so any test that asserts something about the job path
   fails with "permission denied" long before it reaches the behaviour it
   meant to check. BYPASSRLS is a role attribute rather than a grant, so it
   is set alongside the role itself in _local_harness.sql, not here. */
grant usage on schema public, erp to service_role;
grant select, insert, update, delete on all tables    in schema public to service_role;
grant usage, select                  on all sequences in schema public to service_role;
grant execute                        on all functions in schema public to service_role;
grant select, insert, update, delete on all tables    in schema erp    to service_role;

--------------------------------------------------------------------------
-- Re-apply the revokes the migrations make deliberately. The blanket grants
-- above are broader than Supabase's and would otherwise undo them, which
-- would make the tests pass for the wrong reason.
--------------------------------------------------------------------------
revoke execute on function public.is_admin()                  from public, anon;
revoke execute on function public.has_account_access(text)     from public, anon;
revoke execute on function public.my_customer_keys()           from public, anon;

-- Job-only functions: 019/020/030 revoke these from `authenticated` so a rep
-- cannot trigger a full rescore or mint recommendations.
revoke execute on function public.refresh_account_signals()    from authenticated, anon, public;
revoke execute on function public.generate_recommendations()   from authenticated, anon, public;
