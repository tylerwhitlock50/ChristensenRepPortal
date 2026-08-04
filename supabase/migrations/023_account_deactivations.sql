/*============================================================================
  023_account_deactivations.sql
  Purpose: Let a rep take an account out of play. The ERP says an account is
           active no matter what the rep knows — the store closed, the buyer
           moved on, nobody answers the phone — so a portal-side override is
           the only way "stop recommending this to me" can exist at all.

  Why a public.* table and not a flag on erp.dim_customer: the ETL is
  TRUNCATE + COPY per table, every night (etl/push_to_supabase.py). Any
  column added to the landing table is emptied nightly, and 007 gives the
  app no write policy on erp.* anyway. This is the same shape as
  account_assignments (003): an app-owned override layer keyed by
  customer_key, no cross-schema FK, surviving every reload.

  One deactivation "period" per row, history kept: reactivating stamps
  reactivated_at/by rather than deleting, so "rep X wrote this account off
  twice in a year, for the same reason" stays knowable. At most one OPEN
  period per account (partial unique index).

  Where a deactivated account disappears from, and why each place:

    1. refresh_account_signals() base CTE — out of scoring, and therefore
       out of recommendation generation, both preview functions, and
       ai_batch_targets (they all read account_signals and nothing else).
       The stale-row sweep in 019 already deletes the signal row on the next
       refresh; the trigger below deletes it immediately so the rep does not
       wait a night for the account to leave their ranked lists.
    2. Open/acted recommendations — dismissed by the trigger with a new
       'account_deactivated' outcome, so Today's queue clears now, not at
       the next nightly generate. 'dismissed' deliberately: the mission
       visit-guard (016) blocks 'closed' without a survey but never blocks
       dismissal, which is exactly the closed-dealer escape hatch it was
       built to leave open.
    3. v_account_list — grows deactivated_at / deactivation_reason columns
       so the accounts page can filter and label without a second query.
    4. create_mission() — the p_active_only scope (the default) now also
       skips deactivated accounts. An admin who explicitly asks for
       inactive accounts gets everything, portal-deactivated included.
    5. account_coverage / rep_execution_summary — a written-off account must
       not count against a rep's coverage or book size.

  NOT excluded from: my_customer_keys() / has_account_access(). Access is
  not the same thing as relevance — the rep still needs to open the account
  to see who deactivated it, why, and to undo it. v_user_accounts is also
  left alone: the mission progress views (016) join it to attribute already-
  created recommendations, and shrinking it would silently drop those rows
  from an admin's mission accounting.

  Reactivation self-heals downstream: the account re-enters the signals
  base on the next refresh_account_signals() run (step 0 of the nightly
  generate_recommendations()), so scores and recommendations return within
  a day. Dismissed recommendations stay dismissed — the cooldown logic in
  020 decides when the engine may speak about that account again.
============================================================================*/

--------------------------------------------------------------------------
-- The table. deactivated_by defaults to auth.uid() like contacts/notes
-- (004) — the client never sends it. The two CHECKs keep a period's
-- reactivation stamp all-or-nothing and ordered.
--------------------------------------------------------------------------
create table if not exists public.account_deactivations (
    id              bigint generated always as identity primary key,
    customer_key    text not null,          -- erp.dim_customer.customer_key, no FK (schema reloaded wholesale)
    reason          text not null check (reason in
                      ('store_closed','buys_elsewhere','unresponsive',
                       'low_potential','duplicate_account','other')),
    note            text,
    deactivated_by  uuid not null default auth.uid() references public.profiles (user_id),
    deactivated_at  timestamptz not null default now(),
    reactivated_by  uuid references public.profiles (user_id),
    reactivated_at  timestamptz,
    constraint account_deactivations_reactivation_pair
      check ((reactivated_at is null) = (reactivated_by is null)),
    constraint account_deactivations_reactivation_order
      check (reactivated_at is null or reactivated_at >= deactivated_at)
);
alter table public.account_deactivations enable row level security;

comment on table public.account_deactivations is
  'Portal-side "stop working this account" override of the ERP''s active_flag. '
  'One row per deactivation period; reactivating stamps reactivated_at/by '
  'instead of deleting, so the history of who wrote an account off, and why, '
  'is kept. At most one open period per account.';
