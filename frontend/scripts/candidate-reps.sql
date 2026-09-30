-- Reps who placed orders in the last 12 months and have no portal account.
-- Feeds bulk-create-users.mjs: paste the id/name/company_name/email columns
-- into a CSV (extra columns are ignored by the script).
--
-- Excluded on purpose: placeholder / unknown rep codes (migration 010), and
-- anyone whose sales_rep_key already appears on a profile. Rows with a null
-- email still show up here so they can be chased down — the script refuses
-- them until an email is filled in.
with recent as (
  select sales_rep_key,
         count(*)                    as order_lines_12mo,
         count(distinct customer_key) as customers_12mo,
         max(order_date)             as last_order
  from erp.fact_order_line
  where order_date >= current_date - interval '1 year'
  group by sales_rep_key
)
select sr.sales_rep_key                as id,
       sr.sales_rep_name               as name,
       coalesce(sr.vendor_id, 'Christensen Arms (' || sr.sales_rep_type || ')') as company_name,
       lower(sr.sales_rep_email)       as email,
       r.order_lines_12mo,
       r.customers_12mo,
       r.last_order,
       sr.sales_rep_type
from erp.dim_sales_rep sr
join recent r on r.sales_rep_key = sr.sales_rep_key
where not coalesce(sr.is_placeholder_rep, false)
  and not coalesce(sr.is_unknown_sales_rep, false)
  and not exists (select 1 from public.profiles p where p.sales_rep_key = sr.sales_rep_key)
order by sr.sales_rep_type, sr.vendor_id nulls last, sr.sales_rep_key;
