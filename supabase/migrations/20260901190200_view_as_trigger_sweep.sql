/*============================================================================
  20260901190200_view_as_trigger_sweep.sql — view-as is read-only on the
  order and price-list tables too.

  Why
  ---
  20260816140000 §11 attached block_writes_while_impersonating() to every
  RLS-enabled public table — as of the moment it ran. orders, order_lines,
  order_qc_results, price_lists, price_list_items and price_list_files were
  created the next day (20260817000100/000200) and never got the trigger.
  While impersonating, the "rep creates draft orders" policy passes
  (user_id = auth.uid() is the admin; customer_key is in the target's
  book, which is what my_customer_keys() now answers) and submit_order()
  completes: a real order under the admin's identity against the rep's
  account. Latent while feature.orders is off; not latent once it is on.

  What
  ----
  The same sweep, restated. It is idempotent (drop-if-exists + create), so
  it is also the thing to re-run — or better, copy into the migration —
  whenever a new RLS-enabled table lands. supabase/tests/20260901_view_as
  _trigger_sweep.sql asserts full coverage so the next omission fails a
  test instead of a review.
============================================================================*/

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
