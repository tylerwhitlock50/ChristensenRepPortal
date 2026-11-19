-- Help article 'sales-intel': Sales Intel no longer has a "Backlog" tab. It
-- and "Open orders" were two cuts of the same open order lines, and are now
-- one tab with a By order / By SKU switch (20261119130000).
--
-- replace(), not a re-seed of the body, so any edit an admin has made in the
-- portal since 20260908120000 is kept; each statement matches only the
-- seeded wording, so re-running it is a no-op.
update public.help_articles
   set body = replace(
         body,
         '- **Backlog** — every open line by SKU, filterable by account. Use it before you call a dealer who is asking "when?".',
         '- **Open orders** — every open order line in your book. **By order** lists them under each account and order; **By SKU** adds them up by SKU for each account. Pick the account before you call a dealer who is asking "when?".')
 where slug = 'sales-intel'
   and body like '%- **Backlog** — every open line by SKU%';

update public.help_articles
   set title = 'Sales Intel: SKU sales, open orders, ATS, global'
 where slug = 'sales-intel'
   and title = 'Sales Intel: SKU sales, backlog, ATS, global';
