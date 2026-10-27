-- Help article: why a portal figure and a Tableau figure can disagree (G10).
-- Linked from the Sales Intel layout / freshness stamp by its slug, so the
-- slug is a contract with the frontend. Unlike the starter articles this is
-- an upsert: the text below is what was reviewed against the data on
-- 2026-10-26 (Midway USA figures from erp.fact_invoice_line,
-- fact_shipment_line, fact_order_line and agg_account_rollup that day), and
-- a re-run should restore it. An admin can still edit it in the portal
-- afterwards; the deployer applies this file once.
insert into public.help_articles (slug, title, summary, category, sort_order, published, body)
values
('portal-vs-tableau-numbers', 'Why the portal and Tableau numbers differ',
 'Revenue, shipped value, orders, open orders and stock: what each portal number counts, and when it updates.',
 'Start here', 25, true,
$md$
The portal and Tableau read the same ERP, but they do not always count the same things. When two numbers disagree, it is almost always one of these.

## Revenue is invoiced, nothing else

Revenue (YTD, sales, goal %) counts an order only once it is **invoiced**. Shipping can happen a day or two before the invoice, so the portal shows shipment dollars separately as **Shipped value**: the packlist value, quantity × price less trade discount. Shipped value is never revenue.

Credit memos are left out of revenue.

## Cancelled orders never count

Orders and bookings leave out cancelled orders. Tableau's include them, so its order totals can be higher.

## Year over year means the same days

"vs last year" compares this year to date with the **same days last year**. Tableau compares it with the whole of last year, which makes most accounts look behind until December.

## Goal %

Goal % is invoiced revenue ÷ the yearly goal. On pace or behind is judged against a seasonal pace (how far through its year the account usually is by this date), not a straight line.

## Open orders

Open orders are every line still owed: Released, Firmed and Hold. The value is net of the order's discount and credit lines.

## Stock

In stock counts only sellable rack stock: SHIPPING locations R01–R09. Staging, components, international and stage locations are reserved and do not count.

## Rounding

Order values on account pages are rounded to whole dollars.

## Worked example: Midway USA

- **2025 revenue (invoiced):** $443,933. The year's credit memos (−$6,494) are not taken off.
- **2025 shipped value:** $442,975, the value of the year's packlists.
- **2025 orders:** $480,122, leaving out 3 cancelled orders worth $90,959. Tableau's order total includes them.
- **2026 so far (to October 26):** $407,845 invoiced against $342,249 over the same days of 2025, up 19%. Tableau sets $407,845 against all of 2025 ($443,933) and shows Midway behind.

## When the figures update

- **Stock:** every 15 minutes on weekdays, 5 AM to 6 PM.
- **Orders, shipments and invoices:** every hour on weekdays, 6 AM to 4 PM.
- **Everything:** a full refresh at 4:30 AM every day and 5 PM on weekdays.

All times are Mountain. The stamp at the top of each page says when the figures you are looking at were loaded.
$md$)
on conflict (slug) do update
   set title      = excluded.title,
       summary    = excluded.summary,
       category   = excluded.category,
       sort_order = excluded.sort_order,
       published  = excluded.published,
       body       = excluded.body;
