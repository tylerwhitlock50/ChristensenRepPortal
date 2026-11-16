-- Help article 'portal-vs-tableau-numbers': the worked example no longer names
-- a real customer. "Midway USA" becomes the made-up "Dealer 1005"; the
-- figures are unchanged (they are still the ones reviewed on 2026-10-26).
-- A replace(), not a re-seed of the body, so any edit an admin has made in
-- the portal since 20261027090700 is kept. Re-running it is a no-op.
update public.help_articles
   set body = replace(replace(body, 'Midway USA', 'Dealer 1005'), 'Midway', 'the dealer')
 where slug = 'portal-vs-tableau-numbers'
   and body like '%Midway%';
