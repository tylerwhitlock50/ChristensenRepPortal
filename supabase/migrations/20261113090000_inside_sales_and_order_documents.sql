/*============================================================================
  20261113090000_inside_sales_and_order_documents.sql
  Purpose: make the order_entry role what inside sales needs, and give orders
           somewhere to keep the customer's PO document. Follows
           20261112120000_admin_order_pricing.

  Deploy: this migration BEFORE the portal build (frontend) and the edge
  functions that use it (order_owner_names, the order-documents bucket, the
  new error codes). The portal already deployed keeps working against it.
  It runs under lock_timeout 10s: etl/deploy_migrations.py applies each file
  in one transaction, so a lock timeout means a load or a long query held a
  table it needs and NOTHING was applied; simply re-run it, outside the ETL
  windows.

  1. Inside sales (profiles.role = 'order_entry') sees every account, may
     draft for any of them, prices and submits its OWN orders, and changes
     nothing account-side.
       * my_customer_keys() returns every customer for an order_entry user
         (minus an admin's account_assignments 'revoke', which also stops
         their Claude drafting for that account). Every account-scoped
         policy, view and MCP read keys off it, so the portal and their
         Claude read every account as an admin does. The profile still
         carries no rep code (order_entry_empty_book stays).
       * block_writes_for_read_only_role(): a trigger on every RLS-enabled
         public table EXCEPT the ones inside sales works in (orders, order
         lines, QC, their own MCP tokens, support questions, AI caches,
         logs). An order_entry session that tries to write a goal, a note, a
         contact, a visit, a task, a price list, a setting or a profile gets
         'read_only_role'. Applies inside SECURITY DEFINER RPCs too: the
         caller is still the order_entry user.
       * ai_summaries stays out of the sweep (the edge function caches under
         the caller's JWT and tolerates a refused write), but its write
         policies now refuse inside sales: the row is the account's one
         shared summary, so their summaries are generated, not cached.
       * The account-photos bucket: read yes, upload no.
       * NOT widened, because these are scoped by user, not by account:
         other users' tasks, profiles (owners' names come from
         order_owner_names(), never emails), and the rep and coverage
         surfaces (v_user_accounts, account_coverage, rep_execution_summary,
         v_rep_activity, v_rep_goal_attainment, v_rep_goal_dashboard,
         mission batches, agency_rep_activity). Inside sales sees every
         account, not every person's work.

     The order loader signs in as an order_entry user. From this migration
     on that login reads every account and every order (drafts included)
     and could price and submit orders of its own. It must be a dedicated
     account whose password is rotated and kept only in the order-entry
     PC's .env (order_loader README and GO_LIVE.md say so).

  2. Pricing by hand is no longer admin-only: can_price_orders() = admin or
     inside sales. mcp_order_apply, submit_order and
     admin_set_order_line_price use it. A rep is unchanged: no price, ever.
       * admin_set_order_line_price: an admin prices any Claude draft;
         anyone else only an order they own (not_owner). submit_order still
         takes the owner or an admin, so whoever may price an order may
         submit it: an admin, or inside sales on their own order.
       * After a hand price the order's promo pass is re-run
         (order_apply_promo(), the same code submit_order runs), so a draft
         shows the totals the submit will compute.

  3. A customer PO number is encouraged, not required. Without one the draft
     is refused once with po_confirmation_required; when the user says there
     is none (no_po_confirmed) the draft is saved and flagged, and
     submit_order gives the order the reference PORTAL-<id> (what the order
     loader already wrote to Visual for a blank PO, now visible in the
     portal too).
       * Blank means blank after trimming spaces, tabs, line breaks and
         no-break spaces; a draft still carrying its own PORTAL-<id> has no
         customer PO; recall_order clears that reference again.
       * Over MCP a PORTAL-<n> PO is refused unless it is the order's own,
         and an update never drops a PO already on the draft
         (po_would_be_removed).

  4. Free goods: a hand-priced order may carry the same part twice at
     different prices (10 paid + 1 at $0). The unique key
     (order_id, price_list_id, part_id) now covers list-priced lines only;
     the same part twice at the SAME price is still refused, by
     mcp_order_apply and by admin_set_order_line_price.

  5. Order documents: a private storage bucket 'order-documents'. Objects are
     named '<order id>/<file name>'; whoever can read the order can read its
     documents and add one; the uploader, an admin or inside sales removes
     one. No table: the bucket listing is the list.

  6. submit_order snapshots the buyer contact (orders.contact_name / _phone /
     _email; an active contact of the account only) so the order loader can
     write it to Visual, and v_orders_ready_for_erp carries it with the
     hand-pricing fields. It refuses a requested ship date that has passed
     (ship_date_past).

  7. MCP drafting: callers who may price get admin_max_drafts_per_user_per_day
     (default 200) like the other admin caps; the duplicate probe is per
     account, not per drafter; stock and inactive-part warnings are per part
     over the order's total qty; last paid price ignores free ($0) lines.

  8. order_owner_names(uuid[]): the display name and role of order owners the
     caller may see, for the order screens.

  Restated function bodies are the deployed ones (pg_get_functiondef) with
  only the changes named above.
============================================================================*/

-- See the header: fail fast instead of queueing behind a load while holding
-- the locks already taken; a timeout is simply re-run.
set local lock_timeout = '10s';

--------------------------------------------------------------------------
-- 1. Who may price by hand
--------------------------------------------------------------------------
create or replace function public.can_price_orders()
returns boolean
language sql stable security definer set search_path = public
as $$
  select public.is_admin() or public.is_order_entry();
$$;

revoke execute on function public.can_price_orders() from public, anon;
grant execute on function public.can_price_orders() to authenticated;

comment on function public.can_price_orders() is
  'Admin or inside sales (order_entry): may set an order line''s price by hand '
  '(inside sales on its own orders, an admin on any) and submit an order that '
  'has hand-priced lines. Reps never can.';

comment on function public.is_order_entry() is
  'True when the caller''s active profile has role=order_entry (inside sales). '
  'They read every account, draft for any customer, price and submit their '
  'own orders, key submitted orders into the ERP, and change nothing '
  'account-side (block_writes_for_read_only_role, 20261113090000).';

--------------------------------------------------------------------------
-- 2. my_customer_keys(): inside sales reads every account
--------------------------------------------------------------------------
create or replace function public.my_customer_keys()
 RETURNS SETOF text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
  with me as (
    select p.sales_rep_key, p.rep_group_vendor_id, p.role
    from public.profiles p
    where p.user_id = public.effective_user_id()
      and p.active
  ),
  derived as (
    -- own book
    select c.customer_key
    from me
    join erp.dim_customer c
      on c.assigned_sales_rep_id = me.sales_rep_key
    where me.sales_rep_key is not null
      and not (me.sales_rep_key = any (public.placeholder_rep_keys()))

    union

    -- group book: principal over every rep in their agency (vendor)
    select c.customer_key
    from me
    join erp.dim_sales_rep sr
      on sr.vendor_id = me.rep_group_vendor_id
    join erp.dim_customer c
      on c.assigned_sales_rep_id = sr.sales_rep_key
    where me.rep_group_vendor_id is not null
      and sr.vendor_id is not null
      and not (sr.sales_rep_key = any (public.placeholder_rep_keys()))

    union

    -- inside sales (order_entry): every account, to read and to order for.
    -- What they may CHANGE is the read-only trigger's business, not this.
    select c.customer_key
    from me
    cross join erp.dim_customer c
    where me.role = 'order_entry'

    union

    -- explicit grant (house accounts, temporary coverage)
    select aa.customer_key
    from public.account_assignments aa
    where aa.user_id = public.effective_user_id()
      and aa.access = 'grant'
  )
  select d.customer_key
  from derived d
  where not exists (
    select 1
    from public.account_assignments r
    where r.user_id = public.effective_user_id()
      and r.customer_key = d.customer_key
      and r.access = 'revoke'
  );
$$;

comment on function public.my_customer_keys() is
  'The customer keys the effective user may see: own book, agency book, '
  'explicit grants minus revokes; every customer for inside sales '
  '(order_entry, 20261113090000).';

--------------------------------------------------------------------------
-- 3. Inside sales is read-only outside orders
--------------------------------------------------------------------------
create or replace function public.block_writes_for_read_only_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_order_entry() then
    raise exception 'read_only_role: inside sales can view % but not change it', tg_table_name
      using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;
revoke execute on function public.block_writes_for_read_only_role()
  from public, anon, authenticated;

-- The sweep. Idempotent; re-run it (or copy it into the migration) whenever a
-- new RLS-enabled table lands. A table inside sales must write goes in the
-- exempt list; everything else is read-only for them.
do $$
declare
  t record;
begin
  for t in
    select tablename
    from pg_tables
    where schemaname = 'public'
      and rowsecurity
      and tablename not in (
        -- their work
        'orders', 'order_lines', 'order_qc_results', 'order_change_events', 'order_line_snapshot',
        -- their own Claude connection and its audit
        'mcp_tokens', 'mcp_tool_calls',
        -- asking for help
        'support_requests', 'support_messages',
        -- caches and logs written on a user's behalf
        'ai_summaries', 'ai_briefs', 'ai_feedback', 'ai_batch_checks', 'ai_usage_events',
        'login_events', 'job_runs', 'impersonation', 'impersonation_events')
    order by tablename
  loop
    execute format(
      'drop trigger if exists trg_%1$s_read_only_role on public.%1$I', t.tablename);
    execute format(
      'create trigger trg_%1$s_read_only_role '
      'before insert or update or delete on public.%1$I '
      'for each row execute function public.block_writes_for_read_only_role()',
      t.tablename);
  end loop;
end;
$$;

-- Storage is outside the sweep: my_customer_keys() now holds every account
-- for inside sales, so the photo upload policy says no by itself. Restated
-- from 010_access_performance.
drop policy if exists "upload account photos" on storage.objects;
create policy "upload account photos" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'account-photos'
    and (
      (select public.is_admin())
      or (storage.foldername(name))[1] in (select public.my_customer_keys())
    )
    and not (select public.is_order_entry())
  );

