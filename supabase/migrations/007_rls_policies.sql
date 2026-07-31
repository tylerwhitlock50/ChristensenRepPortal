/*============================================================================
  007_rls_policies.sql
  Purpose: All row-level security policies in one place.
  Model  :
    - Reps see ONLY data for accounts assigned to them (account_assignments).
    - Admins see everything.
    - The ETL and the recommendation job run as service_role (bypasses RLS).
    - erp.* is SELECT-only for the app: no insert/update/delete policies
      exist, so writes are impossible for authenticated users regardless
      of grants.
============================================================================*/

--------------------------------------------------------------------------
-- erp schema — read-only, account-scoped where customer-keyed
--------------------------------------------------------------------------
-- Customer-agnostic dims: any authenticated user can read
create policy "read dim_part"      on erp.dim_part      for select to authenticated using (true);
create policy "read dim_sales_rep" on erp.dim_sales_rep for select to authenticated using (true);
create policy "read inventory"     on erp.fact_inventory_on_hand for select to authenticated using (true);

-- Customer-scoped: gated by assignment
create policy "read own dim_customer" on erp.dim_customer
  for select to authenticated using (public.has_account_access(customer_key));

create policy "read own dim_ship_to" on erp.dim_ship_to
  for select to authenticated using (public.has_account_access(customer_id));

create policy "read own fact_order_line" on erp.fact_order_line
  for select to authenticated using (public.has_account_access(customer_key));

create policy "read own fact_invoice_line" on erp.fact_invoice_line
  for select to authenticated using (public.has_account_access(customer_key));

create policy "read own fact_shipment_line" on erp.fact_shipment_line
  for select to authenticated using (public.has_account_access(customer_key));

--------------------------------------------------------------------------
-- profiles
--------------------------------------------------------------------------
create policy "read own profile" on public.profiles
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "admin manages profiles" on public.profiles
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

--------------------------------------------------------------------------
-- account_assignments — reps read their own; admin manages
--------------------------------------------------------------------------
create policy "read own assignments" on public.account_assignments
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
create policy "admin manages assignments" on public.account_assignments
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

--------------------------------------------------------------------------
-- contacts / notes / photos — account-scoped read+write
--------------------------------------------------------------------------
create policy "read contacts" on public.contacts
  for select to authenticated using (public.has_account_access(customer_key));
create policy "write contacts" on public.contacts
  for insert to authenticated with check (public.has_account_access(customer_key) and created_by = auth.uid());
create policy "update contacts" on public.contacts
  for update to authenticated using (public.has_account_access(customer_key));
create policy "admin deletes contacts" on public.contacts
  for delete to authenticated using (public.is_admin());

create policy "read notes" on public.notes
  for select to authenticated using (public.has_account_access(customer_key));
create policy "write notes" on public.notes
  for insert to authenticated with check (public.has_account_access(customer_key) and created_by = auth.uid());
create policy "admin deletes notes" on public.notes
  for delete to authenticated using (public.is_admin());

create policy "read photos" on public.photos
  for select to authenticated using (public.has_account_access(customer_key));
create policy "write photos" on public.photos
  for insert to authenticated with check (public.has_account_access(customer_key) and created_by = auth.uid());
create policy "admin deletes photos" on public.photos
  for delete to authenticated using (public.is_admin());

--------------------------------------------------------------------------
-- tasks — personal: owner full control; admin read
--------------------------------------------------------------------------
create policy "own tasks" on public.tasks
  for all to authenticated
  using (user_id = auth.uid() or public.is_admin())
  with check (user_id = auth.uid() or public.is_admin());

--------------------------------------------------------------------------
-- rule_settings — everyone can read (reason strings shown in UI), admin edits
--------------------------------------------------------------------------
create policy "read rules" on public.rule_settings
  for select to authenticated using (true);
create policy "admin manages rules" on public.rule_settings
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

--------------------------------------------------------------------------
-- recommendations — reps read/update (act, close-with-outcome) on their
-- accounts; only admin INSERTS via the app (system rows come from the
-- service-role job). Reps cannot create or delete recommendations.
--------------------------------------------------------------------------
create policy "read recommendations" on public.recommendations
  for select to authenticated using (public.has_account_access(customer_key));
create policy "admin creates recommendations" on public.recommendations
  for insert to authenticated with check (public.is_admin());
create policy "update recommendations" on public.recommendations
  for update to authenticated
  using (public.has_account_access(customer_key))
  with check (public.has_account_access(customer_key));
create policy "admin deletes recommendations" on public.recommendations
  for delete to authenticated using (public.is_admin());

--------------------------------------------------------------------------
-- actions / visits — account-scoped insert; author or admin
--------------------------------------------------------------------------
create policy "read actions" on public.actions
  for select to authenticated using (public.has_account_access(customer_key));
create policy "write actions" on public.actions
  for insert to authenticated with check (public.has_account_access(customer_key) and user_id = auth.uid());
create policy "admin deletes actions" on public.actions
  for delete to authenticated using (public.is_admin());

create policy "read visits" on public.visits
  for select to authenticated using (public.has_account_access(customer_key));
create policy "write visits" on public.visits
  for insert to authenticated with check (public.has_account_access(customer_key) and user_id = auth.uid());
create policy "admin deletes visits" on public.visits
  for delete to authenticated using (public.is_admin());

--------------------------------------------------------------------------
-- ai_summaries — account-scoped read; account-scoped upsert (the frontend
-- writes the summary it got back from the Claude API)
--------------------------------------------------------------------------
create policy "read ai summaries" on public.ai_summaries
  for select to authenticated using (public.has_account_access(customer_key));
create policy "write ai summaries" on public.ai_summaries
  for insert to authenticated with check (public.has_account_access(customer_key));
create policy "update ai summaries" on public.ai_summaries
  for update to authenticated using (public.has_account_access(customer_key));

--------------------------------------------------------------------------
-- login_events — no insert policy on purpose: rows are written only via
-- the security-definer RPC public.log_login(). Reads own; admin reads all.
--------------------------------------------------------------------------
create policy "read login events" on public.login_events
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