comment on column public.account_deactivations.reason is
  'Why the rep took the account out of play. Vocabulary mirrored in '
  'frontend/src/types/domain.ts (DEACTIVATION_REASONS).';

-- One OPEN deactivation per account. A second deactivate while one is open
-- surfaces as a 23505 the client translates to "already deactivated".
create unique index if not exists uq_account_deactivations_open
  on public.account_deactivations (customer_key)
  where reactivated_at is null;

-- History lookups and the not-exists probes below.
create index if not exists idx_account_deactivations_customer
  on public.account_deactivations (customer_key);

--------------------------------------------------------------------------
-- RLS + grants. Read and deactivate are account-scoped (010's policy
-- shape); reactivation is an UPDATE that column grants confine to the two
-- reactivation stamps — a rep cannot rewrite another rep's reason or note,
-- only end the period. No delete policy: history is the point.
--------------------------------------------------------------------------
create policy "read deactivations" on public.account_deactivations
  for select to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()));

create policy "write deactivations" on public.account_deactivations
  for insert to authenticated
  with check (
    ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
    and deactivated_by = auth.uid()
    and reactivated_at is null          -- a period is opened open; closing it is the UPDATE path
  );

create policy "reactivate deactivations" on public.account_deactivations
  for update to authenticated
  using ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
  with check (
    ((select public.is_admin()) or customer_key in (select public.my_customer_keys()))
    and reactivated_by = auth.uid()
    and reactivated_at is not null
  );

revoke all on public.account_deactivations from anon, public;
revoke all on public.account_deactivations from authenticated;
grant select, insert on public.account_deactivations to authenticated;
-- Column-level: the only thing an UPDATE may touch is the reactivation stamp.
grant update (reactivated_by, reactivated_at) on public.account_deactivations to authenticated;

--------------------------------------------------------------------------
-- New outcome for the auto-dismissal. 005 declared the outcome CHECK
-- inline on the column, so it carries the default constraint name.
--------------------------------------------------------------------------
alter table public.recommendations
  drop constraint if exists recommendations_outcome_check;
alter table public.recommendations
  add constraint recommendations_outcome_check
  check (outcome in ('order_received','inventory_issue','competitor',
                     'customer_shrinking','seasonal','false_positive',
                     'could_not_contact','account_deactivated'));

--------------------------------------------------------------------------
-- The trigger: make deactivation take effect NOW, not at the next nightly
-- run. Dismisses the account's open work and drops its signals row so it
-- leaves ranked lists immediately. SECURITY DEFINER for the same reason as
-- mark_recommendation_acted (005): the writes must not depend on the
-- caller's RLS view of recommendations/account_signals.
--
-- stamp_recommendation_close (005) fires on the update and coalesces, so
-- the closed_by/closed_at set here survive.
--------------------------------------------------------------------------
create or replace function public.handle_account_deactivation()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update public.recommendations
     set status       = 'dismissed',
         outcome      = 'account_deactivated',
         outcome_note = coalesce(outcome_note, 'Account deactivated by the rep'),
         closed_by    = new.deactivated_by,
         closed_at    = now()
   where customer_key = new.customer_key
     and status in ('open', 'acted');

  delete from public.account_signals
   where customer_key = new.customer_key;

  return new;
end;
$$;

revoke execute on function public.handle_account_deactivation() from public, anon, authenticated;

drop trigger if exists trg_account_deactivated on public.account_deactivations;
create trigger trg_account_deactivated after insert on public.account_deactivations
  for each row execute function public.handle_account_deactivation();

--------------------------------------------------------------------------
-- v_account_list — same view as 015 plus the open deactivation period, so
-- the accounts page filters (`deactivated_at is null`) and labels without
-- a second query. Adding columns at the end keeps create-or-replace legal.
--
-- A join this time, unlike 015's scalar-subquery reasoning for
-- last_order_date: account_deactivations is a handful of app-written rows,
-- not a 41k-row fact table, and uq/idx above make the probe an index hit.
-- The count query pays a hash join over a tiny table — noise.
--
-- security_invoker, as always (011/015): without it this view would hand
-- every dealer to every rep.
--------------------------------------------------------------------------
create or replace view public.v_account_list
with (security_invoker = true)
as
select
    c.customer_key,
    c.customer_name,
    c.sold_to_city,
    c.sold_to_state,
    c.assigned_sales_rep_id,
    c.assigned_sales_rep_name,
    c.territory,
    c.active_flag,
    greatest(
        c.last_order_date,
        (select max(o.order_date)
           from erp.fact_order_line o
          where o.customer_key = c.customer_key)
    ) as last_order_date,
    d.deactivated_at,
    d.reason as deactivation_reason