-- ai_summaries is one shared row per account: the summary card its rep,
-- principal and admins see. It stays out of the sweep (ai-account-summary
-- caches under the caller's JWT, and a refused cache write still returns
-- the summary), but inside sales no longer writes it: their summaries are
-- generated, not cached. Restated from 010_access_performance.
drop policy if exists "write ai summaries" on public.ai_summaries;
create policy "write ai summaries" on public.ai_summaries
  for insert to authenticated
  with check (((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
              and not (select public.is_order_entry()));

drop policy if exists "update ai summaries" on public.ai_summaries;
create policy "update ai summaries" on public.ai_summaries
  for update to authenticated
  using (((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
         and not (select public.is_order_entry()));

--------------------------------------------------------------------------
-- 4. Free goods: the same part twice on hand-priced lines
--------------------------------------------------------------------------
alter table public.order_lines
  drop constraint if exists order_lines_order_id_price_list_id_part_id_key;

create unique index if not exists uq_order_lines_list_part
  on public.order_lines (order_id, price_list_id, part_id)
  where price_source = 'list';

comment on index public.uq_order_lines_list_part is
  'One list-priced line per part and price list. Hand-priced lines '
  '(price_source = admin) may repeat a part at different prices, e.g. a free '
  'unit next to the paid ones (20261113090000).';

--------------------------------------------------------------------------
-- 5. mcp_order_check_keys / mcp_order_apply / mcp_order_preview
--    (restated: can_price_orders for pricing and caps, is_admin for the
--    book; optional PO and its rules; repeated hand-priced parts; daily cap
--    for pricers; duplicate probe per account; last paid ignores free
--    lines; hand-pricing words; stock and part status per part)
--------------------------------------------------------------------------
create or replace function public.mcp_order_check_keys(p jsonb, p_update boolean)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $$
declare
  c_top  constant text[] := array['idempotency_key','customer_key','customer_confirmed','ship_to_key',
                                  'ship_to_confirmed','po_number','requested_ship_date',
                                  'customer_contact_key','notes','allow_duplicate','source_ref',
                                  'is_test','lines','price_override_reason','no_po_confirmed'];
  c_line constant text[] := array['part_id','qty','price_list_id','part_confirmed','expected_unit_price',
                                  'unit_price','customer_part_ref','customer_description'];
  c_price constant text[] := array['price','prices','discount_pct','effective_unit_price',
                                   'line_total','total_amount','total'];
  c_ffl  constant text[] := array['ffl_license_number','ffl_expires_on','ffl','ffl_number'];
  k text;
  l jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_input:body: the request must be a JSON object';
  end if;
  for k in select jsonb_object_keys(p) loop
    if k = any (c_price) or k = 'unit_price' then
      raise exception 'invalid_input:%: prices are set by the server from the published price list', k;
    elsif k = any (c_ffl) then
      raise exception 'invalid_input:%: an FFL is never supplied here; the licence on file is used, or the person submitting enters one in the portal', k;
    elsif not (k = any (c_top)) then
      raise exception 'invalid_input:unknown_field:%: not an order field', k;
    end if;
  end loop;
  if jsonb_typeof(p -> 'lines') = 'array' then
    for l in select jsonb_array_elements(p -> 'lines') loop
      if jsonb_typeof(l) <> 'object' then
        raise exception 'invalid_input:lines: every line must be an object {part_id, qty, part_confirmed, price_list_id?, expected_unit_price?}';
      end if;
      for k in select jsonb_object_keys(l) loop
        if k = any (c_price) then
          raise exception 'invalid_input:%: prices are set by the server from the published price list; pass the price the user expects as expected_unit_price', k;
        elsif k = any (c_ffl) then
          raise exception 'invalid_input:%: an FFL is never supplied here', k;
        elsif not (k = any (c_line)) then
          raise exception 'invalid_input:unknown_field:%: not a line field (part_id, qty, part_confirmed, price_list_id, expected_unit_price, unit_price, customer_part_ref, customer_description)', k;
        end if;
      end loop;
    end loop;
  end if;
  foreach k in array array['customer_confirmed', 'ship_to_confirmed', 'is_test', 'no_po_confirmed'] loop
    if p ? k and jsonb_typeof(p -> k) not in ('boolean', 'null') then
      raise exception 'invalid_input:%: must be true or false', k;
    end if;
  end loop;
end;
$$;

create or replace function public.mcp_order_apply(p_order_id bigint, p jsonb, p_params jsonb, p_idem_key text, p_hash text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
declare
  v_uid      uuid := auth.uid();
  v_guc      text := current_setting('app.mcp_order_write', true);
  v_admin    boolean := public.can_price_orders();   -- admin or inside sales: pricing and caps
  v_admin_list bigint := public.admin_price_list_id();
  v_max_lines int;
  v_max_units int;
  v_max_value numeric;
  v_max_day   int;
  v_window    int     := coalesce((p_params ->> 'duplicate_window_days')::int, 14);
  v_cur      public.orders;
  v_ck       text;
  v_cust     record;
  v_ship     erp.dim_ship_to;
  v_ship_key text;
  v_n        int;
  v_po       text;
  v_date     date;
  v_contact  text;
  v_notes    text;
  v_allow    boolean := false;
  v_test     boolean := false;
  v_ref      jsonb;
  v_line     jsonb;
  v_part     text;
  v_qty      numeric;
  v_plid     bigint;
  v_exp      numeric;
  v_item     record;
  v_reason   text;
  v_price    numeric;
  v_cref     text;
  v_cdesc    text;
  v_known    boolean;
  v_has_item boolean;
  v_n_admin  int := 0;
  v_priced   jsonb := '[]'::jsonb;
  v_unconf   jsonb := '[]'::jsonb;
  v_ix       int := -1;
  v_choices  jsonb;
  v_total    numeric;
  v_set      jsonb;
  v_dup      bigint;
  v_tok      uuid;
  v_id       bigint;
  k          text;
begin
  -- An admin or inside sales stages distributor POs (20261112120000) and
  -- enters the day's orders: larger caps, the daily draft count included
  -- (its own key, so raising it never raises a rep's).
  if v_admin then
    v_max_lines := coalesce((p_params ->> 'admin_max_lines')::int, 500);
    v_max_units := coalesce((p_params ->> 'admin_max_units_per_line')::int, 5000);
    v_max_value := coalesce((p_params ->> 'admin_max_order_value')::numeric, 5000000);
    v_max_day   := coalesce((p_params ->> 'admin_max_drafts_per_user_per_day')::int, 200);
  else
    v_max_lines := coalesce((p_params ->> 'max_lines')::int, 40);
    v_max_units := coalesce((p_params ->> 'max_units_per_line')::int, 200);
    v_max_value := coalesce((p_params ->> 'max_order_value')::numeric, 250000);
    v_max_day   := coalesce((p_params ->> 'max_drafts_per_user_per_day')::int, 25);
  end if;

  if p_order_id is not null then
    select * into v_cur from public.orders where id = p_order_id;
  end if;

  -- Customer, and the caller's right to draft for it (DEFINER bypasses RLS,
  -- so the read policy is restated: admin, or the account is on my book).
  -- is_admin(), not v_admin: for inside sales my_customer_keys() is every
  -- account minus an admin's revokes, and a revoke stops drafting too.
  if p ? 'customer_key' and jsonb_typeof(p -> 'customer_key') <> 'null' then
    if jsonb_typeof(p -> 'customer_key') <> 'string' or btrim(p ->> 'customer_key') = '' then
      raise exception 'invalid_input:customer_key: a customer_key string is required';
    end if;
    v_ck := btrim(p ->> 'customer_key');
  else
    v_ck := v_cur.customer_key;
  end if;
  if v_ck is null then
    raise exception 'invalid_input:customer_key: a customer_key is required';
  end if;
  select dc.customer_key, dc.customer_name, dc.customer_type into v_cust
  from erp.dim_customer dc where dc.customer_key = v_ck;
  if not found
     or not (public.is_admin() or v_ck in (select public.my_customer_keys())) then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', v_ck;
  end if;

  -- Several active accounts by this name: the user picks one.
  if (p -> 'customer_confirmed') is distinct from 'true'::jsonb then
    v_choices := public.order_same_name_accounts(v_ck);
    if jsonb_array_length(v_choices) > 1 then
      raise exception using
        message = format('customer_confirmation_required:%s: %s active accounts are named like %s; show them to the user, then send customer_confirmed=true with the one they pick',
                         v_ck, jsonb_array_length(v_choices), v_cust.customer_name),
        detail  = jsonb_build_object('error', 'customer_confirmation_required', 'choices', v_choices)::text;
    end if;
  end if;

  -- Ship-to: a given one must be an orderable ship-to of this account. With
  -- more than one orderable, the user must have picked it
  -- (ship_to_confirmed); with exactly one, it is used.
  select count(*), min(s.ship_to_key) into v_n, v_ship_key
  from erp.dim_ship_to s
  where s.customer_id = v_ck and s.address_source = 'ShipTo'
    and not coalesce(s.is_unknown_ship_to, false)
    and nullif(btrim(s.ship_to_id), '') is not null
    and upper(coalesce(s.active_flag, 'Y')) <> 'N';
  if v_n <> 1 then
    v_ship_key := null;
  end if;

  if p ? 'ship_to_key' and jsonb_typeof(p -> 'ship_to_key') <> 'null' then
    if jsonb_typeof(p -> 'ship_to_key') <> 'string' then
      raise exception 'invalid_input:ship_to_key: must be a string';
    end if;
    v_ship_key := btrim(p ->> 'ship_to_key');
    select s.* into v_ship from erp.dim_ship_to s
    where s.ship_to_key = v_ship_key
      and s.customer_id = v_ck
      and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false)
      and nullif(btrim(s.ship_to_id), '') is not null;
    if not found then
      raise exception 'ship_to_invalid:%: not one of this account''s ship-to addresses', v_ship_key;
    end if;
    if upper(coalesce(v_ship.active_flag, 'Y')) = 'N' then
      raise exception 'ship_to_invalid:%: the ship-to % is inactive in the ERP; pick another', v_ship_key, v_ship.ship_to_id;
    end if;
    if v_n > 1 and (p -> 'ship_to_confirmed') is distinct from 'true'::jsonb then
      raise exception using
        message = format('ship_to_confirmation_required:%s: %s has %s orderable ship-tos; show them (with FFL number and expiry) to the user, then send ship_to_confirmed=true with the one they pick',
                         v_ck, v_ck, v_n),
        detail  = jsonb_build_object('error', 'ship_to_confirmation_required',
                                     'choices', public.order_ship_to_choices(v_ck))::text;
    end if;
  elsif v_n > 1 then
    raise exception using
      message = format('ship_to_confirmation_required:%s: %s has %s orderable ship-tos; show them (with FFL number and expiry) to the user, then send ship_to_key and ship_to_confirmed=true',
                       v_ck, v_ck, v_n),
      detail  = jsonb_build_object('error', 'ship_to_confirmation_required',
                                   'choices', public.order_ship_to_choices(v_ck))::text;
  end if;

  if p ? 'po_number' and jsonb_typeof(p -> 'po_number') <> 'null' then
    if jsonb_typeof(p -> 'po_number') not in ('string', 'number') then
      raise exception 'invalid_input:po_number: must be text';
    end if;
    -- Blank is blank whatever the whitespace (tab, line break, no-break
    -- space), as the order loader's strip() sees it.
    v_po := nullif(btrim(p ->> 'po_number', E' \t\r\n\u00A0'), '');
    if length(v_po) > 40 then
      raise exception 'invalid_input:po_number: 40 characters at most';
    end if;
    -- PORTAL-<id> is the reference submit_order gives an order with no PO.
    -- The order's own counts as none; any other is refused, so two orders
    -- never carry the same reference.
    if v_po ~* '^PORTAL-[0-9]+$' then
      if p_order_id is not null and upper(v_po) = 'PORTAL-' || p_order_id then
        v_po := null;
      else
        raise exception 'invalid_input:po_number: % is not a customer PO; that reference is assigned by the portal to an order that has none', v_po;
      end if;
    end if;
  end if;
  -- An update never drops a customer PO already on the draft: the model
  -- resends every confirmation (no_po_confirmed too), and a PO a person
  -- added in the portal would silently go. The draft's own PORTAL-<id> is
  -- not a customer PO.
  if p_order_id is not null and v_po is null
     and nullif(btrim(v_cur.po_number, E' \t\r\n\u00A0'), '') is not null
     and upper(btrim(v_cur.po_number, E' \t\r\n\u00A0')) <> 'PORTAL-' || p_order_id then
    raise exception 'po_would_be_removed: the draft has the customer PO %; send it again as po_number (a person can clear it in the portal if it really must go)',
      btrim(v_cur.po_number, E' \t\r\n\u00A0');
  end if;
  -- A PO is asked for every time, but an informal order ("Tim wants one")
  -- has none: the user says so (no_po_confirmed) and submit_order gives the
  -- order the reference PORTAL-<id>. Never invented by the model.
  if v_po is null and (p -> 'no_po_confirmed') is distinct from 'true'::jsonb then
    raise exception 'po_confirmation_required: no customer PO number was given. Ask the user for it. Only if they say the customer gave none, send no_po_confirmed=true; the order is then given the reference PORTAL-<order id> when it is submitted. Never invent one';
  end if;

  if p ? 'requested_ship_date' and jsonb_typeof(p -> 'requested_ship_date') <> 'null' then
    begin
      if jsonb_typeof(p -> 'requested_ship_date') <> 'string'
         or (p ->> 'requested_ship_date') !~ '^\d{4}-\d{2}-\d{2}$' then
        raise exception 'bad';
      end if;
      v_date := (p ->> 'requested_ship_date')::date;
    exception when others then
      raise exception 'invalid_input:requested_ship_date: use YYYY-MM-DD';
    end;
    if v_date < current_date then
      raise exception 'invalid_input:requested_ship_date: % is in the past', v_date;
    end if;
  end if;

  if p ? 'customer_contact_key' and jsonb_typeof(p -> 'customer_contact_key') <> 'null' then
    v_contact := btrim(p ->> 'customer_contact_key');
    if jsonb_typeof(p -> 'customer_contact_key') <> 'string'
       or not exists (select 1 from erp.dim_customer_contact e
                      where e.customer_contact_key = v_contact and e.customer_key = v_ck
                        and coalesce(e.contact_active_flag, 'Y') = 'Y') then
      raise exception 'invalid_input:customer_contact_key: not an active contact on this account';
    end if;
  end if;

  if p ? 'notes' and jsonb_typeof(p -> 'notes') <> 'null' then
    if jsonb_typeof(p -> 'notes') <> 'string' then
      raise exception 'invalid_input:notes: must be text';
    end if;
    v_notes := nullif(btrim(p ->> 'notes'), '');
    if length(v_notes) > 1000 then
      raise exception 'invalid_input:notes: 1000 characters at most';
    end if;
  end if;

  if p ? 'price_override_reason' and jsonb_typeof(p -> 'price_override_reason') <> 'null' then
    if not v_admin then
      raise exception 'price_not_allowed:price_override_reason: only an admin or inside sales can price an order by hand; the server prices it from the published list';
    end if;
    if jsonb_typeof(p -> 'price_override_reason') <> 'string' then
      raise exception 'invalid_input:price_override_reason: must be text';
    end if;
    v_reason := nullif(btrim(p ->> 'price_override_reason'), '');
    if length(v_reason) > 500 then
      raise exception 'invalid_input:price_override_reason: 500 characters at most';
    end if;
  end if;

  if p ? 'allow_duplicate' and jsonb_typeof(p -> 'allow_duplicate') <> 'null' then
    if jsonb_typeof(p -> 'allow_duplicate') <> 'boolean' then
      raise exception 'invalid_input:allow_duplicate: must be true or false';
    end if;
    v_allow := (p -> 'allow_duplicate')::boolean;
  end if;

  -- Once a test, always a test: an update can mark a draft as a test but
  -- never clear it (omitted or false keeps it), so a real order needs a new
  -- draft, as the test_order refusal says.
  v_test := coalesce(v_cur.is_test, false)
            or coalesce((p -> 'is_test') = 'true'::jsonb, false);

  if p ? 'source_ref' and jsonb_typeof(p -> 'source_ref') <> 'null' then
    v_ref := p -> 'source_ref';
    if jsonb_typeof(v_ref) <> 'object' or v_ref ->> 'kind' is distinct from 'email' then
      raise exception 'invalid_input:source_ref: must be {kind:"email", sender, subject, received_at, excerpt}';
    end if;
    for k in select jsonb_object_keys(v_ref) loop
      if not (k = any (array['kind','sender','subject','received_at','excerpt','message_id']))
         or jsonb_typeof(v_ref -> k) not in ('string', 'null') then
        raise exception 'invalid_input:source_ref: field % is not allowed or not text', k;
      end if;
    end loop;
    if length(v_ref ->> 'excerpt') > 4000 then
      raise exception 'invalid_input:source_ref: excerpt is 4000 characters at most';
    end if;
    if greatest(length(v_ref ->> 'sender'), length(v_ref ->> 'subject'),
                length(v_ref ->> 'received_at'), length(v_ref ->> 'message_id')) > 500 then
      raise exception 'invalid_input:source_ref: sender, subject, received_at and message_id are 500 characters at most';
    end if;
  end if;

  -- Lines: price every one on the server.
  if jsonb_typeof(p -> 'lines') is distinct from 'array' or jsonb_array_length(p -> 'lines') = 0 then
    raise exception 'invalid_input:lines: at least one line {part_id, qty, part_confirmed} is required';
  end if;
  if jsonb_array_length(p -> 'lines') > v_max_lines then
    raise exception 'too_many_lines: % lines; % at most', jsonb_array_length(p -> 'lines'), v_max_lines;
  end if;

  for v_line in select jsonb_array_elements(p -> 'lines') loop
    v_ix := v_ix + 1;
    if jsonb_typeof(v_line -> 'part_id') is distinct from 'string' or btrim(v_line ->> 'part_id') = '' then
      raise exception 'invalid_input:part_id: every line needs a part_id';
    end if;
    v_part := btrim(v_line ->> 'part_id');
    if length(v_part) > 100 then
      raise exception 'invalid_input:part_id: 100 characters at most';
    end if;
    if jsonb_typeof(v_line -> 'qty') is distinct from 'number' then
      raise exception 'invalid_input:qty: line % needs a whole-number qty', v_part;
    end if;
    v_qty := (v_line ->> 'qty')::numeric;
    if v_qty <> trunc(v_qty) then
      raise exception 'invalid_input:qty: line % needs a whole-number qty', v_part;
    end if;
    if v_qty < 1 or v_qty > v_max_units then
      raise exception 'qty_out_of_range:%: qty % is outside 1-%', v_part, v_qty, v_max_units;
    end if;
    v_plid := null;
    if v_line ? 'price_list_id' and jsonb_typeof(v_line -> 'price_list_id') <> 'null' then
      if jsonb_typeof(v_line -> 'price_list_id') <> 'number'
         or (v_line ->> 'price_list_id')::numeric <> trunc((v_line ->> 'price_list_id')::numeric) then
        raise exception 'invalid_input:price_list_id: line % has a price_list_id that is not a whole number', v_part;
      end if;
      v_plid := (v_line ->> 'price_list_id')::bigint;
    end if;
    v_exp := null;
    if v_line ? 'expected_unit_price' and jsonb_typeof(v_line -> 'expected_unit_price') <> 'null' then
      if jsonb_typeof(v_line -> 'expected_unit_price') <> 'number'
         or (v_line ->> 'expected_unit_price')::numeric <= 0
         or (v_line ->> 'expected_unit_price')::numeric >= 10000000000 then
        raise exception 'invalid_input:expected_unit_price: line % needs a positive number (the unit price the user said)', v_part;
      end if;
      v_exp := round((v_line ->> 'expected_unit_price')::numeric, 2);
    end if;
    if v_line ? 'part_confirmed' and jsonb_typeof(v_line -> 'part_confirmed') not in ('boolean', 'null') then
      raise exception 'invalid_input:part_confirmed: line % must send true or false', v_part;
    end if;

    -- Admin pricing (20261112120000): the PO's price, and the PO's own item
    -- number and description for the reviewer.
    v_price := null;
    if v_line ? 'unit_price' and jsonb_typeof(v_line -> 'unit_price') <> 'null' then
      if not v_admin then
        raise exception 'price_not_allowed:%: only an admin or inside sales can set a price; the server prices the order from the published list (send the user''s price as expected_unit_price)', v_part;
      end if;
      if jsonb_typeof(v_line -> 'unit_price') <> 'number' then
        raise exception 'invalid_input:unit_price: line % needs a number', v_part;
      end if;
      v_price := (v_line ->> 'unit_price')::numeric;
      if v_price < 0 or v_price > 1000000 or v_price <> round(v_price, 2) then
        raise exception 'invalid_input:unit_price: line % has %; use 0-1,000,000 with at most 2 decimals', v_part, v_price;
      end if;
    end if;
    v_cref := null;
    if v_line ? 'customer_part_ref' and jsonb_typeof(v_line -> 'customer_part_ref') <> 'null' then
      if jsonb_typeof(v_line -> 'customer_part_ref') not in ('string', 'number') then
        raise exception 'invalid_input:customer_part_ref: line % must be text', v_part;
      end if;
      v_cref := nullif(btrim(v_line ->> 'customer_part_ref'), '');
      if length(v_cref) > 100 then
        raise exception 'invalid_input:customer_part_ref: 100 characters at most';
      end if;
    end if;
    v_cdesc := null;
    if v_line ? 'customer_description' and jsonb_typeof(v_line -> 'customer_description') <> 'null' then
      if jsonb_typeof(v_line -> 'customer_description') <> 'string' then
        raise exception 'invalid_input:customer_description: line % must be text', v_part;
      end if;
      v_cdesc := left(nullif(btrim(v_line ->> 'customer_description'), ''), 300);
    end if;

    v_known := exists (select 1 from erp.dim_part dp where dp.part_id = v_part);

    if exists (select 1 from erp.dim_part dp where dp.part_id = v_part and dp.is_kit_flag = 'Y') then
      raise exception 'kit_not_supported:%: kits cannot be ordered here', v_part;
    end if;

    v_has_item := false;
    if v_known then
      select l.id as list_id, l.name as list_name, i.id as item_id, i.unit_price, i.description
        into v_item
      from public.effective_price_lists(v_cust.customer_type) l
      join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_part
      where (v_plid is null and not l.is_special) or l.id = v_plid
      order by l.effective_from desc, l.id
      limit 1;
      v_has_item := found;
    end if;

    if (v_line -> 'part_confirmed') is distinct from 'true'::jsonb then
      v_unconf := v_unconf || jsonb_build_object(
        'line', v_ix, 'part_id', v_part,
        'choices', public.order_part_choices(v_cust.customer_type, v_part, 6));
    end if;

    if v_has_item and (v_price is null or v_price = v_item.unit_price) then
      -- The published price. The ERP part master's description first (the
      -- uploaded list's column is only a fallback: the Buy Group sheet
      -- carried the UPC there).
      v_priced := v_priced || jsonb_build_object(
        'part_id', v_part, 'qty', v_qty::int, 'price_list_id', v_item.list_id,
        'item_id', v_item.item_id, 'unit_price', v_item.unit_price,
        'expected_unit_price', v_exp,
        'description', coalesce(
           (select dp.part_description from erp.dim_part dp
             where dp.part_id = v_part and nullif(btrim(dp.part_description), '') is not null
             order by coalesce(dp.is_unknown_part, false), dp.part_key limit 1),
           v_item.description, v_cdesc),
        'price_source', 'list', 'list_unit_price', v_item.unit_price,
        'customer_part_ref', v_cref, 'customer_description', v_cdesc, 'part_unresolved', false);
    elsif v_price is null then
      if not v_known and v_admin then
        raise exception 'part_unknown:%: no ERP part has this id. Resolve it with resolve_order_parts, or send unit_price to stage it unmatched', v_part;
      end if;
      if v_plid is null then
        raise exception 'part_not_orderable:%: not on this account''s price list%', v_part,
          case when v_admin then '; send unit_price to order it off list' else '' end;
      end if;
      raise exception 'part_not_orderable:%: not on price list % (or that list is not effective for this account)', v_part, v_plid;
    else
      -- Admin price: off list, a different price, or an unmatched item.
      if v_admin_list is null then
        raise exception 'admin_price_list: the reserved admin price list is missing';
      end if;
      v_n_admin := v_n_admin + 1;
      v_priced := v_priced || jsonb_build_object(
        'part_id', v_part, 'qty', v_qty::int, 'price_list_id', v_admin_list,
        'item_id', null, 'unit_price', v_price,
        'expected_unit_price', v_exp,
        'description', coalesce(
           (select dp.part_description from erp.dim_part dp
             where dp.part_id = v_part and nullif(btrim(dp.part_description), '') is not null
             order by coalesce(dp.is_unknown_part, false), dp.part_key limit 1),
           case when v_has_item then v_item.description end, v_cdesc),
        'price_source', 'admin',
        'list_unit_price', case when v_has_item then v_item.unit_price
                                else (select i.unit_price
                                        from public.effective_price_lists(v_cust.customer_type) l
                                        join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_part
                                       where not l.is_special
                                       order by l.effective_from desc, l.id limit 1) end,
        'customer_part_ref', coalesce(v_cref, case when not v_known then v_part end),
        'customer_description', v_cdesc, 'part_unresolved', not v_known);
    end if;

    if (select count(*) from jsonb_array_elements(v_priced) e
         where e ->> 'part_id' = v_part
           and (e ->> 'price_list_id')::bigint = (v_priced -> -1 ->> 'price_list_id')::bigint
           -- Hand-priced lines may repeat a part at DIFFERENT prices (10 paid
           -- and 1 free); the same part at the same price is one line.
           and (v_priced -> -1 ->> 'price_source' = 'list'
                or (e ->> 'unit_price')::numeric = (v_priced -> -1 ->> 'unit_price')::numeric)) > 1 then
      raise exception 'invalid_input:duplicate_line:%: the part appears twice at the same price; send one line with the total qty', v_part;
    end if;
  end loop;

  if jsonb_array_length(v_unconf) > 0 then
    raise exception using
      message = format('part_confirmation_required:%s: %s line(s) were not confirmed by the user; show the choices, then send part_confirmed=true on every line',
                       v_unconf -> 0 ->> 'part_id', jsonb_array_length(v_unconf)),
      detail  = jsonb_build_object('error', 'part_confirmation_required', 'lines', v_unconf)::text;
  end if;

  if v_n_admin > 0 and v_reason is null then
    raise exception 'invalid_input:price_override_reason: % line(s) are hand-priced or unmatched; say why in price_override_reason (e.g. "excess stock buy-in, approved by ...")', v_n_admin;
  end if;
  if v_n_admin = 0 then
    v_reason := null;
  end if;

  -- The same promo formula as submit_order (which re-runs it authoritatively).
  -- The admin list has no promo, so admin lines keep their price.
  with x as (
    select * from jsonb_to_recordset(v_priced)
      as (part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
          expected_unit_price numeric, description text,
          price_source text, list_unit_price numeric, customer_part_ref text, customer_description text,
          part_unresolved boolean)
  ),
  pct as (
    select x.price_list_id,
           case when pl.promo_buy_qty is null then 0::numeric
                else round(100 * (floor(sum(x.qty)::numeric / (pl.promo_buy_qty + pl.promo_get_qty))
                                  * pl.promo_get_qty) / sum(x.qty)::numeric, 4)
           end as discount_pct
    from x join public.price_lists pl on pl.id = x.price_list_id
    group by x.price_list_id, pl.promo_buy_qty, pl.promo_get_qty
  )
  select jsonb_agg(to_jsonb(x) || jsonb_build_object(
           'discount_pct', pct.discount_pct,
           'effective_unit_price', round(x.unit_price * (1 - pct.discount_pct / 100), 2))),
         sum(x.qty * round(x.unit_price * (1 - pct.discount_pct / 100), 2)),
         (select jsonb_agg(jsonb_build_array(s.part_id, s.q) order by s.part_id)
            from (select x2.part_id, sum(x2.qty) as q from x x2 group by x2.part_id) s)
    into v_priced, v_total, v_set
  from x join pct using (price_list_id);

  if v_total > v_max_value then
    raise exception 'order_value_cap: the order totals %; drafts over MCP are capped at %', v_total, v_max_value;
  end if;

  -- One draft write per user, and per account, at a time: the cap and the
  -- duplicate probe below are check-then-insert, and models do issue
  -- parallel tool calls; the probe is per account, so two people drafting
  -- for one account queue too. Always user first, then account.
  perform pg_advisory_xact_lock(hashtextextended('mcp_order_apply|' || v_uid::text, 0));
  perform pg_advisory_xact_lock(hashtextextended('mcp_order_apply|account|' || v_ck, 0));

  if p_order_id is null then
    select count(*) into v_n
    from public.orders o
    where o.created_by = v_uid and o.source <> 'portal'
      and o.created_at >= date_trunc('day', now());
    if v_n >= v_max_day then
      raise exception 'daily_draft_cap: % drafts today; % per day at most', v_n, v_max_day;
    end if;
  end if;

  -- Duplicate block: a model that retries usually invents a new key. Per
  -- account, not per drafter: the rep and inside sales (or two inside sales
  -- users) can both receive the same PO. Whoever may draft for the account
  -- reads its orders, so naming the other order leaks nothing.
  if not v_allow then
    select o.id into v_dup
    from public.orders o
    where o.customer_key = v_ck
      and o.status <> 'cancelled'
      and o.created_at >= now() - make_interval(days => v_window)
      and o.id is distinct from p_order_id
      and (   (v_po is not null and upper(btrim(o.po_number, E' \t\r\n\u00A0')) = upper(v_po))
           or v_set = (select jsonb_agg(jsonb_build_array(s.part_id, s.q) order by s.part_id)
                       from (select l.part_id, sum(l.qty) as q from public.order_lines l
                             where l.order_id = o.id group by l.part_id) s))
    order by o.created_at desc, o.id desc
    limit 1;
    if v_dup is not null then
      raise exception 'possible_duplicate:%: order % for this account has the same PO or the same lines; ask the user, then send allow_duplicate=true to draft anyway', v_dup, v_dup;
    end if;
  end if;

  perform set_config('app.mcp_order_write', 'on', true);

  if p_order_id is null then
    if (auth.jwt() -> 'app_metadata' ->> 'mcp_token_id')
         ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      v_tok := (auth.jwt() -> 'app_metadata' ->> 'mcp_token_id')::uuid;
    end if;
    begin
      insert into public.orders (
        user_id, created_by, customer_key, customer_name, customer_type, status, source,
        po_number, requested_ship_date, notes, ship_to_key, customer_contact_key,
        source_ref, mcp_token_id, client_request_id, request_hash, is_test, price_override_reason)
      values (
        v_uid, v_uid, v_ck, coalesce(v_cust.customer_name, ''), v_cust.customer_type, 'draft', 'mcp',
        v_po, v_date, v_notes, v_ship_key, v_contact,
        v_ref, v_tok, p_idem_key, p_hash, v_test, v_reason)
      returning id into v_id;
    exception when unique_violation then
      raise exception 'idempotency_conflict: a request with this idempotency_key is already being processed; retry';
    end;
  else
    v_id := p_order_id;
    update public.orders
    set customer_key         = v_ck,
        customer_name        = coalesce(v_cust.customer_name, ''),
        customer_type        = v_cust.customer_type,
        po_number            = v_po,
        requested_ship_date  = v_date,
        notes                = v_notes,
        ship_to_key          = v_ship_key,
        customer_contact_key = v_contact,
        source_ref           = coalesce(v_ref, source_ref),
        is_test              = v_test,
        price_override_reason = v_reason
    where id = v_id;
    delete from public.order_lines where order_id = v_id;
  end if;

  insert into public.order_lines (order_id, price_list_id, price_list_item_id, part_id, description,
                                  qty, unit_price, discount_pct, effective_unit_price,
                                  mcp_expected_unit_price,
                                  price_source, list_unit_price, customer_part_ref, customer_description,
                                  part_unresolved)
  select v_id, x.price_list_id, x.item_id, x.part_id, x.description,
         x.qty, x.unit_price, x.discount_pct, x.effective_unit_price, x.expected_unit_price,
         x.price_source, x.list_unit_price, x.customer_part_ref, x.customer_description,
         coalesce(x.part_unresolved, false)
  from jsonb_to_recordset(v_priced)
    as x(part_id text, qty int, price_list_id bigint, item_id bigint, unit_price numeric,
         description text, discount_pct numeric, effective_unit_price numeric,
         expected_unit_price numeric,
         price_source text, list_unit_price numeric, customer_part_ref text, customer_description text,
         part_unresolved boolean);

  -- For the reviewer: what this customer last paid for each part, and
  -- whether the PO's description looks like the part it was matched to.
  -- A free unit ($0, or 100% off) is not a price paid; ties break on the
  -- ERP order and line so the answer does not depend on scan order.
  update public.order_lines l
  set last_paid_price = h.net_price,
      last_paid_date  = h.order_date
  from (
    select distinct on (p.part_id) p.part_id,
           round(f.unit_price * (1 - coalesce(f.trade_discount_pct, 0) / 100), 2) as net_price, f.order_date
    from erp.fact_order_line f
    join erp.dim_part p on p.part_key = f.part_key
    where f.customer_key = v_ck and f.unit_price > 0
      and coalesce(f.trade_discount_pct, 0) < 100
      and p.part_id in (select ol.part_id from public.order_lines ol where ol.order_id = v_id)
    order by p.part_id, f.order_date desc nulls last, f.order_id desc, f.line_num desc
  ) h
  where l.order_id = v_id and l.part_id = h.part_id;

  update public.order_lines l
  set description_mismatch = coalesce(public.order_desc_score(
        public.order_desc_tokens(l.customer_description),
        public.order_desc_tokens(public.order_part_doc(l.part_id))), 1) < 0.3
  where l.order_id = v_id and l.customer_description is not null and not l.part_unresolved;

  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);
  return v_id;
end;
$$;

create or replace function public.mcp_order_preview(p_order_id bigint, p_replayed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
declare
  c_ok    constant text := '__mcp_dry_run_ok__';
  o       public.orders;
  v_ok    boolean := false;
  v_err   text;
  v_lines jsonb;
  v_total numeric;
  v_ship  erp.dim_ship_to;
  v_has_ship boolean := false;
  v_cust  record;
  v_needs boolean;
  v_cur   boolean := false;
  v_onf   boolean := false;
  v_contact jsonb;
  v_warn  text[] := '{}';
  v_alerts jsonb := '[]'::jsonb;
  v_head  text[] := '{}';
  v_adm   record;
  v_n_ok  int;
  v_dry   text;
  r       record;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then
    raise exception 'order_not_found: order % not found', p_order_id;
  end if;

  if o.status = 'draft' then
    -- submit_order refuses an MCP session unless this dry-run flag is on.
    -- Set OUTSIDE the subtransaction (so the sentinel rollback cannot undo
    -- it) and put back right after it.
    v_dry := current_setting('app.mcp_dry_run', true);
    perform set_config('app.mcp_dry_run', 'on', true);
    begin
      perform public.submit_order(p_order_id, true);
      select jsonb_agg(jsonb_build_object(
               'part_id', l.part_id, 'description', l.description, 'qty', l.qty,
               'price_list_id', l.price_list_id, 'price_list_name', pl.name,
               'unit_price', l.unit_price, 'discount_pct', l.discount_pct,
               'effective_unit_price', l.effective_unit_price, 'line_total', l.line_total,
               'expected_unit_price', l.mcp_expected_unit_price,
               'price_source', l.price_source, 'list_unit_price', l.list_unit_price,
               'customer_part_ref', l.customer_part_ref, 'customer_description', l.customer_description,
               'part_unresolved', l.part_unresolved,
               'last_paid_price', l.last_paid_price, 'last_paid_date', l.last_paid_date,
               'description_mismatch', l.description_mismatch)
               order by l.id),
             sum(l.line_total)
        into v_lines, v_total
      from public.order_lines l join public.price_lists pl on pl.id = l.price_list_id
      where l.order_id = p_order_id;
      raise exception using message = c_ok;
    exception when others then
      if sqlerrm = c_ok then
        v_ok := true;
      else
        v_ok := false;
        v_err := sqlerrm;
        v_lines := null;
        v_total := null;
      end if;
    end;
    perform set_config('app.mcp_dry_run', coalesce(v_dry, ''), true);
  else
    v_err := format('order %s is %s; only drafts can be submitted', p_order_id, o.status);
  end if;

  if v_lines is null then
    select jsonb_agg(jsonb_build_object(
             'part_id', l.part_id, 'description', l.description, 'qty', l.qty,
             'price_list_id', l.price_list_id, 'price_list_name', pl.name,
             'unit_price', l.unit_price, 'discount_pct', l.discount_pct,
             'effective_unit_price', l.effective_unit_price, 'line_total', l.line_total,
             'expected_unit_price', l.mcp_expected_unit_price,
               'price_source', l.price_source, 'list_unit_price', l.list_unit_price,
               'customer_part_ref', l.customer_part_ref, 'customer_description', l.customer_description,
               'part_unresolved', l.part_unresolved,
               'last_paid_price', l.last_paid_price, 'last_paid_date', l.last_paid_date,
               'description_mismatch', l.description_mismatch)
             order by l.id),
           sum(l.line_total)
      into v_lines, v_total
    from public.order_lines l join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = p_order_id;
  end if;

  -- Stock never blocks; each line carries its part's available-to-sell
  -- (ats_qty), and the warning below compares it per part.
  select coalesce(jsonb_agg(x.line || jsonb_build_object('ats_qty', x.ats) order by x.ord), '[]'::jsonb)
    into v_lines
  from (
    select e.line, e.ord,
           (select sum(a.available_to_sell_qty)
              from erp.fact_available_to_sell a
              join erp.dim_part dp on dp.part_key = a.part_key
             where dp.part_id = e.line ->> 'part_id') as ats
    from jsonb_array_elements(coalesce(v_lines, '[]'::jsonb)) with ordinality as e(line, ord)
  ) x;

  -- Hand pricing and unmatched parts (20261112120000): these lead the
  -- warnings, in capitals, and carry alerts of their own. The alert type
  -- and the admin_* keys keep their names; the words say "hand-priced".
  select count(*) as n,
         count(*) filter (where l.price_source = 'admin') as n_admin,
         count(*) filter (where l.price_source = 'admin' and l.list_unit_price is null and not l.part_unresolved) as n_off,
         count(*) filter (where l.price_source = 'admin' and l.list_unit_price is not null) as n_diff,
         count(*) filter (where l.part_unresolved) as n_unres,
         coalesce(sum(l.qty * l.unit_price) filter (where l.price_source = 'admin'), 0) as admin_value,
         coalesce(sum(l.qty * (l.list_unit_price - l.unit_price))
                    filter (where l.price_source = 'admin' and l.list_unit_price is not null), 0) as under_list,
         string_agg(coalesce(l.customer_part_ref, l.part_id), ', ' order by l.id)
           filter (where l.part_unresolved) as unres_refs,
         count(*) filter (where l.description_mismatch) as n_desc,
         string_agg(format('%s matched to %s', coalesce(l.customer_part_ref, l.part_id), l.part_id), '; ' order by l.id)
           filter (where l.description_mismatch) as desc_refs,
         count(*) filter (where l.price_source = 'admin' and l.last_paid_price is not null
                            and l.last_paid_price <> l.unit_price) as n_vs_paid
    into v_adm
  from public.order_lines l where l.order_id = p_order_id;
  if v_adm.n_unres > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'unmatched_parts', 'severity', 'hard',
      'count', v_adm.n_unres, 'refs', v_adm.unres_refs,
      'message', 'Lines that match no ERP part: the order cannot be submitted until each is corrected or removed.');
    v_head := v_head || format(
      'UNMATCHED PARTS: %s line(s) match no part in the ERP (%s). They are staged as sent; the order '
      'cannot be submitted until each is corrected (update_order_draft with the right part_id) or removed.',
      v_adm.n_unres, left(v_adm.unres_refs, 400));
  end if;
  if v_adm.n_desc > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'description_check', 'severity', 'warning',
      'count', v_adm.n_desc, 'lines', v_adm.desc_refs);
    v_head := v_head || format(
      'DESCRIPTION CHECK: on %s line(s) the PO''s description does not look like the part it was matched to '
      '(%s). Likely a typo in the PO''s item number: confirm each with the user.',
      v_adm.n_desc, left(v_adm.desc_refs, 600));
  end if;
  if v_adm.n_admin > 0 then
    v_alerts := v_alerts || jsonb_build_object('type', 'admin_pricing', 'severity', 'warning',
      'lines', v_adm.n_admin, 'off_list', v_adm.n_off, 'differs_from_list', v_adm.n_diff,
      'unmatched', v_adm.n_unres, 'admin_value', v_adm.admin_value, 'below_list', v_adm.under_list,
      'reason', o.price_override_reason,
      'message', 'Hand-priced lines: an admin, or inside sales on their own order, submits it after reviewing each flagged line.');
    v_head := v_head || format(
      'HAND PRICING - CHECK EVERY FLAGGED LINE: %s of %s lines are not at the published price '
      '(%s on no price list for this account, %s priced differently from the list, %s unmatched). '
      'Hand-priced value %s; %s below list on the lines that have a list price. Reason: "%s". '
      'An admin, or inside sales on their own order, submits it after reviewing each flagged line.',
      v_adm.n_admin, v_adm.n, v_adm.n_off, v_adm.n_diff, v_adm.n_unres,
      '$' || to_char(v_adm.admin_value, 'FM999,999,990.00'), '$' || to_char(v_adm.under_list, 'FM999,999,990.00'),
      coalesce(o.price_override_reason, 'none given'));
    if v_adm.n_vs_paid > 0 then
      v_head := v_head || format(
        'PRICE VS LAST PAID: %s hand-priced line(s) differ from what this customer last paid for the part.',
        v_adm.n_vs_paid);
    end if;
  end if;

  -- No customer PO: blank after any whitespace, or a draft still carrying
  -- its own PORTAL-<id> (given at a submit, then recalled). The "No
  -- customer PO" prefix is what the portal looks for.
  if nullif(btrim(o.po_number, E' \t\r\n\u00A0'), '') is null
     or (o.status = 'draft' and upper(btrim(o.po_number, E' \t\r\n\u00A0')) = 'PORTAL-' || o.id) then
    v_alerts := v_alerts || jsonb_build_object('type', 'no_customer_po', 'severity', 'warning',
      'assigned_reference', 'PORTAL-' || o.id,
      'message', 'No customer PO number: the order is given the reference PORTAL-' || o.id || ' when it is submitted. Add the real PO if the customer has one.');
    v_warn := v_warn || format('No customer PO: it will be submitted as PORTAL-%s. Ask the customer for a PO number if they use them.', o.id);
  end if;

  if o.is_test then
    v_alerts := v_alerts || jsonb_build_object('type', 'test_order', 'severity', 'hard',
      'message', 'Test draft: it is labelled TEST in the portal and can never be submitted.');
    v_warn := v_warn || 'TEST ORDER: this draft was made as a test and cannot be submitted.'::text;
  end if;

  -- The user's expected price is checked per line.
  for r in
    select e.line ->> 'part_id' as part_id,
           (e.line ->> 'unit_price')::numeric as list_price,
           (e.line ->> 'effective_unit_price')::numeric as eff_price,
           (e.line ->> 'expected_unit_price')::numeric as expected,
           e.line ->> 'price_list_name' as list_name
    from jsonb_array_elements(v_lines) as e(line)
    where not coalesce((e.line ->> 'part_unresolved')::boolean, false)
  loop
    if r.expected is not null and r.expected is distinct from r.eff_price then
      v_alerts := v_alerts || jsonb_build_object(
        'type', 'price_mismatch', 'severity', 'warning', 'part_id', r.part_id,
        'expected', r.expected, 'list', r.list_price, 'effective', r.eff_price,
        'difference', r.eff_price - r.expected, 'price_list', r.list_name);
      v_warn := v_warn || format('Price: the user expected $%s for %s; %s prices it at $%s (%s$%s each). The draft keeps the list price: a different price is agreed outside the portal.',
                                 to_char(r.expected, 'FM999,999,990.00'), r.part_id, r.list_name,
                                 to_char(r.eff_price, 'FM999,999,990.00'),
                                 case when r.eff_price > r.expected then '+' else '-' end,
                                 to_char(abs(r.eff_price - r.expected), 'FM999,999,990.00'));
    end if;
  end loop;

  -- Stock and part status per PART, over the order's total qty, once each:
  -- free goods put one part on two lines (5 available, 5 paid + 1 free is
  -- short).
  for r in
    select g.part_id, g.qty, g.ats,
           (select min(dp.status) from erp.dim_part dp where dp.part_id = g.part_id) as status
    from (select e.line ->> 'part_id' as part_id,
                 sum((e.line ->> 'qty')::int) as qty,
                 max((e.line ->> 'ats_qty')::numeric) as ats,
                 min(e.ord) as ord
            from jsonb_array_elements(v_lines) with ordinality as e(line, ord)
           where not coalesce((e.line ->> 'part_unresolved')::boolean, false)
           group by e.line ->> 'part_id') g
    order by g.ord
  loop
    if r.ats is null or r.ats < r.qty then
      v_warn := v_warn || format('Stock: %s has %s available to sell; %s ordered in all. Stock does not block the order.',
                                 r.part_id, coalesce(trim_scale(r.ats)::text, 'no'), r.qty);
    end if;
    if r.status is distinct from 'A' then
      v_warn := v_warn || format('%s is not an active part in the ERP (status %s).', r.part_id, coalesce(r.status, 'unknown'));
    end if;
  end loop;

  select dc.customer_name, dc.credit_status, dc.active_flag into v_cust
  from erp.dim_customer dc where dc.customer_key = o.customer_key;
  if upper(coalesce(v_cust.active_flag, 'Y')) = 'N' then
    v_warn := v_warn || 'The account is inactive in the ERP.'::text;
  end if;
  if upper(coalesce(v_cust.credit_status, '')) like 'HOLD%' then
    v_warn := v_warn || format('The account is on credit hold in the ERP (%s).', v_cust.credit_status);
  end if;

  v_needs := exists (select 1 from public.order_lines l
                     where l.order_id = p_order_id and public.part_requires_ffl(l.part_id));

  -- DEFINER: read only this account's own ship-to and contact, whatever key
  -- the row carries (a portal PATCH could point them at another account).
  if o.ship_to_key is not null then
    select s.* into v_ship from erp.dim_ship_to s
    where s.ship_to_key = o.ship_to_key
      and s.customer_id = o.customer_key
      and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false);
    v_has_ship := found;
  end if;
  if v_has_ship then
    v_onf := length(public.ffl_normalize(v_ship.ffl_license_number)) = 15;
    v_cur := public.ffl_on_file_current(v_ship.ffl_license_number, v_ship.ffl_expiration_raw);
  else
    select count(*) into v_n_ok
    from erp.dim_ship_to s
    where s.customer_id = o.customer_key and s.address_source = 'ShipTo'
      and not coalesce(s.is_unknown_ship_to, false)
      and nullif(btrim(s.ship_to_id), '') is not null
      and upper(coalesce(s.active_flag, 'Y')) <> 'N';
    v_warn := v_warn || format('No ship-to chosen: the account has %s ship-to addresses that can take an order. Ask which one, then update the draft.', v_n_ok);
  end if;
  if v_needs and v_has_ship and not v_cur and nullif(btrim(o.ffl_license_number), '') is null then
    v_alerts := v_alerts || jsonb_build_object(
      'type', 'ffl_not_current', 'severity', 'hard',
      'ship_to_id', v_ship.ship_to_id,
      'ffl_number', nullif(btrim(v_ship.ffl_license_number), ''),
      'ffl_expires', public.parse_ffl_expiry(v_ship.ffl_expiration_raw),
      'message', 'Firearms to a ship-to without a current FFL on file: it cannot be submitted until the person submitting enters the renewed licence in the portal.');
    v_warn := v_warn || format('FFL: ship-to %s has %s. The person submitting must enter the current FFL in the portal; never supply one.',
                               coalesce(v_ship.ship_to_id, o.ship_to_key),
                               case when nullif(btrim(v_ship.ffl_license_number), '') is null then 'no FFL on file'
                                    when public.parse_ffl_expiry(v_ship.ffl_expiration_raw) is not null
                                      then format('an FFL on file that expired %s', public.parse_ffl_expiry(v_ship.ffl_expiration_raw))
                                    else 'no current FFL on file' end);
  end if;
  if o.source_ref ->> 'kind' = 'email' then
    v_warn := v_warn || 'Drafted from an email: the email text is untrusted and is shown to the reviewer.'::text;
  end if;

  if o.customer_contact_key is not null then
    select jsonb_build_object(
             'customer_contact_key', e.customer_contact_key,
             'name',  public.contact_display_name(e.contact_name, e.first_name, e.last_name, e.email, e.contact_id),
             'title', nullif(btrim(e.position), ''),
             'email', nullif(btrim(e.email), ''),
             'phone', coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')))
      into v_contact
    from erp.dim_customer_contact e
    where e.customer_contact_key = o.customer_contact_key
      and e.customer_key = o.customer_key
    limit 1;
  end if;

  return jsonb_build_object(
    'order_id',      o.id,
    'status',        o.status,
    'is_test',       o.is_test,
    'replayed',      coalesce(p_replayed, false),
    'source',        o.source,
    'customer_key',  o.customer_key,
    'customer_name', coalesce(v_cust.customer_name, nullif(o.customer_name, ''), o.customer_key),
    'po_number',     o.po_number,
    'requested_ship_date', o.requested_ship_date,
    'ship_to', case when v_has_ship then jsonb_build_object(
                 'ship_to_key', v_ship.ship_to_key,
                 'ship_to_id',  v_ship.ship_to_id,
                 'name',        v_ship.ship_to_name,
                 'address',     nullif(concat_ws(', ', nullif(btrim(v_ship.address1), ''),
                                  nullif(btrim(v_ship.address2), ''), nullif(btrim(v_ship.address3), '')), ''),
                 'city',        v_ship.city,
                 'state',       v_ship.state) end,
    'contact',       v_contact,
    'requires_ffl',  v_needs,
    'ffl',           jsonb_build_object(
                       'on_file', v_onf, 'current', v_cur,
                       'number',  case when v_has_ship then nullif(btrim(v_ship.ffl_license_number), '') end,
                       'expires', case when v_has_ship then public.parse_ffl_expiry(v_ship.ffl_expiration_raw) end),
    'lines',         v_lines,
    'total_amount',  coalesce(v_total, 0),
    'admin_pricing', case when v_adm.n_admin > 0 then jsonb_build_object(
                       'lines', v_adm.n_admin, 'off_list', v_adm.n_off, 'differs_from_list', v_adm.n_diff,
                       'unmatched', v_adm.n_unres, 'admin_value', v_adm.admin_value,
                       'below_list', v_adm.under_list, 'reason', o.price_override_reason) end,
    'would_submit',  jsonb_build_object('ok', v_ok, 'error', v_err),
    'alerts',        v_alerts,
    'warnings',      to_jsonb(v_head || v_warn),
    'portal_path',   '/orders/' || o.id);
end;
$$;

revoke execute on function public.mcp_order_check_keys(jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.mcp_order_preview(bigint, boolean) from public, anon, authenticated;
revoke execute on function public.mcp_order_apply(bigint, jsonb, jsonb, text, text) from public, anon, authenticated;

--------------------------------------------------------------------------
-- 5b. order_resolve_parts (restated from 20261112120000: the last price
--     paid ignores free lines and breaks ties on the ERP line, as
--     mcp_order_apply; inside sales may stage unmatched items too)
--------------------------------------------------------------------------
create or replace function public.order_resolve_parts(p_customer_key text, p_items jsonb)
returns jsonb
language plpgsql stable security invoker set search_path = public, erp
as $$
declare
  c_stop constant text[] := array['christensen','chris','arms','ca','rifle','rifles','rd','rnd',
                                  'round','rounds','in','inch','the','and','with','w','each','ea'];
  v_type  text;
  v_its   jsonb;   -- [{idx, ref, uref, digits, descr}]
  v_cand  jsonb;   -- [{idx, part_id, how, score}]
  v_more  jsonb;
  v_items jsonb;
begin
  select dc.customer_type into v_type
  from erp.dim_customer dc where dc.customer_key = p_customer_key;
  if not found then
    raise exception 'customer_not_in_book: % is not on your book (or does not exist)', p_customer_key;
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'invalid_input:items: a non-empty list of {ref, description?}';
  end if;
  if jsonb_array_length(p_items) > 300 then
    raise exception 'invalid_input:items: 300 items at most per call';
  end if;

  select jsonb_agg(jsonb_build_object(
           'idx', (e.n - 1)::int,
           'ref', left(nullif(btrim(e.v ->> 'ref'), ''), 100),
           'uref', upper(nullif(btrim(e.v ->> 'ref'), '')),
           'digits', regexp_replace(coalesce(e.v ->> 'ref', ''), '\D', '', 'g'),
           'descr', left(nullif(btrim(e.v ->> 'description'), ''), 300)) order by e.n)
    into v_its
  from jsonb_array_elements(p_items) with ordinality as e(v, n)
  where jsonb_typeof(e.v) = 'object';

  -- Exact part id; the customer's own item number on their past ERP orders;
  -- the same digits ("CHR801-15025-01", "8011502501" -> 801-15025-01; six
  -- digits at least, so a stray "22" never matches). Best kind per part wins.
  with it as (
    select * from jsonb_to_recordset(coalesce(v_its, '[]'::jsonb))
      as (idx int, ref text, uref text, digits text, descr text)
  ),
  raw as (
    select it.idx, p.part_id, 'exact'::text as how, 1.0::numeric as score
    from it join erp.dim_part p on upper(p.part_id) = it.uref
    union all
    select it.idx, p.part_id, 'customer_history', 0.95
    from it
    join erp.fact_order_line f
      on f.customer_key = p_customer_key and upper(btrim(f.customer_part_id)) = it.uref
    join erp.dim_part p on p.part_key = f.part_key
    union all
    select it.idx, p.part_id, 'digits', 0.9
    from it
    join (select distinct dp.part_id, regexp_replace(dp.part_id, '\D', '', 'g') as d from erp.dim_part dp) p
      on p.d = it.digits
    where length(it.digits) >= 6
  ),
  best as (
    select distinct on (idx, part_id) idx, part_id, how, score
    from raw order by idx, part_id, score desc
  )
  select coalesce(jsonb_agg(to_jsonb(best)), '[]'::jsonb) into v_cand from best;

  -- Description, only for items nothing above matched: the share of the PO
  -- description's words (normalised like order_product_search) found in an
  -- active firearm's description / family / chambering. Top 3, >= 0.5.
  if exists (select 1 from jsonb_array_elements(coalesce(v_its, '[]'::jsonb)) i
             where i ->> 'descr' is not null
               and not exists (select 1 from jsonb_array_elements(v_cand) c
                               where (c ->> 'idx')::int = (i ->> 'idx')::int)) then
    with q as (
      select (i ->> 'idx')::int as idx, public.order_desc_tokens(i ->> 'descr') as toks
      from jsonb_array_elements(v_its) i
      where i ->> 'descr' is not null
        and not exists (select 1 from jsonb_array_elements(v_cand) c
                        where (c ->> 'idx')::int = (i ->> 'idx')::int)
    ),
    docs as materialized (
      select x.part_id,
             public.order_desc_tokens(concat_ws(' ',
               x.part_description, nullif(upper(btrim(x.product_family)), 'N/A'),
               nullif(upper(btrim(x.chambering)), 'N/A'), nullif(upper(btrim(x.barrel_length)), 'N/A'),
               nullif(upper(btrim(x.finish)), 'N/A'), nullif(upper(btrim(x.stock_color)), 'N/A'))) as toks
      from (select distinct on (dp.part_id) dp.*
              from erp.dim_part dp
             where dp.status = 'A' and dp.part_id ~ '^8\d\d-' and dp.part_id !~ '-M$'
             order by dp.part_id, dp.part_key) x
    ),
    scored as (
      select q.idx, d.part_id, public.order_desc_score(q.toks, d.toks) as score
      from q cross join docs d
      where cardinality(q.toks) > 0
    ),
    ranked as (
      select s.*, row_number() over (partition by s.idx order by s.score desc, s.part_id) as rn
      from scored s where s.score >= 0.5
    )
    select coalesce(jsonb_agg(jsonb_build_object('idx', idx, 'part_id', part_id,
                                                 'how', 'description', 'score', score)), '[]'::jsonb)
      into v_more
    from ranked where rn <= 3;
    v_cand := v_cand || v_more;
  end if;

  with it as (
    select * from jsonb_to_recordset(coalesce(v_its, '[]'::jsonb))
      as (idx int, ref text, uref text, digits text, descr text)
  ),
  c0 as (
    select * from jsonb_to_recordset(v_cand) as (idx int, part_id text, how text, score numeric)
  ),
  cand as (
    select c.idx, c.part_id, c.how, c.score,
           dp.part_description, dp.status, coalesce(dp.is_kit_flag = 'Y', false) as is_kit,
           lp.unit_price as list_price,
           hist.net_price as last_paid_price, hist.order_date as last_paid_date,
           case when c.how = 'description' then c.score
                else public.order_desc_score(public.order_desc_tokens(it.descr),
                                             public.order_desc_tokens(public.order_part_doc(c.part_id))) end
             as agreement,
           row_number() over (partition by c.idx
                              order by c.score desc, (dp.status = 'A') desc, (c.part_id ~ '-M$'), c.part_id) as rn
    from c0 c
    join it on it.idx = c.idx
    left join lateral (
      select p.part_description, p.status, p.is_kit_flag
      from erp.dim_part p where p.part_id = c.part_id order by p.part_key limit 1) dp on true
    left join lateral (
      select i.unit_price
      from public.effective_price_lists(v_type) l
      join public.price_list_items i on i.price_list_id = l.id and i.part_id = c.part_id
      where not l.is_special
      order by l.effective_from desc, l.id limit 1) lp on true
    -- Last paid: a free unit ($0, or 100% off) is not a price paid; ties
    -- break on the ERP order and line (as mcp_order_apply, 20261113090000).
    left join lateral (
      select round(f.unit_price * (1 - coalesce(f.trade_discount_pct, 0) / 100), 2) as net_price, f.order_date
      from erp.fact_order_line f
      join erp.dim_part p on p.part_key = f.part_key
      where f.customer_key = p_customer_key and p.part_id = c.part_id and f.unit_price > 0
        and coalesce(f.trade_discount_pct, 0) < 100
      order by f.order_date desc nulls last, f.order_id desc, f.line_num desc limit 1) hist on true
  ),
  per_item as (
    select it.idx, it.ref, it.descr,
           coalesce(jsonb_agg(jsonb_build_object(
             'part_id',         c.part_id,
             'erp_description', c.part_description,
             'part_status',     c.status,
             'match',           c.how,
             'score',           c.score,
             'description_agreement', c.agreement,
             'is_kit',          c.is_kit,
             'requires_ffl',    public.part_requires_ffl(c.part_id),
             'on_price_list',   c.list_price is not null,
             'list_price',      c.list_price,
             'last_paid_price', c.last_paid_price,
             'last_paid_date',  c.last_paid_date)
             order by c.rn) filter (where c.part_id is not null and c.rn <= 5), '[]'::jsonb) as cands,
           count(*) filter (where c.how <> 'description' and c.status = 'A' and c.part_id !~ '-M$') as strong_active,
           count(*) filter (where c.how <> 'description') as strong,
           count(c.part_id) as any_cand,
           bool_or(c.rn = 1 and c.how <> 'description' and c.agreement < 0.3) as top_disagrees
    from it
    left join cand c on c.idx = it.idx
    group by it.idx, it.ref, it.descr
  )
  select jsonb_agg(jsonb_build_object(
           'index', p.idx,
           'ref', p.ref,
           'description', p.descr,
           'status', case
              when (p.strong_active = 1 or p.strong = 1) and coalesce(p.top_disagrees, false) then 'check_description'
              when p.strong_active = 1 or p.strong = 1 then 'matched'
              when p.strong > 1 then 'ambiguous'
              when p.any_cand > 0 then 'description_only'
              else 'unmatched' end,
           'candidates', p.cands)
           order by p.idx)
    into v_items
  from per_item p;

  return jsonb_build_object(
    'customer_type', v_type,
    'items', coalesce(v_items, '[]'::jsonb),
    'note', 'matched = one strong match (exact id, this customer''s own item number, or the same digits) '
            'whose ERP description agrees with the PO''s. check_description = the number matched but '
            'the descriptions disagree (a chambering missing, or under a third of the words): likely a typo '
            'on the PO; show the user both. description_only and ambiguous need a person''s choice; '
            'unmatched items can be staged only by an admin or inside sales, with a price.');
end;
$$;

revoke execute on function public.order_resolve_parts(text, jsonb) from public, anon;
grant execute on function public.order_resolve_parts(text, jsonb) to authenticated;

comment on function public.order_resolve_parts(text, jsonb) is
  'Resolve a PO''s lines [{ref, description}] to ERP parts across the whole catalog: exact id, '
  'the customer''s own item number on past ERP orders, same digits, then description. Each '
  'candidate carries its list price for the account and the last price the customer paid '
  '(free lines ignored, 20261113090000). RLS-scoped (SECURITY INVOKER).';

--------------------------------------------------------------------------
-- 6. submit_order (restated: inside sales submits its own hand-priced
--    orders; a blank PO becomes PORTAL-<id>; the buyer contact is
--    snapshotted; a past ship date is refused; the promo pass moves to
--    order_apply_promo() unchanged)
--------------------------------------------------------------------------
alter table public.orders
  add column if not exists contact_name  text,
  add column if not exists contact_phone text,
  add column if not exists contact_email text;

comment on column public.orders.contact_name is
  'The buyer (customer_contact_key) as the ERP had them at submit: name, '
  'contact_phone, contact_email. Stamped by submit_order for the order loader, '
  'like the ship-to snapshot; null when no contact was chosen, or it is not '
  'an active contact of the account.';

-- The promo pass, one copy (moved out of submit_order unchanged):
-- submit_order runs it authoritatively, admin_set_order_line_price after
-- every hand price, so a draft shows the totals the submit will compute.
-- Per price list: buy N get M settled as a prorated percent over the qty on
-- that list. The admin list has no promo, so hand-priced lines keep their
-- price. The caller opens the write window (app.mcp_order_write) first.
create or replace function public.order_apply_promo(p_order_id bigint)
returns void
language sql
set search_path = public
as $$
  with totals as (
    select l.price_list_id,
           sum(l.qty)::numeric as total_qty,
           pl.promo_buy_qty, pl.promo_get_qty
    from public.order_lines l
    join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = p_order_id
    group by l.price_list_id, pl.promo_buy_qty, pl.promo_get_qty
  ),
  pct as (
    select price_list_id,
           case
             when promo_buy_qty is null then 0::numeric
             else round(
               100 * (floor(total_qty / (promo_buy_qty + promo_get_qty))
                      * promo_get_qty) / total_qty, 4)
           end as discount_pct
    from totals
  )
  update public.order_lines l
  set discount_pct         = pct.discount_pct,
      effective_unit_price = round(l.unit_price * (1 - pct.discount_pct / 100), 2)
  from pct
  where l.order_id = p_order_id
    and l.price_list_id = pct.price_list_id;
$$;

revoke execute on function public.order_apply_promo(bigint) from public, anon, authenticated;

create or replace function public.submit_order(p_order_id bigint, p_acknowledged boolean DEFAULT false)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
  v_cust  record;
  v_ship  erp.dim_ship_to;
  v_bad   text;
  v_needs boolean;
  v_ffl   text;
  v_exp   date;
  v_ack   boolean := coalesce(p_acknowledged, false);
  v_guc   text := current_setting('app.mcp_order_write', true);
  v_n_admin int;
  v_cname  text;
  v_cphone text;
  v_cemail text;
begin
  -- A JWT outlives deactivation; the profile is the cutoff, not the token.
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;
  -- Claude never submits. An MCP session reaches this only through the
  -- draft preview's dry run (mcp_order_preview sets app.mcp_dry_run and
  -- always rolls the subtransaction back).
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp'
     and coalesce(current_setting('app.mcp_dry_run', true), '') <> 'on' then
    raise exception 'mcp_cannot_submit: Claude drafts orders; a person submits them in the portal'
      using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if not (v_order.user_id = v_uid or public.is_admin()) then
    raise exception 'only the order''s owner may submit it';
  end if;
  if v_order.status <> 'draft' then
    raise exception 'order % is %, only drafts can be submitted',
      p_order_id, v_order.status;
  end if;
  -- Claude (or any non-portal source) drafted it: a person must confirm it.
  if v_order.source <> 'portal' and not v_ack then
    raise exception 'acknowledge_required: order % was drafted by %; confirm you have reviewed it before submitting',
      p_order_id, case v_order.source when 'mcp' then 'Claude' else v_order.source end;
  end if;
  if not exists (select 1 from public.order_lines where order_id = p_order_id) then
    raise exception 'order % has no lines', p_order_id;
  end if;

  -- Unmatched items never leave draft.
  select string_agg(coalesce(l.customer_part_ref, l.part_id), ', ' order by l.id) into v_bad
  from public.order_lines l
  where l.order_id = p_order_id
    and (l.part_unresolved or not exists (select 1 from erp.dim_part dp where dp.part_id = l.part_id));
  if v_bad is not null then
    raise exception 'unmatched_parts: order % has lines that match no ERP part (%). Correct or remove them before submitting.',
      p_order_id, left(v_bad, 400);
  end if;

  -- Hand prices: an admin, or inside sales on their own order (the owner
  -- check above), submits, and only having acknowledged them.
  select count(*) into v_n_admin
  from public.order_lines l where l.order_id = p_order_id and l.price_source = 'admin';
  if v_n_admin > 0 then
    if not public.can_price_orders() then
      raise exception 'admin_price_requires_admin: order % has % line(s) priced by hand; only an admin, or inside sales on their own order, can submit it',
        p_order_id, v_n_admin;
    end if;
    if not v_ack then
      raise exception 'acknowledge_required: order % has % line(s) at admin prices; confirm you have reviewed every flagged line before submitting',
        p_order_id, v_n_admin;
    end if;
    if exists (select 1 from public.order_lines l
               where l.order_id = p_order_id and l.price_source = 'admin'
                 and l.price_list_id is distinct from public.admin_price_list_id()) then
      raise exception 'order % has an admin-priced line that is not on the admin price list', p_order_id;
    end if;
  end if;

  select c.customer_name, c.customer_type into v_cust
  from erp.dim_customer c where c.customer_key = v_order.customer_key;
  if not found then
    raise exception 'customer % not found in the ERP', v_order.customer_key;
  end if;

  -- A ship date already gone by would reach order entry as a date the ERP
  -- refuses; the person submitting fixes it first. current_date is the
  -- business date (America/Denver, 20260901190000).
  if v_order.requested_ship_date < current_date then
    raise exception 'ship_date_past: the requested ship date % has passed; change it before submitting',
      v_order.requested_ship_date;
  end if;

  -- Ship-to: one of this account's own Visual ship-to addresses (CUST_ADDRESS,
  -- so it has a SHIPTO_ID the order can carry), and still active.
  if v_order.ship_to_key is null then
    raise exception 'pick a ship-to address for this order';
  end if;
  select s.* into v_ship from erp.dim_ship_to s where s.ship_to_key = v_order.ship_to_key;
  if not found
     or v_ship.customer_id is distinct from v_order.customer_key
     or v_ship.address_source is distinct from 'ShipTo'
     or coalesce(v_ship.is_unknown_ship_to, false)
     or nullif(trim(v_ship.ship_to_id), '') is null then
    raise exception 'ship-to % is not one of this account''s ship-to addresses', v_order.ship_to_key;
  end if;
  if upper(coalesce(v_ship.active_flag, 'Y')) = 'N' then
    raise exception 'ship-to % (%) is inactive in the ERP; pick another address',
      v_ship.ship_to_id, v_ship.ship_to_name;
  end if;

  -- FFL: only when a line is a firearm (part_requires_ffl). The ship-to's
  -- licence on file is used when it is complete and current; the rep enters
  -- one only when it is not (or to give a renewed licence). Whether an
  -- entered licence matches Visual is order entry's check: the loader
  -- refuses to write until the ship-to in Visual carries it.
  v_needs := exists (select 1 from public.order_lines l
                     where l.order_id = p_order_id and public.part_requires_ffl(l.part_id));
  if not v_needs then
    v_ffl := null;
    v_exp := null;
  elsif nullif(trim(v_order.ffl_license_number), '') is null
        and public.ffl_on_file_current(v_ship.ffl_license_number, v_ship.ffl_expiration_raw) then
    v_ffl := upper(trim(v_ship.ffl_license_number));
    v_exp := public.parse_ffl_expiry(v_ship.ffl_expiration_raw);
  else
    if length(public.ffl_normalize(v_order.ffl_license_number)) <> 15 then
      raise exception 'this order has firearms and ship-to % has no current FFL on file: enter the FFL '
        'number (15 characters, e.g. 1-23-456-78-9A-12345)', v_ship.ship_to_id;
    end if;
    if v_order.ffl_expires_on is null then
      raise exception 'the FFL expiration date is required';
    end if;
    if v_order.ffl_expires_on < current_date then
      raise exception 'the FFL expired on %; get the renewed licence before submitting',
        v_order.ffl_expires_on;
    end if;
    v_ffl := upper(trim(v_order.ffl_license_number));
    v_exp := v_order.ffl_expires_on;
  end if;

  -- The buyer, as the ERP has them now: the order loader writes these to
  -- the Visual order (it reads the order, not erp.dim_customer_contact).
  -- Only an ACTIVE contact of this account: one deactivated since the draft,
  -- or a key pointing at another account (a portal PATCH can set one),
  -- stamps nothing, all three fields null.
  select public.contact_display_name(e.contact_name, e.first_name, e.last_name, null, null),
         coalesce(nullif(btrim(e.phone), ''), nullif(btrim(e.mobile), '')),
         nullif(btrim(e.email), '')
    into v_cname, v_cphone, v_cemail
  from erp.dim_customer_contact e
  where e.customer_contact_key = v_order.customer_contact_key
    and e.customer_key = v_order.customer_key
    and coalesce(e.contact_active_flag, 'Y') = 'Y'
  limit 1;

  -- Every LIST-priced line must sit on a list effective today for this
  -- customer type, and its captured price must still be the published price.
  -- Admin lines were checked above.
  select string_agg(distinct l.part_id, ', ') into v_bad
  from public.order_lines l
  where l.order_id = p_order_id
    and l.price_source = 'list'
    and not exists (
      select 1
      from public.effective_price_lists(v_cust.customer_type) epl
      join public.price_list_items i
        on i.price_list_id = epl.id and i.part_id = l.part_id
      where epl.id = l.price_list_id
        and i.unit_price = l.unit_price
    );
  if v_bad is not null then
    raise exception 'lines no longer valid against today''s price lists: %. '
      'Re-open the draft to refresh pricing.', v_bad;
  end if;

  -- From here the server writes lines and protected columns: open the write
  -- window (order_lines_protect_pricing, orders_protect_provenance), then put
  -- the GUC back as it was.
  perform set_config('app.mcp_order_write', 'on', true);

  -- Authoritative promo pass (overwrites whatever the client previewed).
  -- The admin list has no promo: its lines keep their price.
  perform public.order_apply_promo(p_order_id);

  update public.orders o
  set status        = 'submitted',
      -- No customer PO (blank after any whitespace): the order's own
      -- reference, so the portal, the order loader and Visual's
      -- CUSTOMER_PO_REF all show the same thing. A real PO is stored trimmed.
      po_number     = coalesce(nullif(btrim(o.po_number, E' \t\r\n\u00A0'), ''), 'PORTAL-' || o.id),
      customer_name = coalesce(v_cust.customer_name, v_order.customer_key),
      customer_type = v_cust.customer_type,
      ship_to_id      = v_ship.ship_to_id,
      ship_to_addr_no = v_ship.addr_no,
      ship_to_name    = v_ship.ship_to_name,
      ship_to_address = concat_ws(', ',
                          nullif(trim(v_ship.address1), ''), nullif(trim(v_ship.address2), ''),
                          nullif(trim(v_ship.address3), ''), nullif(trim(v_ship.city), ''),
                          nullif(trim(concat_ws(' ', v_ship.state, v_ship.zip_code)), '')),
      requires_ffl               = v_needs,
      ffl_license_number         = v_ffl,
      ffl_expires_on             = v_exp,
      ffl_on_file_number         = v_ship.ffl_license_number,
      ffl_on_file_expiration_raw = v_ship.ffl_expiration_raw,
      total_amount  = (select sum(line_total) from public.order_lines
                       where order_id = p_order_id),
      -- The buyer snapshot (resolved above).
      contact_name  = v_cname,
      contact_phone = v_cphone,
      contact_email = v_cemail,
      submitted_at  = now(),
      acknowledged_at = case when v_ack then now() else o.acknowledged_at end,
      acknowledged_by = case when v_ack then v_uid else o.acknowledged_by end
  where o.id = p_order_id
  returning * into v_order;
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);

  return v_order;
