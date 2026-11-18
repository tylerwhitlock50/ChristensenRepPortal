/*============================================================================
  20261116130000_usage_events.sql — what the team actually looks at.

  Why
  ---
  login_events (006) answers "did they open the portal". It cannot answer the
  next question an admin asks: which pages, which accounts, how often, on a
  phone or at a desk. This adds that.

  What
  ----
  1. public.usage_events — one row per thing a signed-in user looked at or
     did: a page view (route name, and the account when the page is one
     account's), a download, a search. Small on purpose: an event name, the
     page, an optional account, the device class, and a small jsonb.

  2. log_usage(jsonb) — the only write path (no insert grant, like
     log_login()). SECURITY DEFINER, stamps auth.uid() and now() itself, so a
     client cannot log for someone else or backdate. Logs nothing while an
     admin is viewing as a rep: that is support work, not the rep's use, and
     must not move anybody's numbers (the same rule as useUsagePing.ts).
     Bounded: 20 events a call, 600 a user an hour, 1 KB of detail.

  3. admin_usage_report(days, user, include_admins) — the Admin › Usage page
     in one round trip: totals, by day, by page, by person, most-viewed
     accounts, downloads and searches, and the latest events. Admin-only:
     returns null to anyone else, and the table's only read policy is the
     admin's, so the function (SECURITY INVOKER) is not the boundary.

  Sweeps
  ------
  usage_events is a log written on a user's behalf, like login_events: it is
  outside the view-as read-only sweep and the inside-sales read-only sweep
  (inside sales' own use is logged too). Both tests' exempt lists name it.

  Days are business days: the database runs in America/Denver (20260901190000).

  Guarded by tests/20261116_usage_events.sql.
============================================================================*/

--------------------------------------------------------------------------
-- 1. The table
--------------------------------------------------------------------------
create table if not exists public.usage_events (
    id           bigint generated always as identity primary key,
    occurred_at  timestamptz not null default now(),
    user_id      uuid not null references public.profiles (user_id) on delete cascade,
    event        text not null,
    page         text,
    customer_key text,
    device       text check (device in ('phone', 'tablet', 'desktop')),
    detail       jsonb
);
alter table public.usage_events enable row level security;

create index if not exists idx_usage_events_time on public.usage_events (occurred_at desc);
create index if not exists idx_usage_events_user on public.usage_events (user_id, occurred_at desc);

comment on table public.usage_events is
  'Portal usage log: one row per page view (event = page_view, page = the '
  'route name, customer_key when the page is one account''s) or action '
  '(export, order_lookup, …). Written only by log_usage(); never while an '
  'admin is viewing as a rep. Read by admins (admin_usage_report()).';

drop policy if exists "admins read usage events" on public.usage_events;
create policy "admins read usage events" on public.usage_events
  for select to authenticated
  using ((select public.is_admin()));

revoke all on public.usage_events from anon, public, authenticated;
grant select on public.usage_events to authenticated;

--------------------------------------------------------------------------
-- 2. log_usage(): the only write path
--------------------------------------------------------------------------
create or replace function public.log_usage(p_events jsonb)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_count integer;
begin
  if v_uid is null or public.acting_as_user_id() is not null then
    return 0;
  end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' then
    return 0;
  end if;
  if not exists (select 1 from public.profiles p where p.user_id = v_uid) then
    return 0;
  end if;
  -- A runaway client (a redirect loop, a script) stops here, not in the table.
  if (select count(*) from public.usage_events e
      where e.user_id = v_uid and e.occurred_at > now() - interval '1 hour') >= 600 then
    return 0;
  end if;

  insert into public.usage_events (user_id, event, page, customer_key, device, detail)
  select
    v_uid,
    e.item ->> 'event',
    nullif(left(btrim(e.item ->> 'page'), 64), ''),
    nullif(left(btrim(e.item ->> 'customer_key'), 64), ''),
    case when e.item ->> 'device' in ('phone', 'tablet', 'desktop')
         then e.item ->> 'device' end,
    case when jsonb_typeof(e.item -> 'detail') = 'object'
              and octet_length((e.item -> 'detail')::text) <= 1024
         then e.item -> 'detail' end
  from (
    select item
    from jsonb_array_elements(p_events) with ordinality as a (item, n)
    where jsonb_typeof(item) = 'object'
    order by n
    limit 20
  ) e
  where (e.item ->> 'event') ~ '^[a-z][a-z0-9_]{0,39}$';

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function public.log_usage(jsonb) is
  'Appends the caller''s usage events ([{event, page, customer_key, device, '
  'detail}]). Stamps auth.uid() and now(); logs nothing while viewing as a '
  'rep. At most 20 events a call and 600 a user an hour. Returns rows written.';

revoke execute on function public.log_usage(jsonb) from public, anon;
grant execute on function public.log_usage(jsonb) to authenticated;

--------------------------------------------------------------------------
-- 3. admin_usage_report(): the Admin › Usage page
--------------------------------------------------------------------------
create or replace function public.admin_usage_report(
  p_days           integer default 30,
  p_user_id        uuid    default null,
  p_include_admins boolean default false
)
returns jsonb
language plpgsql stable set search_path = public
as $$
declare
  v_days  integer := least(greatest(coalesce(p_days, 30), 1), 365);
  v_from  date    := current_date - (v_days - 1);
  v_out   jsonb;