from erp.dim_customer c
left join public.account_deactivations d
  on d.customer_key = c.customer_key
 and d.reactivated_at is null;

comment on view public.v_account_list is
  'The accounts list: dim_customer identity columns plus a last_order_date '
  'derived from order history (015) and the open portal deactivation period, '
  'if any (023). deactivated_at is null = the account is in play. '
  'security_invoker: the caller''s RLS applies throughout.';

--------------------------------------------------------------------------
-- refresh_account_signals — identical to 019 except the base CTE also
-- skips accounts with an open deactivation. Everything ranked or generated
-- reads account_signals, so this one predicate removes a deactivated
-- account from scoring, both admin previews, generate_recommendations()
-- and ai_batch_targets() alike; the stale-row sweep at the bottom clears
-- any row the trigger somehow missed.
--------------------------------------------------------------------------
create or replace function public.refresh_account_signals()
returns integer
language plpgsql
security definer set search_path = public, erp
as $$
declare
  v_started timestamptz := clock_timestamp();
  v_rows int;
begin
  with base as (
    select c.customer_key, c.yearly_sales_goal, c.last_order_date as dim_last_order
    from erp.dim_customer c
    where c.active_flag = 'Y'
      and coalesce(c.internal_customer_flag, 'N') <> 'Y'
      -- 023: the rep said stop. Out of scoring, out of everything scored.
      and not exists (
        select 1 from public.account_deactivations d
        where d.customer_key = c.customer_key
          and d.reactivated_at is null
      )
  ),
  inv as (
    select f.customer_key,
      sum(f.revenue) filter (
        where f.invoice_date > current_date - interval '12 months')     as revenue_12m,
      sum(f.revenue) filter (
        where f.invoice_date <= current_date - interval '12 months'
          and f.invoice_date >  current_date - interval '24 months')    as revenue_prior_12m
    from erp.fact_invoice_line f
    where f.is_memo is not true            -- NULL-safe; see the 011 header
      and f.invoice_date is not null
      and f.invoice_date > current_date - interval '24 months'
    group by 1
  ),
  ord as (
    select o.customer_key,
      max(o.order_date)                                          as last_order_date,
      sum(o.backlog_amount) filter (where o.is_backlog_line)      as open_backlog_amount
    from erp.fact_order_line o
    group by 1
  ),
  -- Distinct order DAYS, not order ids: three POs the same morning are one
  -- buying event, and counting them separately halves the apparent cadence
  -- of every dealer that batches its paperwork.
  order_days as (
    select o.customer_key, o.order_date
    from erp.fact_order_line o
    where o.order_date is not null
      and o.order_date > current_date - interval '24 months'
    group by 1, 2
  ),
  gaps as (
    select customer_key,
           order_date - lag(order_date) over (
             partition by customer_key order by order_date) as gap
    from order_days
  ),
  cadence as (
    select customer_key,
      count(*)::int                                             as order_days_24m,
      percentile_cont(0.5) within group (order by gap)::numeric as cadence_days,
      count(*) filter (where gap is not null)                   as gap_count
    from gaps
    group by 1
  ),
  touch as (
    select a.customer_key, max(a.action_date) as last_touch_date
    from public.actions a
    group by 1
  ),
  -- One pass, both windows: a family present in the prior year and absent in
  -- this one is the signal, so both flags come off the same grouped row.
  fam as (
    select f.customer_key, p.product_family,
      bool_or(f.invoice_date >  current_date - interval '12 months') as in_now,
      bool_or(f.invoice_date <= current_date - interval '12 months') as in_prior
    from erp.fact_invoice_line f
    join erp.dim_part p on p.part_key = f.part_key
    where f.is_memo is not true
      and f.invoice_date is not null
      and f.invoice_date > current_date - interval '24 months'
      and p.product_family is not null
    group by 1, 2
  ),
  fam_agg as (
    select customer_key,
      count(*) filter (where in_now)::int                   as families_12m,
      count(*) filter (where in_prior)::int                 as families_prior_12m,
      count(*) filter (where in_prior and not in_now)::int  as families_dropped
    from fam
    group by 1
  ),
  outcomes as (
    select r.customer_key,
      max(r.closed_at::date) filter (where r.outcome = 'order_received') as last_order_received_at,
      max(r.closed_at::date) filter (where r.outcome = 'false_positive') as last_false_positive_at
    from public.recommendations r
    where r.status in ('closed','dismissed') and r.closed_at is not null
    group by 1
  ),
  merged as (
    select
      b.customer_key,
      coalesce(i.revenue_12m, 0)::numeric        as revenue_12m,
      coalesce(i.revenue_prior_12m, 0)::numeric  as revenue_prior_12m,
      case when coalesce(i.revenue_prior_12m, 0) > 0
           then (coalesce(i.revenue_12m, 0) - i.revenue_prior_12m) / i.revenue_prior_12m
      end                                        as yoy_change,
      -- The 015 fix. dim_customer.last_order_date is unmaintained in this ERP
      -- and NULL for most accounts; greatest() ignores NULLs, so this is the
      -- real date wherever either source has one.
      greatest(b.dim_last_order, o.last_order_date) as last_order_date,
      cd.order_days_24m,
      cd.cadence_days,
      coalesce(cd.gap_count, 0) >= 2             as cadence_confident,
      t.last_touch_date,
      coalesce(fa.families_12m, 0)               as families_12m,
      coalesce(fa.families_prior_12m, 0)         as families_prior_12m,
      coalesce(fa.families_dropped, 0)           as families_dropped,
      coalesce(o.open_backlog_amount, 0)::numeric as open_backlog_amount,
      b.yearly_sales_goal,
      oc.last_order_received_at,
      oc.last_false_positive_at
    from base b
    left join inv     i  on i.customer_key  = b.customer_key
    left join ord     o  on o.customer_key  = b.customer_key
    left join cadence cd on cd.customer_key = b.customer_key
    left join touch   t  on t.customer_key  = b.customer_key
    left join fam_agg fa on fa.customer_key = b.customer_key
    left join outcomes oc on oc.customer_key = b.customer_key
    -- Scorable = some activity in 24 months. Everything else gets no row and
    -- is simply unranked, rather than sitting at the bottom of every list.
    where coalesce(i.revenue_12m, 0) <> 0
       or coalesce(i.revenue_prior_12m, 0) <> 0
       or coalesce(cd.order_days_24m, 0) > 0
  ),
  ranked as (
    select m.*, percent_rank() over (order by m.revenue_12m) as revenue_percentile
    from merged m
  ),
  upserted as (
    insert into public.account_signals as t (
      customer_key, computed_at,
      revenue_12m, revenue_prior_12m, revenue_percentile, yoy_change,
      last_order_date, days_since_order, order_days_24m, cadence_days,
      cadence_confident, last_touch_date, days_since_touch,
      families_12m, families_prior_12m, families_dropped,
      open_backlog_amount, yearly_sales_goal,
      last_order_received_at, last_false_positive_at
    )
    select
      -- v_started, NOT now(): now() is the TRANSACTION timestamp and is
      -- therefore always earlier than the clock_timestamp() captured above,
      -- so the stale-row delete below would sweep away every row this
      -- statement just wrote. One stamp, used for the write and the compare.
      r.customer_key, v_started,
      r.revenue_12m, r.revenue_prior_12m, r.revenue_percentile, r.yoy_change,
      r.last_order_date,
      case when r.last_order_date is not null
           then (current_date - r.last_order_date) end,
      r.order_days_24m, r.cadence_days,
      r.cadence_confident, r.last_touch_date,
      case when r.last_touch_date is not null
           then (current_date - r.last_touch_date) end,
      r.families_12m, r.families_prior_12m, r.families_dropped,
      r.open_backlog_amount, r.yearly_sales_goal,
      r.last_order_received_at, r.last_false_positive_at
    from ranked r
    on conflict (customer_key) do update set
      computed_at            = excluded.computed_at,
      revenue_12m            = excluded.revenue_12m,
      revenue_prior_12m      = excluded.revenue_prior_12m,
      revenue_percentile     = excluded.revenue_percentile,
      yoy_change             = excluded.yoy_change,
      last_order_date        = excluded.last_order_date,
      days_since_order       = excluded.days_since_order,
      order_days_24m         = excluded.order_days_24m,
      cadence_days           = excluded.cadence_days,
      cadence_confident      = excluded.cadence_confident,
      last_touch_date        = excluded.last_touch_date,
      days_since_touch       = excluded.days_since_touch,
      families_12m           = excluded.families_12m,
      families_prior_12m     = excluded.families_prior_12m,
      families_dropped       = excluded.families_dropped,
      open_backlog_amount    = excluded.open_backlog_amount,
      yearly_sales_goal      = excluded.yearly_sales_goal,
      last_order_received_at = excluded.last_order_received_at,
      last_false_positive_at = excluded.last_false_positive_at
    returning 1
  )
  select count(*)::int into v_rows from upserted;

  -- Accounts that left the ERP, went inactive, got deactivated in the
  -- portal, or fell out of the 24-month window. Without this they keep
  -- their last score forever. Rows written above carry
  -- computed_at = v_started exactly, so `<` spares them.
  delete from public.account_signals s
  where s.computed_at < v_started;

  perform public.log_job_run('refresh_account_signals', 'success',
                             v_rows::bigint, null, v_started);
  return v_rows;