end;
$$;

revoke execute on function public.submit_order(bigint, boolean) from public, anon;
grant execute on function public.submit_order(bigint, boolean) to authenticated, service_role;

comment on function public.submit_order(bigint, boolean) is
  'draft -> submitted, with the authoritative pricing/ship-to/FFL pass. An '
  'order with source <> ''portal'' needs p_acknowledged => true. Lines '
  'matching no ERP part never submit; hand-priced lines need an admin, or '
  'inside sales on their own order, as submitter and the acknowledgement. A '
  'blank PO becomes PORTAL-<id>; a requested ship date that has passed is '
  'refused (ship_date_past) (20261113090000).';

--------------------------------------------------------------------------
-- 6b. recall_order (restated from 20260817000300_order_review_hardening:
--     a stamped PORTAL-<id> is cleared again)
--------------------------------------------------------------------------
create or replace function public.recall_order(p_order_id bigint)
returns public.orders
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_order public.orders;
begin
  if not exists (
    select 1 from public.profiles p where p.user_id = v_uid and p.active
  ) then
    raise exception 'your account has been deactivated';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order % not found', p_order_id;
  end if;
  if not (v_order.user_id = v_uid or public.is_admin()) then
    raise exception 'only the order''s owner may recall it';
  end if;
  if v_order.status <> 'submitted' then
    raise exception 'order % is %, only submitted orders can be recalled',
      p_order_id, v_order.status;
  end if;

  -- PORTAL-<id> was given at submit because the order had no customer PO:
  -- back in draft it has none again (flagged, and re-given at the next
  -- submit), so a PO that turns up can simply be typed in.
  update public.orders
  set status = 'draft', submitted_at = null, total_amount = null,
      po_number = case when po_number = 'PORTAL-' || id then null else po_number end
  where id = p_order_id
  returning * into v_order;
  return v_order;
