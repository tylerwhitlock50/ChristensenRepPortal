-- Help article for the in-app change-password page (account menu →
-- Change password). Same rule as the starter articles: only inserted where
-- the slug is new, so an admin's edits in the portal survive a re-run.
insert into public.help_articles (slug, title, summary, category, sort_order, published, body)
values
('change-password', 'Changing your password', 'Pick a new password while you are signed in.', 'How to', 75, true,
$md$
Open the account menu (your initials, top right) and tap **Change password**. Enter your current password, then the new one twice, and save.

You stay signed in on the device you used. Any other phone, tablet, or computer signed in to your account is signed out and will ask for the new password.

Forgot the current one? Sign out and use **Forgot your password?** on the sign-in screen instead.
$md$)
on conflict (slug) do nothing;
