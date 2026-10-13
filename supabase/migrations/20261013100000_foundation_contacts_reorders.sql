/*============================================================================
  20261013100000_foundation_contacts_reorders.sql
  Purpose: Two reads the account page's "who do I call" and "what do they
  reorder" need: a printable contact name, and the account's in-stock
  repeat buys.

  1. v_account_contacts.display_name
  ----------------------------------
  The view's `name` is coalesce(contact_name, contact_id) on the ERP arm, so
  a buyer whose ERP row has first_name / last_name but no contact_name shows
  up as '0027284'. display_name is what to PRINT:

      ERP rows   contact_name when it is a name (not a bare id)
                 → first_name + ' ' + last_name
                 → contact_name / contact_id (the old answer)
      rep rows   name

  `name` itself is untouched — ContactForm, the MCP list_contacts tool and
  035's tests read it, and lib/contacts.ts falls back to it on a database
  without this column. create-or-replace rules (same as 032/034): column
  positions are fixed, so display_name goes LAST and nothing above it moves.

  Ranking (billing / AP / internal demotion) is deliberately NOT in SQL. It
  lives in frontend/src/lib/contacts.ts with unit tests, needs the
  account's invoice_email / statement_email, and is a heuristic that will be
  tuned — a view column every consumer bakes in is the wrong home for that.

  2. public.report_reorder_candidates(p_customer_key, p_limit)
  ------------------------------------------------------------
  "Bought before and in stock now": the account's own repeat buys from
  erp.agg_sku_month (36 whole months + the current partial one, rebuilt
  nightly — 20260901190100), with each part's buying rhythm, joined to
  today's available-to-sell. A part is DUE when the last buy month plus the
  median gap between buy months has arrived.

  SECURITY INVOKER, unlike report_account_sku_gaps: everything read here is
  the caller's to see. agg_sku_month's policy is is_admin() or
  customer_key in my_customer_keys() — both view-as aware (20260816140000) —
  so another rep's account, or one that does not exist, simply has no rows.
  fact_available_to_sell and dim_part are readable by every authenticated
  user (032, 002/007), and every dim_part column used here survives the
  column-level grants of 20260901190300. No guard to forget, no company-wide
  aggregate per call.

  Same screens as report_account_sku_gaps (036 / 20260818212142): finished
  firearms only (no 'component' product codes; family or chambering must be
  real), and only parts with at least 1 available to sell.
============================================================================*/

--------------------------------------------------------------------------
-- 1. display_name, appended last.
--------------------------------------------------------------------------
create or replace view public.v_account_contacts
with (security_invoker = true)
as
select
    'rep-' || c.id::text  as contact_key,
    'rep'::text           as source,
    c.id,
    c.customer_key,
    c.name,
    c.title,
    c.phone,
    c.email,
    c.is_primary,
    c.notes,
    c.updated_at,
    -- Rep-entered: no ERP instruction attached. See 034.
    false                 as do_not_call,
    false                 as do_not_email,
    c.name                as display_name
from public.contacts c
union all
select
    'erp-' || e.customer_contact_key,
    'erp',
    null::bigint,
    e.customer_key,
    coalesce(e.contact_name, e.contact_id),
    nullif(e.position, ''),
    coalesce(nullif(e.phone, ''), nullif(e.mobile, '')),
    nullif(e.email, ''),
    e.primary_contact_flag = 'Y',
    null::text,
    null::timestamptz,
    -- See 034: the flag for the number the row actually exposes.
    case
        when nullif(e.phone, '')  is not null then e.do_not_call_phone_flag  = 'Y'
        when nullif(e.mobile, '') is not null then e.do_not_call_mobile_flag = 'Y'
        else false
    end,
    coalesce(e.do_not_email_flag = 'Y', false),
    coalesce(
        -- contact_name, unless it is itself just an id
        case when btrim(e.contact_name) !~ '^[0-9#[:space:]-]*$'
             then btrim(e.contact_name) end,
        nullif(btrim(concat_ws(' ', btrim(e.first_name), btrim(e.last_name))), ''),
        nullif(btrim(e.contact_name), ''),
        e.contact_id
    )
from erp.dim_customer_contact e
-- Source keeps inactive assignments; the CRM shows active people only.
where e.contact_active_flag = 'Y';

comment on view public.v_account_contacts is
  'Merged contacts for one account: rep-entered rows (source=rep, editable, '
  'id set) plus active ERP contacts (source=erp, read-only). Always query '
  'with .eq(customer_key). security_invoker — RLS of both source tables '
  'applies. do_not_call/do_not_email carry the ERP contact-preference flags; '
  'do_not_call describes the number in THIS row''s phone column (landline '
  'when present, else mobile), not the contact in general. display_name is '
  'the name to print (ERP: contact_name, else first + last, else the id); '
  'name keeps its old meaning. Ranking lives in frontend/src/lib/contacts.ts.';

