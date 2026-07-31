# supabase/functions

Two Supabase Edge Functions (Deno + TypeScript). Exactly two, because
TECH_STACK §3.2 admits only code that holds a secret or needs `service_role`:

| Function | Why it can't be client-side |
|---|---|
| `ai-account-summary` | Holds `ANTHROPIC_API_KEY` |
| `admin-create-user` | Needs `service_role` to create auth users and set passwords (PRD: no self-signup) |

Everything else — reads, writes, photo upload/download — goes straight to
PostgREST and Storage with the user's JWT. If a third candidate appears, the
first question is "can this be a Postgres function with `security definer`
instead?" (usually yes).

```
functions/
├── _shared/
│   ├── cors.ts              CORS headers, preflight, json()/fail()
│   └── supabase.ts          userClient() vs serviceClient(), HttpError
├── ai-account-summary/
│   ├── index.ts             the flow in TECH_STACK §5.1, in order
│   └── prompt.md            THE prompt — versioned file, not a string literal
└── admin-create-user/
    └── index.ts
```

## Secrets

Set these once per project (`dev` and `prod` are separate projects — §8):

| Secret | Used by | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | `ai-account-summary` | Edge Function secrets **only**. Never in Vercel, never in the frontend bundle. |
| `SUPABASE_SERVICE_ROLE_KEY` | `admin-create-user` | Auto-injected by the platform on deploy; set explicitly only for `supabase functions serve`. |
| `SUPABASE_URL` | both | Auto-injected. |
| `SUPABASE_ANON_KEY` | both | Auto-injected. Used to build the caller-scoped client that then carries the user's `Authorization` header. |

```bash
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
supabase secrets list
```

### Optional tuning (all have defaults; no redeploy needed to change)

| Variable | Default | What it does |
|---|---|---|
| `AI_SUMMARY_DAILY_LIMIT` | `25` | Accounts a single user can generate summaries for per UTC day. `0` disables the cap. |
| `AI_SUMMARY_MIN_INVOICE_LINES` | `5` | Below this, with no notes, the function returns "Not enough activity to summarize" without calling the API. |
| `AI_SUMMARY_COOLDOWN_SECONDS` | `60` | Minimum gap between two *paid* generations for the same account. Cached returns are unaffected. |
| `CORS_ALLOWED_ORIGIN` | `*` | Pin to the Vercel origin if you ever move to cookie auth. |

## Deploy

```bash
supabase link --project-ref <project-ref>

supabase functions deploy ai-account-summary --no-verify-jwt
supabase functions deploy admin-create-user  --no-verify-jwt
```

**Why `--no-verify-jwt`.** The gateway's built-in check rejects the browser's
CORS preflight, which by spec carries no `Authorization` header. Both functions
verify the caller themselves and do strictly more than the gateway would:

- `ai-account-summary` resolves the user from their JWT and then asks Postgres
  `has_account_access(customer_key)` **as that user**.
- `admin-create-user` resolves the user and then calls `is_admin()` **as that
  user**, before `service_role` is constructed at all.

An unauthenticated request reaches the function and gets a `401` from our own
code. If you prefer the gateway check, drop the flag and handle the preflight
at the CDN instead — but do not remove the in-function checks either way.

`ai-account-summary` reads `prompt.md` at runtime from its own directory, so
always deploy the **directory**, never a single file.

## Local development

```bash
supabase start
supabase functions serve --env-file ./supabase/.env.local
```

`.env.local` (git-ignored) needs `ANTHROPIC_API_KEY`, and
`SUPABASE_SERVICE_ROLE_KEY` if you're exercising `admin-create-user`.

```bash
# ai-account-summary
curl -i -X POST http://localhost:54321/functions/v1/ai-account-summary \
  -H "Authorization: Bearer $USER_JWT" \
  -H "Content-Type: application/json" \
  -d '{"customer_key":"12345"}'

# admin-create-user
curl -i -X POST http://localhost:54321/functions/v1/admin-create-user \
  -H "Authorization: Bearer $ADMIN_JWT" \
  -H "Content-Type: application/json" \
  -d '{"email":"rep@example.com","password":"correct-horse-battery",
       "full_name":"Dana Rep","role":"rep","sales_rep_key":"AB"}'
```

## ai-account-summary

**Request** `POST { "customer_key": "..." }`

