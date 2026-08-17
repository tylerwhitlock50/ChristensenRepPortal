--------------------------------------------------------------------------
-- v_data_freshness: add orders_through (newest order_date).
--
-- Why: "Data through Aug 13" read as "the warehouse is four days stale"
-- when invoicing in the ERP was merely behind shipping — orders and
-- shipments were current through the load date. The stamp now shows both
-- dates so a rep can tell an ETL problem from a billing lag.
--
-- data_through keeps its meaning (newest non-memo invoice date): the MCP
-- whoami tool, the AI brief prompt, and goal pace all document it as the
-- revenue horizon. Renamed nowhere; only the portal label changes.
--
-- OWNER-rights exception re-justified (024 said not to widen the column
-- list without doing so): the new column is again a single warehouse-wide
-- timestamp derived by MAX over a table reps cannot read directly. Three
-- timestamps still structurally cannot leak account data.
--------------------------------------------------------------------------
create or replace view public.v_data_freshness as
select
    (select max(j.finished_at)
       from public.job_runs j
      where j.status = 'success'
        and j.job_name like 'etl:%')                 as data_loaded_at,
    (select max(f.invoice_date)
       from erp.fact_invoice_line f
      where f.is_memo is not true)                   as data_through,
    (select max(o.order_date)
       from erp.fact_order_line o)                   as orders_through;

revoke all on public.v_data_freshness from anon, public;
grant select on public.v_data_freshness to authenticated;

comment on view public.v_data_freshness is
  'One row: last successful ETL finish time, newest non-memo invoice date '
  '(data_through — the revenue horizon), and newest order entry date '
  '(orders_through). OWNER-rights on purpose (documented exception): output '
  'is three timestamps and nothing else. Powers the freshness stamp.';