revoke all on public.v_account_contacts from anon, public;
grant select on public.v_account_contacts to authenticated;

--------------------------------------------------------------------------
-- 2. Reorder candidates.
--------------------------------------------------------------------------
create or replace function public.report_reorder_candidates(
    p_customer_key  text,
    p_limit         int default 10
)
returns table (
    part_key                    text,
    part_id                     text,
    part_description            text,
    product_code                text,
    product_family              text,
    chambering                  text,
    barrel_length               text,
    upc                         text,
    ats_qty                     numeric,
    last_bought_month           date,
    last_qty                    numeric,
    total_qty                   numeric,
    months_with_buys            int,
    median_months_between_buys  numeric,
    expected_next_month         date,
    is_due                      boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
    with buys as (
        -- RLS on agg_sku_month is the scope (see header). Months with a net
        -- return (qty <= 0) are not buys.
        select
            m.part_key,
            m.sales_month,
            m.qty,
            extract(year from m.sales_month)::int * 12
              + extract(month from m.sales_month)::int as month_no
        from erp.agg_sku_month m
        where m.customer_key = p_customer_key
          and m.qty > 0
    ),
    gaps as (
        select
            b.*,
            b.month_no - lag(b.month_no) over (
                partition by b.part_key order by b.sales_month
            ) as gap_months
        from buys b
    ),
    rhythm as (
        select
            g.part_key,
            max(g.sales_month)                                   as last_bought_month,
            (array_agg(g.qty order by g.sales_month desc))[1]    as last_qty,
            sum(g.qty)                                           as total_qty,
            count(*)::int                                        as months_with_buys,
            -- NULL gaps (each part's first buy) are ignored, so one buy
            -- month gives a NULL median.
            round(percentile_cont(0.5) within group (order by g.gap_months)::numeric, 1)
                                                                 as median_gap
        from gaps g
        group by g.part_key
    ),
    ats as (
        select a.part_key, sum(a.available_to_sell_qty) as ats_qty
        from erp.fact_available_to_sell a
        where a.part_key in (select r.part_key from rhythm r)
        group by a.part_key
        having sum(a.available_to_sell_qty) >= 1          -- sellable today; see 027
    ),
    scored as (
        select
            r.*,
            s.ats_qty,
            case when r.median_gap is not null
                 then (r.last_bought_month
                       + make_interval(months => round(r.median_gap)::int))::date
            end as expected_next_month
        from rhythm r
        join ats s on s.part_key = r.part_key
    )
    select
        sc.part_key,
        p.part_id,
        p.part_description,
        p.product_code,
        p.product_family,
        p.chambering,
        p.barrel_length,
        p.upc,
        sc.ats_qty,
        sc.last_bought_month,
        sc.last_qty,
        sc.total_qty,
        sc.months_with_buys,
        sc.median_gap,
        sc.expected_next_month,
        coalesce(sc.expected_next_month <= date_trunc('month', current_date)::date, false)
    from scored sc
    join erp.dim_part p on p.part_key = sc.part_key
    -- Finished firearms only. Mirrors report_account_sku_gaps / isGunRow().
    where coalesce(p.product_code, '') !~* 'component'
      and (
            coalesce(nullif(btrim(p.product_family), ''), 'N/A') <> 'N/A'
         or coalesce(nullif(btrim(p.chambering), ''), 'N/A')     <> 'N/A'
      )
    order by
        coalesce(sc.expected_next_month <= date_trunc('month', current_date)::date, false) desc,
        sc.months_with_buys desc,
        sc.last_bought_month desc,
        sc.part_key
    limit greatest(1, least(coalesce(p_limit, 10), 50));
$$;

comment on function public.report_reorder_candidates(text, int) is
  'In-stock parts this account has bought before, with their buying rhythm: '
  'last buy month and qty, total qty and buy months over the agg_sku_month '
  'window (36 whole months + current), median months between buys, the '
  'month the next buy is expected, and is_due once that month arrives. '
  'Finished firearms with available_to_sell >= 1 only. Due first, then '
  'most-repeated, then most recent; p_limit clamped to 1..50. SECURITY '
  'INVOKER — RLS on erp.agg_sku_month (my_customer_keys(), view-as aware) '
  'decides which accounts return anything.';

revoke execute on function public.report_reorder_candidates(text, int)
  from public, anon;
grant execute on function public.report_reorder_candidates(text, int)
  to authenticated;
