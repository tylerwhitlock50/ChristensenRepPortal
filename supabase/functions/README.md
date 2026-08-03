# supabase/functions

Four Supabase Edge Functions (Deno + TypeScript). Exactly four, because
TECH_STACK §3.2 admits only code that holds a secret or needs `service_role`:

| Function | Why it can't be client-side |
|---|---|
| `ai-account-summary` | Holds `OPENAI_API_KEY` |
| `ai-summary-batch` | Holds `OPENAI_API_KEY`; pre-generates briefings overnight |
| `admin-create-user` | Needs `service_role` to create auth users and set passwords (PRD: no self-signup) |
| `admin-update-user` | Needs `service_role` to set passwords and ban/unban sign-in on deactivate |

Everything else — reads, writes, photo upload/download — goes straight to
PostgREST and Storage with the user's JWT. If a third candidate appears, the
first question is "can this be a Postgres function with `security definer`
instead?" (usually yes).

```
functions/
├── _shared/
│   ├── cors.ts              CORS headers, preflight, json()/fail()
│   ├── supabase.ts          userClient() vs serviceClient(), HttpError
│   ├── accountContext.ts    the context payload + hashing, shared by both AI paths
│   └── aiSummary.ts         the model call, cost gates, generate-or-cache decision
├── ai-account-summary/
│   ├── index.ts             the flow in TECH_STACK §5.1, in order
│   └── prompt.ts            THE prompt — its own versioned module (see below)
├── ai-summary-batch/
│   └── index.ts             nightly pre-generation; the ONE service_role exception
├── admin-create-user/
│   └── index.ts
└── admin-update-user/
    └── index.ts
```

`accountContext.ts` and `aiSummary.ts` exist so the interactive and batch paths
cannot drift. Both derive the context hash the cache is keyed on; if they built
the context differently, the same unchanged account would look changed to one
and cached to the other, and the two would take turns paying to overwrite each
other's summary.

## Secrets

Set these once per project (`dev` and `prod` are separate projects — §8):

| Secret | Used by | Notes |
|---|---|---|
| `OPENAI_API_KEY` | `ai-account-summary`, `ai-summary-batch` | Edge Function secrets **only**. Never in Vercel, never in the frontend bundle. |
| `AI_BATCH_SECRET` | `ai-summary-batch` | The **only** thing standing between the batch and the internet — it authenticates nothing else. Generate with `openssl rand -hex 32` and give the same value to the ETL environment. |
| `SUPABASE_SERVICE_ROLE_KEY` | `admin-create-user`, `admin-update-user` | Auto-injected by the platform on deploy; set explicitly only for `supabase functions serve`. |
| `SUPABASE_URL` | both | Auto-injected. |
| `SUPABASE_ANON_KEY` | both | Auto-injected. Used to build the caller-scoped client that then carries the user's `Authorization` header. |

```bash
supabase secrets set OPENAI_API_KEY=sk-...
supabase secrets list
```

### Optional tuning (all have defaults; no redeploy needed to change)

| Variable | Default | What it does |
|---|---|---|
| `AI_SUMMARY_DAILY_LIMIT` | `25` | Accounts a single user can generate summaries for per UTC day. `0` disables the cap. |
| `AI_SUMMARY_MIN_INVOICE_LINES` | `5` | Below this, with no notes, the function returns "Not enough activity to summarize" without calling the API. |
| `AI_SUMMARY_COOLDOWN_SECONDS` | `60` | Minimum gap between two *paid* generations for the same account. Cached returns are unaffected. |
| `CORS_ALLOWED_ORIGIN` | `*` | Pin to the Vercel origin if you ever move to cookie auth. |
| `OPENAI_MODEL` | `gpt-5-mini` | Model id. Folded into the context hash, so changing it re-baselines every cached summary once. |
| `OPENAI_REASONING_EFFORT` | `minimal` | `minimal` / `low` / `medium` / `high`. Raise if summaries come back shallow; costs more per call. |

## Deploy

```bash
supabase link --project-ref <project-ref>

supabase functions deploy ai-account-summary --no-verify-jwt
supabase functions deploy ai-summary-batch   --no-verify-jwt
supabase functions deploy admin-create-user  --no-verify-jwt
supabase functions deploy admin-update-user  --no-verify-jwt
```

**Why `--no-verify-jwt`.** The gateway's built-in check rejects the browser's
CORS preflight, which by spec carries no `Authorization` header. Both functions
verify the caller themselves and do strictly more than the gateway would:

- `ai-account-summary` resolves the user from their JWT and then asks Postgres
  `has_account_access(customer_key)` **as that user**.
- `admin-create-user` and `admin-update-user` resolve the user and then call
  `is_admin()` **as that user**, before `service_role` is constructed at all.

An unauthenticated request reaches the function and gets a `401` from our own
code. If you prefer the gateway check, drop the flag and handle the preflight
at the CDN instead — but do not remove the in-function checks either way.

`ai-summary-batch` is the exception to the pattern above: it has no caller and
no JWT. It authenticates a constant-time match on `x-batch-secret`, and it is
the only function that constructs `serviceClient()` without first resolving a
user. Its file header argues why that is narrow rather than a hole — read it
before changing anything there. The short version: a nightly job answers no
browser, returns only counts, cannot be pointed at an account (the request
body carries no `customer_key`), and writes rows whose read path is still
RLS-scoped.

## ai-summary-batch

**Request** `POST` with `x-batch-secret`, body `{ "per_rep": 5 }` (optional,
also `max_accounts`). **Response** `200` with a tally:
`{ targets, attempted, generated, cached, skipped, insufficient, failed }`.