end;
$$;

-- 019's revoke posture survives create-or-replace (the ACL rides the
-- function), but restate it: this remains job-only.
revoke execute on function public.refresh_account_signals()
  from public, anon, authenticated;

--------------------------------------------------------------------------
-- create_mission — identical to 016 except the active-only scope (the
-- default) also skips portal-deactivated accounts. p_active_only = false
-- remains the explicit "everything, even dead accounts" switch and
-- includes them.
--------------------------------------------------------------------------
create or replace function public.create_mission(
    p_title          text,
    p_reason         text default null,
    p_priority       text default 'normal',
    p_due_date       date default null,
    p_requires_visit boolean default false,
    p_scope_type     text default 'custom',
    p_scope_value    text default null,
    p_customer_keys  text[] default null,
    p_active_only    boolean default true,
    p_dry_run        boolean default false
)
returns table (batch_id bigint, created_count integer)
language plpgsql
security definer set search_path = public, erp
as $$
declare
  v_input_keys text[];
  v_keys       text[];
  v_batch      bigint;
begin
  if not public.is_admin() then
    raise exception 'not_admin';
  end if;
  if p_title is null or length(trim(p_title)) = 0 then
    raise exception 'missing_title';
  end if;
  if p_priority not in ('high','normal','low') then
    raise exception 'invalid_priority';
  end if;
  if p_scope_type not in ('all','vendor','rep','custom') then
    raise exception 'invalid_scope';
  end if;
  if p_scope_type in ('vendor','rep') and nullif(trim(coalesce(p_scope_value,'')), '') is null then
    raise exception 'missing_scope_value';
  end if;
  if p_scope_type = 'rep' and p_scope_value = any (public.placeholder_rep_keys()) then
    -- No person exists to do the work; a WEB/HOUSE mission would sit open forever.
    raise exception 'placeholder_rep_key';
  end if;

  if p_scope_type = 'custom' then
    select array_agg(distinct k) into v_input_keys
    from unnest(coalesce(p_customer_keys, '{}'::text[])) as k;
    if v_input_keys is null then
      raise exception 'empty_custom_scope';
    end if;
    -- Typos are silent no-ops otherwise: validate existence before filtering.
    if exists (
      select 1 from unnest(v_input_keys) k
      where not exists (select 1 from erp.dim_customer c where c.customer_key = k)
    ) then
      raise exception 'unknown_customer_keys';
    end if;
  end if;

  -- One scope resolution for preview and create alike. "Active" now means
  -- active in the ERP AND not deactivated in the portal (023).
  select array_agg(c.customer_key) into v_keys
  from erp.dim_customer c
  where (not p_active_only
         or (c.active_flag = 'Y'
             and not exists (
               select 1 from public.account_deactivations d
               where d.customer_key = c.customer_key
                 and d.reactivated_at is null)))
    and case p_scope_type
          when 'all'    then true
          when 'rep'    then c.assigned_sales_rep_id = p_scope_value
          when 'vendor' then exists (
              select 1 from erp.dim_sales_rep sr
              where sr.sales_rep_key = c.assigned_sales_rep_id
                and sr.vendor_id = p_scope_value
                and not (sr.sales_rep_key = any (public.placeholder_rep_keys())))
          when 'custom' then c.customer_key = any (v_input_keys)
        end;

  if p_dry_run then
    return query select null::bigint, coalesce(array_length(v_keys, 1), 0);
    return;
  end if;

  if v_keys is null then
    raise exception 'scope_resolved_empty';
  end if;

  insert into public.mission_batches
      (title, description, scope_type, scope_value, requires_visit, due_date, created_by)
  values
      (trim(p_title), nullif(trim(coalesce(p_reason,'')), ''), p_scope_type,
       nullif(trim(coalesce(p_scope_value,'')), ''), p_requires_visit, p_due_date, auth.uid())
  returning id into v_batch;

  insert into public.recommendations
      (customer_key, source, title, reason, priority, due_date,
       requires_visit, batch_id, created_by)
  select k, 'admin', trim(p_title), nullif(trim(coalesce(p_reason,'')), ''),
         p_priority, p_due_date, p_requires_visit, v_batch, auth.uid()
  from unnest(v_keys) as k;

  return query select v_batch, array_length(v_keys, 1);