**Response** `200` with `{ status, summary, ... }`:

| `status` | Meaning | Tokens spent |
|---|---|---|
| `generated` | Fresh call to Claude; `summary` is the stored row | yes |
| `cached` | Context hash unchanged since last time | no |
| `cooldown` | Context changed but the last generation is younger than the cooldown; `summary` is the previous row, plus `retry_after_seconds` | no |
| `insufficient_data` | `summary` is `null`; `message` is `"Not enough activity to summarize"` | no |

Errors are `{ error: { code, message } }` with codes `no_auth`,
`invalid_token`, `no_access` (403), `daily_limit_reached` (429),
`ai_rate_limited` (429), `ai_unavailable` (504), `ai_error` / `ai_refused` (502).

**Cost controls, in the order they fire:** degradation gate → context hash →
per-account cooldown → per-user daily cap. The hash covers the context *plus*
`PROMPT_VERSION` and the model id, so a prompt change re-baselines every
account exactly once.

**Model.** `claude-sonnet-5`, one call, `effort: low`, thinking disabled. Note
there is deliberately no `temperature` — Sonnet 5 rejects a non-default
sampling parameter with a 400. Determinism comes from the prompt, the effort
level and the hash cache instead.

**Prompt caching** is on the system block (`cache_control: ephemeral`), which
is byte-identical across every account. The minimum cacheable prefix on
Sonnet 5 is ~1024 tokens; if you trim `prompt.md` below that, caching silently
stops working with no error. Check `cache_read_input_tokens` in the function
logs (`supabase functions logs ai-account-summary`) — a steady zero means
something is invalidating the prefix.

**Prompt versioning (§5.2).** `prompt.md`'s first line carries
`prompt-version: X.Y.Z`; `index.ts` exports a matching `PROMPT_VERSION`. The
function refuses to run if they disagree, because every `ai_summaries` row is
stamped with the version that produced it and the PRD's whole thesis is tuning
on outcomes.

**PII.** The context payload never includes `public.contacts` and carries no
author identity on notes, visits or actions (§5.1 — never send PII you don't
need). Note bodies are free text and are sent as written; that is the
substance of the note, not incidental identity.

**Revenue rollup.** The function prefers a pre-aggregated
`public.v_account_revenue_monthly` view and falls back to reading this one
customer's invoice lines directly when it doesn't exist yet. The fallback is
a single-customer, index-backed, 24-month-bounded read on the server — not the
browser-side fact-table aggregation TECH_STACK §3.3 forbids. When the view
lands, the function starts using it with no code change.

## admin-create-user

**Request** `POST`:

```json
{
  "email": "rep@example.com",
  "password": "at least 12 characters",
  "full_name": "Dana Rep",
  "role": "rep",
  "sales_rep_key": "AB",
  "rep_group_vendor_id": null,
  "active": true
}
```

**Response** `201` with `{ user_id, email, profile, warnings }`.

`warnings` is non-fatal: it flags a `sales_rep_key` that matches no row in
`erp.dim_sales_rep`, or a `rep_group_vendor_id` that matches no reps. Both
produce a user who can sign in and sees nothing, which is otherwise
indistinguishable from "the ETL hasn't run yet."

**Rejections:** `not_admin` (403), `invalid_email` / `weak_password` /
`invalid_role` / `missing_full_name` (400), `email_taken` (409), and
`placeholder_rep_key` (400) — `(Unknown)`, `WEB` and `HOUSE` are real rep IDs
in this ERP (`WEB` owns 52 live customers), so stamping one on a profile would
hand that user the placeholder's entire book. The list is read from
`public.placeholder_rep_keys()` rather than hard-coded, so emptying that array
relaxes both the SQL guard and this check together.

**Rollback.** If the profile update fails after the auth user is created, the
function deletes the auth user. If that cleanup also fails it returns
`profile_update_failed_orphan` naming the user id to delete by hand — an auth
account with a default profile can still sign in, so it must not be left
quietly behind.

**After creating a user**, the only remaining per-user setup is the ERP-derived
one: `sales_rep_key` for a rep, plus `rep_group_vendor_id` for a rep-group
principal. There is no bulk account-assignment exercise — ownership comes from
`erp.dim_customer.assigned_sales_rep_id` (TECH_STACK §3.4).