end;
$$;

revoke execute on function public.recall_order(bigint) from public, anon;
grant execute on function public.recall_order(bigint) to authenticated;

--------------------------------------------------------------------------
-- 7. admin_set_order_line_price (restated: admin, or inside sales on its
--    own orders; the same part at the same hand price is refused; the
--    order's promo is re-run)
--------------------------------------------------------------------------
comment on column public.order_lines.price_source is
  '''list'' = the published price; ''admin'' = priced by hand (off list or a different price) '
  'by an admin or inside sales. Hand-priced lines sit on the reserved admin price list; an '
  'admin, or inside sales on their own order, submits them (20261113090000).';

create or replace function public.admin_set_order_line_price(p_line_id bigint, p_unit_price numeric, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'erp'
AS $$
declare
  v_guc   text := current_setting('app.mcp_order_write', true);
  v_line  public.order_lines;
  v_order public.orders;
  v_type  text;
  v_item  record;
  v_has   boolean;
  v_reason text := nullif(btrim(p_reason), '');
  v_admin_list bigint := public.admin_price_list_id();
begin
  if coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'mcp' then
    raise exception 'mcp_direct_write: prices are set in the portal by an admin or inside sales' using errcode = '42501';
  end if;
  if not public.can_price_orders() then
    raise exception 'not_admin: only an admin or inside sales can set a line''s price' using errcode = '42501';
  end if;

  select * into v_line from public.order_lines where id = p_line_id;
  if not found then
    raise exception 'line_not_found: order line % not found', p_line_id;
  end if;
  select * into v_order from public.orders where id = v_line.order_id for update;
  -- An admin prices any Claude draft; inside sales only its own. submit_order
  -- takes the owner or an admin, so whoever may price an order may also
  -- submit it: a hand price on a rep's draft would leave it to an admin.
  if not (public.is_admin() or v_order.user_id = auth.uid()) then
    raise exception 'not_owner: only the order''s owner or an admin can set prices on it'
      using errcode = '42501';
  end if;
  if v_order.status <> 'draft' then
    raise exception 'order_not_draft: order % is %; recall it to draft first', v_order.id, v_order.status;
  end if;
  if v_order.source = 'portal' then
    raise exception 'order_portal: hand-typed orders are priced from the price list';
  end if;
  if v_line.part_unresolved then
    raise exception 'unmatched_part: line % matches no ERP part; ask Claude to correct it, or remove the line', v_line.part_id;
  end if;
  if length(v_reason) > 500 then
    raise exception 'invalid_input:reason: 500 characters at most';
  end if;

  select dc.customer_type into v_type from erp.dim_customer dc where dc.customer_key = v_order.customer_key;
  select l.id as list_id, i.id as item_id, i.unit_price, i.description into v_item
  from public.effective_price_lists(v_type) l
  join public.price_list_items i on i.price_list_id = l.id and i.part_id = v_line.part_id
  where not l.is_special
  order by l.effective_from desc, l.id
  limit 1;
  v_has := found;

  if p_unit_price is not null
     and (p_unit_price < 0 or p_unit_price > 1000000 or p_unit_price <> round(p_unit_price, 2)) then
    raise exception 'invalid_input:unit_price: use 0-1,000,000 with at most 2 decimals';
  end if;
  if p_unit_price is null and not v_has then
    raise exception 'no_list_price: % is on no price list for this account; set a price instead', v_line.part_id;
  end if;

  perform set_config('app.mcp_order_write', 'on', true);
  begin
    if p_unit_price is null or (v_has and p_unit_price = v_item.unit_price) then
      update public.order_lines
      set price_list_id = v_item.list_id, price_list_item_id = v_item.item_id,
          unit_price = v_item.unit_price, discount_pct = 0, effective_unit_price = v_item.unit_price,
          price_source = 'list', list_unit_price = v_item.unit_price
      where id = p_line_id;
    else
      if v_reason is null and v_order.price_override_reason is null then
        raise exception 'reason_required: say why this order is priced by hand';
      end if;
      -- Free goods may repeat a part at DIFFERENT prices; the same part at
      -- the same hand price is one line (mcp_order_apply's rule). The
      -- unique key covers list-priced lines only, so it is checked here.
      if exists (select 1 from public.order_lines o2
                 where o2.order_id = v_order.id and o2.id <> p_line_id
                   and o2.part_id = v_line.part_id and o2.price_source = 'admin'
                   and o2.unit_price = p_unit_price) then
        raise exception 'invalid_input:duplicate_line:%: the part appears twice at the same price; send one line with the total qty', v_line.part_id;
      end if;
      update public.order_lines
      set price_list_id = v_admin_list, price_list_item_id = null,
          unit_price = p_unit_price, discount_pct = 0, effective_unit_price = p_unit_price,
          price_source = 'admin', list_unit_price = case when v_has then v_item.unit_price end
      where id = p_line_id;
    end if;
    -- The line left (or joined) a price list: the promo of the lines still
    -- on it changes. Re-run the order's promo pass, the one submit_order
    -- runs, so the draft shows what the submit will compute.
    perform public.order_apply_promo(v_order.id);
  exception when unique_violation then
    raise exception 'duplicate_line: % is already on this order at that price list; remove one of the lines first', v_line.part_id;
  end;
  if v_reason is not null then
    update public.orders set price_override_reason = v_reason where id = v_order.id;
  end if;
  perform set_config('app.mcp_order_write', coalesce(v_guc, ''), true);

  select * into v_line from public.order_lines where id = p_line_id;
  return to_jsonb(v_line);
end;
$$;

revoke execute on function public.admin_set_order_line_price(bigint, numeric, text) from public, anon;
grant execute on function public.admin_set_order_line_price(bigint, numeric, text) to authenticated;

comment on function public.admin_set_order_line_price(bigint, numeric, text) is
  'Admin or inside sales (can_price_orders), drafts from Claude only; inside sales on its own '
  'orders only (not_owner), an admin on any. Sets a line''s unit price (it moves to the admin '
  'price list unless it equals the published price) or, with p_unit_price null, resets it to the '
  'published price, then re-runs the order''s promo (order_apply_promo). The same part twice at '
  'the same hand price is refused (duplicate_line). p_reason sets orders.price_override_reason '
  '(required if none is on the order yet). 20261113090000.';

--------------------------------------------------------------------------
-- 8. Order documents (the customer's PO as it arrived)
--------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('order-documents', 'order-documents', false,
        26214400,                              -- 25 MB per file
        array['application/pdf',
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              'application/vnd.ms-excel',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
              'application/msword',
              'text/csv', 'text/plain',
              'message/rfc822', 'application/vnd.ms-outlook',
              'image/png', 'image/jpeg', 'image/webp', 'image/heic'])
on conflict (id) do nothing;

-- '<order id>/<file name>': the first path segment is the order, in the one
-- shape the portal and Claude write (no leading zero, no deeper folder).
-- Anything else would count as the order's for RLS yet never show in a
-- listing of '<id>/', so it belongs to no order.
create or replace function public.order_document_order_id(p_name text)
returns bigint
language sql immutable set search_path = public
as $$
  select case when p_name ~ '^[1-9][0-9]{0,17}/[^/]+$'
              then split_part(p_name, '/', 1)::bigint end
$$;

revoke execute on function public.order_document_order_id(text) from public, anon;
grant execute on function public.order_document_order_id(text) to authenticated;

-- The policies are set-based, like the account-photos ones (010): the
-- caller's readable orders are built once per statement (a hashed subplan
-- of my_order_ids(), which includes their own orders), never once per
-- object. A folder listing filters the name with LIKE, which is not
-- leakproof, so the policy runs on every object in the bucket before the
-- prefix does: a per-row access function would make every listing as slow
-- as the bucket is big.
drop policy if exists "read order documents" on storage.objects;
create policy "read order documents" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'order-documents'
    and ((select public.is_admin())
         or public.order_document_order_id(name) in (select public.my_order_ids()))
  );

-- Whoever can read the order can add a document to it, at any status: the
-- signed PO often arrives after the order was submitted.
drop policy if exists "add order documents" on storage.objects;
create policy "add order documents" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'order-documents'
    and ((select public.is_admin())
         or public.order_document_order_id(name) in (select public.my_order_ids()))
  );

-- Removing one: whoever uploaded it, an admin, or inside sales. owner_id,
-- not owner: Storage documents the uuid owner column as deprecated.
drop policy if exists "remove order documents" on storage.objects;
create policy "remove order documents" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'order-documents'
    and ((select public.is_admin())
         or public.order_document_order_id(name) in (select public.my_order_ids()))
    and ((select public.is_admin())
         or (select public.is_order_entry())
         or owner_id = (select auth.uid())::text)
  );

-- An earlier draft of this migration checked each object with a per-row
-- can_read_order(); nothing uses it now.
drop function if exists public.can_read_order(bigint);

--------------------------------------------------------------------------
-- 9. v_orders_ready_for_erp: the hand-pricing fields (appended; a view's
--    existing columns cannot move)
--------------------------------------------------------------------------
create or replace view public.v_orders_ready_for_erp
with (security_invoker = true) as
select
  o.id                         as order_id,
  o.status,
  o.source,
  o.user_id,
  o.created_by,
  o.created_at,
  o.submitted_at,
  o.acknowledged_at,
  o.acknowledged_by,
  o.customer_key,
  o.customer_name,
  o.customer_type,
  o.po_number,
  o.requested_ship_date,
  o.notes,
  o.customer_contact_key,
  o.ship_to_key,
  o.ship_to_id,
  o.ship_to_addr_no,
  o.ship_to_name,
  o.ship_to_address,
  o.requires_ffl,
  o.ffl_license_number,
  o.ffl_expires_on,
  o.ffl_on_file_number,
  o.ffl_on_file_expiration_raw,
  o.total_amount,
  o.mcp_token_id,
  o.client_request_id,
  o.source_ref,
  o.mcp_warnings,
  o.updated_at,
  coalesce((
    select jsonb_agg(jsonb_build_object(
             'line_id',              l.id,
             'part_id',              l.part_id,
             'description',          l.description,
             'qty',                  l.qty,
             'price_list_id',        l.price_list_id,
             'price_list_name',      pl.name,
             'unit_price',           l.unit_price,
             'discount_pct',         l.discount_pct,
             'effective_unit_price', l.effective_unit_price,
             'line_total',           l.line_total,
             'price_source',         l.price_source,
             'list_unit_price',      l.list_unit_price,
             'customer_part_ref',    l.customer_part_ref,
             'customer_description', l.customer_description)
           order by l.id)
    from public.order_lines l
    join public.price_lists pl on pl.id = l.price_list_id
    where l.order_id = o.id), '[]'::jsonb) as lines,
  o.price_override_reason,
  o.contact_name,
  o.contact_phone,
  o.contact_email
from public.orders o
where o.status = 'submitted'
  and (o.source = 'portal'
       or (o.acknowledged_at is not null and o.acknowledged_at >= o.submitted_at));

revoke all on public.v_orders_ready_for_erp from anon, public;
grant select on public.v_orders_ready_for_erp to authenticated, service_role;

--------------------------------------------------------------------------
-- 10. order_owner_names(): who an order belongs to, for the order screens
--------------------------------------------------------------------------
-- profiles shows each user only their own row (and admins every row), so
-- a rep looking at an order inside sales drafted on their account, or
-- inside sales reviewing a rep's, could not name its owner. This returns
-- the display name and role, never the email, for:
--   * the caller themselves;
--   * anyone, when the caller is an admin or inside sales;
--   * the owner of an order the caller can read (my_order_ids()).
-- An id outside those simply returns no row. 'order_entry' is reported as
-- 'inside_sales', the name people use.
create or replace function public.order_owner_names(p_user_ids uuid[])
returns table (user_id uuid, display_name text, role text)
language sql stable security definer set search_path = public
as $$
  select p.user_id,
         coalesce(nullif(btrim(p.full_name), ''), 'Portal user'),
         case when p.role = 'order_entry' then 'inside_sales' else p.role end
  from public.profiles p
  where p.user_id = any (p_user_ids)
    and (p.user_id = auth.uid()
         or (select public.is_admin() or public.is_order_entry())
         or p.user_id in (select o.user_id from public.orders o
                           where o.id in (select public.my_order_ids())));
$$;

revoke execute on function public.order_owner_names(uuid[]) from public, anon;
grant execute on function public.order_owner_names(uuid[]) to authenticated;

comment on function public.order_owner_names(uuid[]) is
  'Display name (full_name, else ''Portal user'') and role (order_entry reported as '
  'inside_sales) of the requested users the caller may name: themselves; anyone for an '
  'admin or inside sales; otherwise the owners of orders the caller can read. Never the '
  'email. 20261113090000.';

--------------------------------------------------------------------------
-- 11. Words
--------------------------------------------------------------------------
comment on function public.mcp_create_order_draft(jsonb) is
  'MCP only (mcp_orders_gate). Creates a DRAFT from {idempotency_key, customer_key, '
  'customer_confirmed?, ship_to_key, ship_to_confirmed, po_number | no_po_confirmed, '
  'requested_ship_date?, customer_contact_key?, notes?, allow_duplicate?, is_test?, '
  'source_ref?, price_override_reason?, lines:[{part_id, qty, part_confirmed, '
  'price_list_id?, expected_unit_price?, unit_price?, customer_part_ref?, '
  'customer_description?}]}. unit_price and price_override_reason: admin or inside '
  'sales only. Prices otherwise on the server; dry-runs submit_order; never submits.';