end;
$$;

--------------------------------------------------------------------------
-- account_coverage / rep_execution_summary — same bodies as 006, minus
-- deactivated accounts. A store the rep wrote off must not sit in the
-- coverage denominator forever as "not contacted", and the admin's
-- assigned-accounts count should mean workable accounts. Column lists are
-- unchanged, so create-or-replace is safe. The open/overdue subqueries
-- need no predicate: the deactivation trigger dismisses that account's
-- open recommendations at the moment they would start to miscount.
--------------------------------------------------------------------------
create or replace view public.rep_execution_summary
with (security_invoker = true)
as
select
    p.user_id,
    p.full_name,
    p.rep_group_vendor_id,
    p.active,
    (select max(logged_at) from public.login_events le where le.user_id = p.user_id)         as last_login_at,
    (select count(*) from public.v_user_accounts ua
      where ua.user_id = p.user_id
        and not exists (
          select 1 from public.account_deactivations d
          where d.customer_key = ua.customer_key
            and d.reactivated_at is null))                                                   as assigned_accounts,
    (select count(*) from public.recommendations r
       join public.v_user_accounts ua on ua.customer_key = r.customer_key
      where ua.user_id = p.user_id and r.status = 'open')                                    as open_recommendations,
    (select count(*) from public.recommendations r
       join public.v_user_accounts ua on ua.customer_key = r.customer_key
      where ua.user_id = p.user_id and r.status = 'open' and r.due_date < current_date)      as overdue_recommendations,
    (select count(*) from public.actions a
      where a.user_id = p.user_id and a.action_date >= current_date - 30)                    as actions_last_30d,
    (select max(a.action_date) from public.actions a where a.user_id = p.user_id)            as last_action_date
