/*============================================================================
  008_recommendation_engine.sql
  Purpose: The nightly recommendation generator. A plain SQL function the
           scheduler calls AFTER the ETL lands fresh erp data:

             select public.generate_recommendations();

           Run it either as the last step of the ETL job (recommended — it
           runs the moment fresh data exists) or via pg_cron:

             select cron.schedule('generate-recommendations',
                                  '30 5 * * *',
                                  $$select public.generate_recommendations()$$);

  Idempotent: the unique partial index uq_recs_open_rule guarantees at most
  one OPEN system recommendation per (customer, rule); re-runs no-op via
  ON CONFLICT. Closed/dismissed recs do NOT block a rule re-firing later —
  if an account goes quiet again next quarter it gets flagged again.

  Rules read their thresholds from public.rule_settings.params so the admin
  tunes them with an UPDATE, not a deploy.

  SECURITY: intended to be run as service_role / postgres (bypasses RLS).
  Not exposed to app users — REVOKE at the bottom.
============================================================================*/

create or replace function public.generate_recommendations()
returns table (out_rule_key text, out_created int)
language plpgsql
security definer set search_path = public, erp
as $$
declare
  v_params jsonb;
  v_created int;
  v_started timestamptz := clock_timestamp();
  v_total   int := 0;
begin
  ------------------------------------------------------------------
  -- Rule: no_order_days — active accounts with real history whose
  -- last order is older than N days
  ------------------------------------------------------------------
  select params into v_params
  from public.rule_settings rs
  where rs.rule_key = 'no_order_days' and rs.enabled;

  if found then
    with quiet_accounts as (
      select
        c.customer_key,
        c.customer_name,
        c.last_order_date,
        current_date - c.last_order_date as days_quiet,
        coalesce((
          select sum(f.revenue) from erp.fact_invoice_line f
          where f.customer_key = c.customer_key
            and f.invoice_date >= current_date - 365
            and not f.is_memo
        ), 0) as trailing_12m_revenue
      from erp.dim_customer c
      where c.active_flag = 'Y'
        and coalesce(c.internal_customer_flag, 'N') <> 'Y'
        and c.last_order_date is not null
        and c.last_order_date < current_date - (v_params ->> 'days')::int
    ),
    ins as (
      insert into public.recommendations
        (customer_key, source, rule_key, title, reason, priority)
      select
        q.customer_key,
        'system',
        'no_order_days',
        'No order in ' || q.days_quiet || ' days',
        q.customer_name || ' last ordered on ' || q.last_order_date ||
          '. Trailing-12-month revenue $' || round(q.trailing_12m_revenue)::text ||
          '. Contact the buyer and find out why.',
        case when q.trailing_12m_revenue >= 50000 then 'high' else 'normal' end
      from quiet_accounts q
      where q.trailing_12m_revenue >= (v_params ->> 'min_trailing_12m_revenue')::numeric
      on conflict (customer_key, rule_key) where status = 'open' and source = 'system'
        do nothing
      returning 1
    )
    select count(*) into v_created from ins;
    v_total := v_total + coalesce(v_created, 0);
    out_rule_key := 'no_order_days'; out_created := coalesce(v_created, 0);
    return next;
  end if;

  ------------------------------------------------------------------
  -- Rule: yoy_decline — YTD revenue down > X% vs same period last year
  ------------------------------------------------------------------
  select params into v_params
  from public.rule_settings rs
  where rs.rule_key = 'yoy_decline' and rs.enabled;

  if found then
    with ytd as (
      select
        f.customer_key,
        sum(f.revenue) filter (
          where f.invoice_date >= date_trunc('year', current_date)
        ) as cur_ytd,
        sum(f.revenue) filter (
          where f.invoice_date >= date_trunc('year', current_date) - interval '1 year'
            and f.invoice_date <  current_date - interval '1 year'
        ) as prior_ytd
      from erp.fact_invoice_line f
      where not f.is_memo
        and f.invoice_date >= date_trunc('year', current_date) - interval '1 year'
      group by f.customer_key
    ),
    declining as (
      select
        y.customer_key,
        c.customer_name,
        coalesce(y.cur_ytd, 0)  as cur_ytd,
        y.prior_ytd,
        round(100.0 * (1 - coalesce(y.cur_ytd, 0) / y.prior_ytd)) as decline_pct
      from ytd y
      join erp.dim_customer c on c.customer_key = y.customer_key
      where c.active_flag = 'Y'
        and coalesce(c.internal_customer_flag, 'N') <> 'Y'
        and y.prior_ytd >= (v_params ->> 'min_prior_ytd_revenue')::numeric
        and coalesce(y.cur_ytd, 0) < y.prior_ytd * (1 - (v_params ->> 'decline_pct')::numeric / 100.0)
    ),
    ins as (
      insert into public.recommendations
        (customer_key, source, rule_key, title, reason, priority)
      select
        d.customer_key,
        'system',
        'yoy_decline',
        'Revenue down ' || d.decline_pct || '% YoY',
        d.customer_name || ' is at $' || round(d.cur_ytd)::text || ' YTD vs $' ||
          round(d.prior_ytd)::text || ' this time last year (down ' || d.decline_pct ||
          '%). Verify inventory, ask about competitors, and review fall programs.',
        case when d.prior_ytd >= 100000 then 'high' else 'normal' end
      from declining d
      on conflict (customer_key, rule_key) where status = 'open' and source = 'system'
        do nothing
      returning 1
    )
    select count(*) into v_created from ins;
    v_total := v_total + coalesce(v_created, 0);
    out_rule_key := 'yoy_decline'; out_created := coalesce(v_created, 0);
    return next;
  end if;

  perform public.log_job_run('generate_recommendations', 'success',
                             v_total::bigint, null, v_started);
  return;
end;
$$;

-- Job-only: app users cannot run the generator
revoke execute on function public.generate_recommendations() from public, anon, authenticated;
