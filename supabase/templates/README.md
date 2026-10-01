# Auth email templates

Supabase sends these; the Dashboard is the only place they can be set
(**Authentication → Email Templates**). This folder is the versioned copy —
paste the file's contents into the matching template after changing it here.

| Template | File | Why it is not the default |
|---|---|---|
| Reset Password | `recovery.html` | The default `{{ .ConfirmationURL }}` is a one-shot GoTrue `/verify` link that is consumed by the first HTTP fetch. Outlook's link scanner fetches every reset link seconds after delivery (see the auth logs: a `HEAD /verify` from a Microsoft address, then a `GET` that "logs in", then the rep's real tap a minute later getting *Email link is invalid or has expired*). This template links straight to the app with the token hash, and the app only calls `verifyOtp` when the rep presses **Save password** — a scanner loading the page spends nothing. |

The link uses `{{ .RedirectTo }}`, which is the `redirectTo` the app passed
(`<origin>/reset-password`) when it is on the project's redirect allow-list,
and the Site URL otherwise. The router forwards a recovery credential to
`/reset-password` from any route, so a missing allow-list entry degrades to
a working flow rather than a dead one — but keep the list current anyway, so
the link opens the reset page directly.

Required Dashboard settings (**Authentication → URL Configuration**):

- Site URL: `https://carms.app`
- Redirect URLs: `https://carms.app/reset-password`, `http://localhost:5231/reset-password`
  (and whatever port `npm run dev` is served on locally).
