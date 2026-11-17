-- Help article 'portal-vs-tableau-numbers': the worked example no longer
-- carries a real account's figures. 20261116090000 renamed the account to
-- "Dealer 1005" but kept its real revenue, order and credit-memo amounts,
-- which every signed-in rep can read. The amounts below are made up and
-- round; they still show the same four differences (credit memos, shipped
-- value, cancelled orders, same-days year over year).
-- replace(), not a re-seed, so an admin's edits to the rest of the article
-- are kept. Re-running it is a no-op.
update public.help_articles
   set body = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(
         body,
         '$443,933', '$250,000'),
         '−$6,494', '−$4,000'),
         '$442,975', '$248,500'),
         '$480,122', '$275,000'),
         '3 cancelled orders worth $90,959', '2 cancelled orders worth $30,000'),
         '$407,845', '$230,000'),
         '$342,249', '$200,000'),
         'up 19%', 'up 15%'),
         '(to October 26)', '(to late October)'),
         '## Worked example: Dealer 1005', '## Worked example: Dealer 1005 (made-up figures)')
 where slug = 'portal-vs-tableau-numbers'
   and body like '%$443,933%';
