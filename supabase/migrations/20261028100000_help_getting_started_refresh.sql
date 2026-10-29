/*============================================================================
  20261028100000_help_getting_started_refresh.sql — two help articles still
  say the data loads once a day.

  Why
  ---
  Two starter articles (seeded by 20260908120000_help_and_support.sql) still
  describe the once-a-day load:
    getting-started  "When is the data current?" says the warehouse loads
                     every evening at about 5 PM and points at a "Data
                     through" stamp.
    find-an-order    its last tip says an order entered this afternoon is not
                     loaded until tonight, and points at the same stamp.
  Since 27–28 Oct the loads run in tiers on the BI server (etl/views.yml
  profiles, etl/schedule/Register-CrmTasks.ps1): stock every 15 minutes,
  orders / shipments / invoices hourly on weekdays, and full runs at 04:30
  daily and 17:00 on weekdays. The stamp now reads "Invoiced through … ·
  Orders through … · Loaded …" (FreshnessStamp.vue; "Orders through" only
  when it differs, "Loaded" always). In stock has its own "Stock as of".
  Reps coming off Tableau read these articles first (G10).

  What
  ----
  Replace that paragraph and that tip, each only while it is still the
  seeded text. The starter articles can be edited by an admin in the portal,
  so an admin's rewrite keeps its wording, and a re-run changes nothing. The
  times match the "Why the portal and Tableau numbers differ" article
  (20261027090700).
============================================================================*/

update public.help_articles
   set body = replace(
         body,
         $old$The warehouse loads every evening at about 5 PM Mountain. The **Data through** stamp on the Overview tells you the newest invoice date loaded. Anything that shipped after that shows up tomorrow.$old$,
         $new$On weekdays the figures refresh through the day: stock every 15 minutes from 5 AM to 6 PM, and orders, shipments and invoices every hour from 6 AM to 4 PM. Everything refreshes at 4:30 AM every day and at 5 PM on weekdays. All times are Mountain.

The stamp at the top of the Overview says how current the page is, for example *Invoiced through Oct 27, 2026 · Orders through Oct 28, 2026 · Loaded 2:05 PM*. Invoicing can run a day or two behind shipping, so the invoiced date is often earlier than today. **In stock** shows its own *Stock as of* time.

Coming from Tableau? *Why the portal and Tableau numbers differ* (also under Start here) explains the few places the two count differently.$new$)
 where slug = 'getting-started'
   and position($old$The warehouse loads every evening at about 5 PM Mountain.$old$ in body) > 0;

update public.help_articles
   set body = replace(
         body,
         $old$- If nothing comes up, check the **Data through** date — an order entered this afternoon will not be loaded until tonight.$old$,
         $new$- If nothing comes up, the order may be newer than the last load. On weekdays orders load every hour from 6 AM to 4 PM and again at 5 PM; every day at 4:30 AM. All times are Mountain. The *Loaded* time on the Overview stamp says when the last load finished.$new$)
 where slug = 'find-an-order'
   and position($old$an order entered this afternoon will not be loaded until tonight.$old$ in body) > 0;