begin
  if not public.is_admin() then
    return null;
  end if;

  with people as (
    select p.user_id, p.full_name, p.email, p.role, p.active,
           p.rep_group_vendor_id, p.sales_rep_key
    from public.profiles p
    where (p_include_admins or p.role <> 'admin')
      and (p_user_id is null or p.user_id = p_user_id)
  ),
  ev as (
    select e.*, e.occurred_at::date as day
    from public.usage_events e
    join people p on p.user_id = e.user_id
    where e.occurred_at >= v_from
  ),
  views as (select * from ev where event = 'page_view'),
  totals as (
    select jsonb_build_object(
      'views',        (select count(*) from views),
      'users',        (select count(distinct user_id) from ev),
      'phone_views',  (select count(*) from views where device = 'phone'),
      'device_views', (select count(*) from views where device is not null),
      'actions',      (select count(*) from ev where event <> 'page_view'),
      'accounts',     (select count(distinct customer_key) from views
                       where customer_key is not null)
    ) as j
  ),
  by_day as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'day', d.day, 'views', coalesce(v.views, 0), 'users', coalesce(v.users, 0))
             order by d.day), '[]'::jsonb) as j
    from (select generate_series(v_from, current_date, interval '1 day')::date as day) d
    left join (
      select day,
             count(*) filter (where event = 'page_view') as views,
             count(distinct user_id)                     as users
      from ev group by day
    ) v on v.day = d.day
  ),
  by_page as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'page', page, 'views', views, 'users', users,
             'phone_views', phone_views, 'last_at', last_at)
             order by views desc, page), '[]'::jsonb) as j
    from (
      select coalesce(page, '(unknown)') as page,
             count(*)                                as views,
             count(distinct user_id)                 as users,
             count(*) filter (where device = 'phone') as phone_views,
             max(occurred_at)                        as last_at
      from views group by 1
    ) x
  ),
  top_page as (
    select distinct on (user_id) user_id, page, n
    from (select user_id, page, count(*) as n from views
          where page is not null group by 1, 2) x
    order by user_id, n desc, page
  ),
  per_user as (
    select user_id,
           count(*) filter (where event = 'page_view')                      as views,
           count(distinct day)                                              as active_days,
           max(occurred_at)                                                 as last_at,
           count(*) filter (where event = 'page_view' and device = 'phone') as phone_views,
           count(distinct customer_key) filter (where event = 'page_view')  as accounts,
           count(*) filter (where event = 'export')                         as exports
    from ev group by user_id
  ),
  by_user as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', p.user_id, 'full_name', p.full_name, 'email', p.email,
             'role', p.role, 'active', p.active,
             'rep_group', p.rep_group_vendor_id, 'sales_rep_key', p.sales_rep_key,
             'views', coalesce(u.views, 0), 'active_days', coalesce(u.active_days, 0),
             'last_at', u.last_at, 'phone_views', coalesce(u.phone_views, 0),
             'accounts', coalesce(u.accounts, 0), 'exports', coalesce(u.exports, 0),
             'top_page', t.page)
             order by coalesce(u.views, 0) desc, p.full_name), '[]'::jsonb) as j
    from people p
    left join per_user u on u.user_id = p.user_id
    left join top_page t on t.user_id = p.user_id
    -- Someone switched off who never used it is not a row worth reading.
    where p.active or u.user_id is not null
  ),
  by_account as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'customer_key', x.customer_key, 'customer_id', c.customer_id,
             'customer_name', c.customer_name, 'views', x.views,
             'users', x.users, 'last_at', x.last_at)
             order by x.views desc, x.customer_key), '[]'::jsonb) as j
    from (
      select customer_key, count(*) as views, count(distinct user_id) as users,
             max(occurred_at) as last_at
      from views where customer_key is not null
      group by customer_key
      order by count(*) desc, customer_key
      limit 100
    ) x
    left join erp.dim_customer c on c.customer_key = x.customer_key
  ),
  by_action as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'event', event, 'what', what, 'page', page,
             'count', n, 'users', users, 'last_at', last_at)
             order by n desc, event, what), '[]'::jsonb) as j
    from (
      select event,
             coalesce(detail ->> 'report', detail ->> 'what', '') as what,
             coalesce(page, '')                                   as page,
             count(*) as n, count(distinct user_id) as users, max(occurred_at) as last_at
      from ev where event <> 'page_view'
      group by 1, 2, 3
    ) x
  ),
  recent as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', x.id, 'at', x.occurred_at, 'user_id', x.user_id,
             'full_name', p.full_name, 'event', x.event, 'page', x.page,
             'customer_key', x.customer_key, 'customer_name', c.customer_name,
             'device', x.device, 'detail', x.detail)
             order by x.occurred_at desc, x.id desc), '[]'::jsonb) as j
    from (select * from ev order by occurred_at desc, id desc limit 200) x
    join people p on p.user_id = x.user_id
    left join erp.dim_customer c on c.customer_key = x.customer_key
  )
  select jsonb_build_object(
    'days', v_days, 'from', v_from, 'through', current_date,
    'first_event_at', (select min(occurred_at) from public.usage_events),
    'totals', (select j from totals),
    'by_day', (select j from by_day),
    'by_page', (select j from by_page),
    'by_user', (select j from by_user),
    'by_account', (select j from by_account),
    'by_action', (select j from by_action),
    'recent', (select j from recent)
  ) into v_out;

  return v_out;
end;
$$;

comment on function public.admin_usage_report(integer, uuid, boolean) is
  'Admin › Usage in one call: page views and actions over the last p_days '
  '(1–365, business days) — totals, by day, by page, by person (everyone '
  'active, zeros included), most-viewed accounts, actions and the latest 200 '
  'events. p_user_id narrows to one person; admins'' own use is left out '
  'unless p_include_admins. Null for a non-admin.';

revoke execute on function public.admin_usage_report(integer, uuid, boolean) from public, anon;
grant execute on function public.admin_usage_report(integer, uuid, boolean) to authenticated;