Targets come from `public.ai_batch_targets(p_per_rep)` — each active rep's
highest-scoring accounts that have open work, minus anything resolved inside
the rule cooldown, deduped so an account that is top-N for both a rep and their
group principal is generated once. Rows are written with `generated_by = null`
so an overnight run never consumes a rep's `AI_SUMMARY_DAILY_LIMIT`.

Wired into the ETL's `post_load_http` (`etl/views.yml`), so it runs on fresh
data right after `generate_recommendations()`. Best-effort by design: a failed
batch logs and moves on rather than failing a good data load.

| Variable | Default | What it does |
|---|---|---|
| `AI_BATCH_PER_REP` | `5` | Accounts per rep per run. |
| `AI_BATCH_MAX_ACCOUNTS` | `100` | Hard ceiling per run. Overruns are logged, never silent. |
| `AI_BATCH_CONCURRENCY` | `3` | Parallel model calls. Raising this is how a nightly job earns a rate limit. |
| `AI_BATCH_MIN_AGE_HOURS` | `20` | Skip accounts summarised more recently than this. |

The prompt is a **module** (`prompt.ts`), imported by `index.ts`. It used to be
`prompt.md` read at runtime with `Deno.readTextFile()`, and that does not
survive deployment: the bundler builds from the import graph, so a markdown
file nobody imports is silently dropped and every request dies on
`prompt_missing`. Do not move it back to a data file that is only read at
runtime — if it is not imported, it does not ship.

## Local development

```bash
supabase start
supabase functions serve --env-file ./supabase/.env.local
```

`.env.local` (git-ignored) needs `OPENAI_API_KEY`, and
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
| `generated` | Fresh call to OpenAI; `summary` is the stored row | yes |
| `cached` | Context hash unchanged since last time | no |
| `cooldown` | Context changed but the last generation is younger than the cooldown; `summary` is the previous row, plus `retry_after_seconds` | no |
| `insufficient_data` | `summary` is `null`; `message` is `"Not enough activity to summarize"` | no |

Errors are `{ error: { code, message } }` with codes `no_auth`,
`invalid_token`, `no_access` (403), `daily_limit_reached` (429),
`ai_rate_limited` (429), `ai_unavailable` (504), and `ai_error` /
`ai_refused` / `ai_empty` / `ai_truncated` (502).

**Cost controls, in the order they fire:** degradation gate → context hash →
per-account cooldown → per-user daily cap. The hash covers the context *plus*
`PROMPT_VERSION` and the model id, so a prompt change re-baselines every
account exactly once.

**Model.** `gpt-5-mini` via Chat Completions, one call, `reasoning_effort:
minimal`. Note there is deliberately no `temperature` — gpt-5 reasoning models
accept only the default and 400 on anything else. Determinism comes from the
prompt, the effort level and the hash cache instead.

Two parameter names are load-bearing and easy to get wrong:

- `max_completion_tokens`, **not** `max_tokens` — the gpt-5 family rejects the
  latter outright.
- That budget covers **reasoning tokens as well as the visible reply**, and
  reasoning is spent first. It is set to 2000 for a ~150-word answer for
  exactly that reason; sizing it to the answer returns an empty message with
  `finish_reason: length`, surfaced as `ai_truncated`. Unused budget is not
  billed.

**Prompt caching** is automatic on OpenAI above ~1024 tokens — there is no
field to set. What matters is ordering: the system prompt is the first message
and is byte-identical across every account, so it forms a shared prefix. Any
account-specific content placed before it would break that prefix for every
account. The prompt is ~1280 tokens today; trim it below ~1024 and caching
silently stops with no error. Check `cached_tokens` in the function logs
(`supabase functions logs ai-account-summary`) — a steady zero means something
is invalidating the prefix.

**Switching models.** `OPENAI_MODEL` overrides the default with no redeploy.
The model id is folded into the context hash, so a change re-baselines every
cached summary exactly once — the same property `prompt_version` has. That is
also why moving off Claude did not require clearing `ai_summaries`.

**Prompt versioning (§5.2).** `prompt.ts` exports `PROMPT_VERSION` alongside
`SYSTEM_PROMPT`, so the version and the text it describes live in one file and
cannot desync. Bump the version whenever you change the text: every
`ai_summaries` row is stamped with the version that produced it and the PRD's
whole thesis is tuning on outcomes. The version is also folded into the context
hash, so a bump regenerates every account exactly once.

This replaced an earlier scheme where `prompt.md` carried a `prompt-version:`
marker that `index.ts` compared against its own constant at runtime. Two
sources of truth needed a check to keep them honest; one source needs no
check, so `prompt_version_missing` and `prompt_version_mismatch` no longer
exist.

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

## admin-update-user

**Request** `POST` — `user_id` plus at least one of `password` / `active`:

```json
{ "user_id": "uuid", "password": "at least 12 characters", "active": false }
```

**Response** `200` with `{ user_id, updated, warnings }`.

- `password` → `auth.admin.updateUserById` sets the new password.
- `active: false` → an auth ban (~100 years) blocks refresh and future
  sign-ins, then `profiles.active = false`. If the profile write fails the
  ban is reverted so auth and profile can't disagree. `warnings` notes that
  the current access token survives up to ~an hour and that explicit
  `account_assignments` grant rows keep working until removed.
- `active: true` → lifts the ban and restores `profiles.active`.

**Rejections:** `not_admin` (403), `invalid_user_id` / `weak_password` /
`nothing_to_do` / `cannot_deactivate_self` (400), `user_not_found` (404).

Profile fields (name, role, `sales_rep_key`, `rep_group_vendor_id`) are NOT
handled here — the admin edits them with a plain client-side `profiles`
update under the `"admin manages profiles"` policy; the placeholder-rep-key
rule is enforced in the database (migration 016).