from public.profiles p
where p.role = 'rep';

create or replace view public.account_coverage
with (security_invoker = true)
as
select
    ua.customer_key,
    ua.user_id,
    p.full_name                                   as rep_name,
    max(a.action_date)                            as last_contact_date,
    (max(a.action_date) >= current_date - 30)     as contacted_last_30d,
    (max(a.action_date) >= current_date - 90)     as contacted_last_90d
from public.v_user_accounts ua
join public.profiles p on p.user_id = ua.user_id
left join public.actions a
       on a.customer_key = ua.customer_key and a.user_id = ua.user_id
where not exists (
    select 1 from public.account_deactivations d
    where d.customer_key = ua.customer_key
      and d.reactivated_at is null
)
group by ua.customer_key, ua.user_id, p.full_name;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. supabase/tests/023_account_deactivations.sql covers RLS (rep A cannot
     see or write rep B's deactivations), the column-grant lockdown, the
     dismiss/de-score trigger, and the exclusions. Run it against dev.
  2. Regenerate frontend/src/types/database.types.ts — until then the
     frontend reads the table and the new v_account_list columns through the
     same untyped handle pattern as useAccounts.ts already uses.
  3. After the first nightly ETL with this applied, sanity-check that a
     deactivated account is absent from `select * from
     public.ai_batch_targets(5);` and from generate_recommendations() output
     (it will be, via account_signals — this is a belt check, not a fix).
----------------------------------------------------------------------------*/
