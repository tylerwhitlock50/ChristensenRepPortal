# Sales Execution Portal — Tech Stack & Architecture Decisions

**Companion to:** [PRD.md](PRD.md)
**Owner:** Tyler Whitlock
**Date:** 2026-07-31
**Status:** Draft for review

This document turns the PRD's platform line ("Vue 3 SPA on Vercel; Supabase")
into a concrete, buildable stack. Where the PRD left a decision open, this
document makes a recommendation and states the reasoning so it can be argued
with rather than rediscovered.

---

## 0. TL;DR

| Layer | Choice | Why |
|---|---|---|
| Frontend framework | **Vue 3.5 + Vite + TypeScript** (SPA, no SSR) | PRD-committed; internal portal has no SEO/SSR need |
| Routing / state | **Vue Router 4**, **Pinia** (session only), **TanStack Query (vue-query)** for all server data | Server state ≠ client state; caching/refetch is the whole job |
| UI kit | **Tailwind v4 + shadcn-vue (reka-ui)** + **TanStack Table** for admin grids | Accessible primitives, mobile-first, no theme fight |
| Forms | **vee-validate + zod** | Visit survey is the one complex form; schema shared with DB constraints |
| Charts | **Chart.js via vue-chartjs** | 2–3 simple charts (PRD §7); ECharts/D3 is overkill |
| Mobile | **vite-plugin-pwa** + IndexedDB draft queue + client-side image compression | Reps are in stores with bad signal; a lost survey is worse than a slow one |
| API / data plane | **Supabase PostgREST + RLS** — no bespoke REST layer | RLS is the security boundary; a Node API in front of it would duplicate it |
| Server-side code | **Supabase Edge Functions (Deno/TS)** — 2 of them | Only for things that need a secret or service_role |
| Database | **Supabase Postgres**: `erp` (read, ETL-owned) + `public` (app, RLS) | Established in migrations 001–010 |
| Auth | **Supabase Auth**, admin-created users, signups disabled | PRD §7; already wired via `handle_new_user()` trigger |
| Account access | **Derived from the ERP hierarchy** (rep = `assigned_sales_rep_id`, group = `dim_sales_rep.vendor_id`) + grant/revoke overrides | §3.4 — no manual assignment exercise, always current, makes the P1 principal role nearly free |
| Files | **Supabase Storage**, private bucket + signed URLs | Photos are dealer-premises images; never public |
| ETL | **Python + Docker**, SQL Server → Postgres, truncate-and-load in one transaction per table | Existing tooling; transactional `TRUNCATE` means readers never see an empty table |
| Nightly jobs | **SQL function called by the ETL scheduler**, `pg_cron` as fallback | Runs on fresh data, idempotent in SQL, auditable |
| AI | **Claude API (Sonnet 5) via Edge Function**, cached summaries | Direct call beats MCP for a fixed-shape prompt |
| MCP | **Dev-time now; product feature in M3** | See §6 — genuinely useful, but not in the v1 request path |
| CI/CD | **GitHub Actions** (migrations, tests) + **Vercel** (frontend) | Two triggers, no orchestration needed |
| Monorepo | **pnpm workspaces** | `frontend/`, `etl/`, `supabase/`, `docs/` in one repo |

---

## 1. Constraints this stack has to respect

Pulled straight from the PRD; every choice below is downstream of these.

1. **The ERP path is one-way and read-only.** Nothing in the app stack may hold
   a SQL Server write credential. The only process that touches SQL Server is
   the ETL, and it only runs `SELECT`.
2. **RLS is the security boundary, not the UI.** A rep hitting the API directly
   with their own JWT must get nothing outside their book (PRD acceptance
   criterion #1). This rules out any architecture where a server component uses
   `service_role` to fetch data "on behalf of" a rep — that pattern moves the
   boundary into application code, where it will eventually leak.
3. **Phone-first, in the field.** Visit logging happens in a dealer's store on
   LTE. Sub-60-second survey completion (PRD acceptance criterion #5) with a
   photo means the client must not be shipping 4 MB images over a bad
   connection, and must not lose the survey if the connection drops.
4. **Low data literacy.** The UI budget goes to clarity, not features. This
   argues for a small component set used consistently, not a kitchen-sink kit.
5. **Mid order season.** Time-to-v1 is the dominant cost. Every "we could build
   our own X" is a no.

---

## 2. Frontend

### 2.1 Framework: Vite SPA, not Nuxt

The PRD says "Vue 3 SPA on Vercel." Worth stating why I'd *keep* it there
rather than upgrade to Nuxt, since Nuxt is the reflexive choice for a Vue app
on Vercel:

- Nuxt's main wins are SSR/SEO and server routes. This is a login-walled
  internal portal — SEO is worth zero.
- Server routes sound attractive as "a place for the Anthropic key," but
  Supabase Edge Functions already provide that, and we need Edge Functions
  regardless (admin user creation needs `service_role` near the database).
  Nuxt would add a *second* server runtime for no new capability.
- Nuxt SSR + Supabase auth means moving to cookie-based sessions and dealing
  with hydration of RLS-scoped data. That is real complexity in exchange for a
  faster first paint on an app users open once a day and keep open.

**Decision: Vite SPA.** Revisit only if we ever need a public-facing surface.

### 2.2 Core packages

```
vue                     ^3.5
vue-router              ^4
pinia                   ^3        # session/user/role only — NOT server data
@tanstack/vue-query     ^5        # every read from Supabase goes through this
@supabase/supabase-js   ^2
@vueuse/core            ^13
vee-validate + zod                # visit survey, contact forms
tailwindcss             ^4
shadcn-vue / reka-ui              # accessible headless primitives
@tanstack/vue-table     ^8        # admin coverage + execution grids
vue-chartjs + chart.js            # the 2–3 account charts
date-fns                          # no moment, no dayjs plugins sprawl
vite-plugin-pwa                   # installable + offline shell
idb-keyval                        # draft queue (see 2.5)
browser-image-compression         # resize photos before upload
```

Pin exact versions at scaffold time; the majors above are what matters.

### 2.3 State management: the one rule that keeps this app simple

**Pinia holds only: the auth session, the current user's profile/role, and UI
preferences. Everything that comes from the database goes through TanStack
Query.**

This sounds pedantic but it's the difference between a maintainable app and a
pile of `loading`/`error`/`data` triples. Concretely, TanStack Query gives you,
for free, the things this PRD actually asks for:

- The rep dashboard's activity feed refetching on window focus (rep leaves the
  app, comes back after a call, sees fresh data).
- Optimistic updates when closing a recommendation, so the phone UI feels
  instant on LTE.
- Cache invalidation: logging a visit invalidates the account's activity list
  and the "needs attention" count in one line, instead of manual refresh calls
  scattered across components.

Query key convention — flat, explicit, easy to invalidate:

```ts
['account', customerKey]
['account', customerKey, 'orders']
['account', customerKey, 'recommendations']
['me', 'needs-attention']
['admin', 'coverage', { from, to }]
```

### 2.4 UI kit: Tailwind + shadcn-vue — **decided**

The realistic alternatives were PrimeVue and Vuetify. Both get you an admin
DataTable faster on day one. Tailwind + shadcn-vue wins because:

- The rep-facing screens (the 90% of usage) are *custom* layouts — a to-do
  list, an account summary card, a survey. Component kits don't help there and
  their opinionated styling actively fights mobile-first custom design.
- shadcn-vue copies components into your repo. When a rep says "the outcome
  picker is confusing," you edit the component instead of fighting a library's
  theme API.
- The one place a kit genuinely wins — admin data grids — is covered by
  TanStack Table, which is headless and pairs with Tailwind cleanly.

**The honest cost of this choice:** PRD acceptance criterion #4 wants the
untouched-accounts list to export and filter cleanly. That is a built-in prop
on PrimeVue's `DataTable` and roughly an hour of work with TanStack Table plus
a small CSV helper (see `packages/shared` — the export shape should be shared
with the P1 activity export anyway). That hour is the entire delta, and it buys
an unconstrained field UI on the screens reps actually live in.

**Guardrail:** shadcn-vue components are *copied into the repo*, not imported.
Copy them in as they're needed and treat them as project code from that moment
— don't build a speculative component library up front. If a component starts
carrying business logic (the outcome picker, the survey question types), it
belongs in `frontend/src/components/`, not in the `ui/` folder alongside the
generic primitives.

Design constraint for the field UI, given persona #1: **minimum 44px touch
targets, no hover-only affordances, no horizontal scroll, and every destructive
or state-changing action confirmed inline rather than in a modal.**

### 2.5 Offline behavior (the requirement hiding in "phone-first")

Not in the PRD explicitly, but implied by acceptance criterion #5 and by where
reps physically are. Recommended for v1 because retrofitting it is painful:

- **Survey draft persistence.** Every keystroke in the visit survey writes to
  IndexedDB (`idb-keyval`) under a draft key. If the app is killed, backgrounded
  by a phone call, or loses signal, the draft survives.
- **Submit queue.** On submit failure, the payload (plus photo blobs) stays
  queued and retries on reconnect via a `navigator.onLine` listener. The UI
  says "Saved — will sync when you're back online," which is honest and stops
  the rep re-entering it.
- **Photo compression before upload.** `browser-image-compression` to ~1600px
  / ~300 KB before it hits Storage. This is both a UX fix (upload succeeds on
  bad signal) and the answer to PRD open question on Storage cost ceilings — a
  4 MB phone photo becomes ~300 KB, so a rep logging 5 photos/visit × 200
  visits/season is ~300 MB, not 4 GB.

**This ships in v1** — decided, not deferred. The reasoning is adoption, not
engineering taste: PRD goal #3 needs ≥90% of reps logging in weekly, and the
personas are low-data-literacy field agents who are not obligated to use this
tool. A rep who drives to a dealer, spends a minute on a survey, and watches it
vanish will not trust the app again — and won't tell you, they'll just stop.
That's a permanent loss against the one goal the whole product depends on.
Retrofitting also means rewriting the submit path, so the "save time now"
argument is mostly illusory.

**Scope discipline — what is deliberately excluded**, so this stays ~a day and
not a two-week service-worker project:

| In v1 | Not in v1 |
|---|---|
| Draft written to IndexedDB on change (debounced ~500ms) | Offline *reading* of accounts / dashboard |
| Retry queue for failed submits, flushed on `navigator.onLine` | Background Sync API / service-worker-mediated retry |
| Honest UI state: "Saved — will sync when you're back online" | Conflict resolution (surveys are append-only; there's nothing to conflict) |
| Draft restored if the app is killed or backgrounded | Queue for anything other than visit surveys + their photos |
| Photo blobs held in IndexedDB alongside the draft | Sync status UI beyond a single pending-count badge |

Read caching (viewing accounts offline) stays out — it's a genuinely larger
problem, and reps can open an account before they walk into the store.

---

## 3. Backend / data plane

### 3.1 There is no application server

The default and correct path for nearly every operation is:

```
Vue app (user's JWT)  →  Supabase PostgREST  →  Postgres + RLS
```

Reads come from views and tables; writes go straight to app tables with RLS
policies enforcing ownership. No Express/Fastify/Nest layer. Adding one would
mean either (a) it forwards the user's JWT and does nothing but add latency, or
(b) it uses `service_role` and re-implements RLS in TypeScript, which violates
constraint #2 above.

### 3.2 What actually needs server-side code

Exactly two Supabase Edge Functions (Deno/TypeScript), each justified by
holding a secret or needing `service_role`:

| Function | Why it can't be client-side |
|---|---|
| `ai-account-summary` | Holds `ANTHROPIC_API_KEY` |
| `admin-create-user` | Needs `service_role` to create auth users + set passwords (PRD: no self-signup) |

Photo upload/download does **not** need a function: the private bucket's
Storage RLS (`009_storage.sql`) gates both directions on
`has_account_access()` via the object path (`<customer_key>/<file>`), so
supabase-js talks to Storage directly with the user's JWT. Revisit signed
URLs only if per-rep upload quotas become necessary.

If a third candidate appears, the first question should be "can this be a
Postgres function with `security definer` instead?" — usually yes, and that
keeps the logic next to the data and inside the same transaction.

### 3.3 Database shape (already established, stated for completeness)

```
erp.*      ETL-owned, truncate-and-load, app has SELECT only
public.*   app-owned, RLS on every table
```

Already in the migrations: `job_runs` (010 — the ETL and
`generate_recommendations()` both write to it) and `login_events` written via
the `log_login()` security-definer RPC with no client insert policy (006).

Still to add when the account page gets built:

- **`public.v_*` views for the read paths the UI actually uses.** The account
  mini-dashboard needs current-vs-prior-year revenue and a 12-month order
  history. Doing that as a client-side aggregation over `erp.fact_invoice_line`
  would ship thousands of rows to a phone. Make it
  `public.v_account_revenue_monthly` etc., defined once, with RLS applied via
  `has_account_access()`. **The UI should never aggregate ERP facts
  client-side.**
- **Materialize the expensive ones.** If the monthly rollups are slow, make
  them materialized views refreshed by the ETL at the end of its run. The data
  is only daily-fresh anyway, so there's no staleness cost.

### 3.4 Account ownership: derived from the ERP, with an override layer — **decided**

The ERP already carries the entire ownership hierarchy — both levels:

| Concept | ERP source | Landed as |
|---|---|---|
| **Individual rep** (owns the account) | `vw_DimCustomer.AssignedSalesRepID` (customer-header `SALESREP_ID`) | `erp.dim_customer.assigned_sales_rep_id` |
| **Rep group / agency** (the rep works for) | `vw_DimSalesRep.VendorID` (`SALES_REP.VENDOR_ID`) | `erp.dim_sales_rep.vendor_id` |

Migration 003 already anticipated the first with `profiles.sales_rep_key`.

**So assignment is derived, not hand-maintained.** `account_assignments`
survives, but demoted from *the* record of ownership to an override/expansion
layer. Access resolves in three tiers plus overrides:

```
admin                                                → everything
OR  rep:        profiles.sales_rep_key
                  = erp.dim_customer.assigned_sales_rep_id            (own book)
OR  principal:  profiles.rep_group_vendor_id
                  = erp.dim_sales_rep.vendor_id
                    of the account's assigned rep                     (group book)
OR  an explicit grant row in public.account_assignments               (override)
MINUS any explicit revoke row                                          (override)
```

Why this shape rather than either extreme:

- **Zero assignment admin on day one.** Every account has an owner already, so
  the portal is fully populated the moment the ETL runs. No 2,000-row
  assignment exercise mid-season. The only per-user setup is stamping
  `sales_rep_key` (and `rep_group_vendor_id` for principals) on the profile.
- **It stays current for free.** Rep-group turnover handled in the ERP shows up
  in the portal the next morning. The PRD's "deactivate a user and reassign
  their accounts" story is mostly solved by the ERP change already happening.
- **The rep-group principal role gets cheap.** PRD P1 lists "rep-group
  principal role that aggregates their reps' books" as a fast-follow. Because
  `SALES_REP.VENDOR_ID` already models the agency, that aggregation is one
  extra branch in `has_account_access()` and one index — not a hierarchy to
  design or maintain. **Build the access branch in v1** even though the
  principal-facing UI stays P1; the expensive part is the access model, and
  retrofitting it into RLS later means re-testing every policy.
- **Overrides cover what the ERP can't:** house accounts, temporary coverage,
  a rep working an account they don't own, and immediate changes that
  shouldn't wait for an ERP edit + overnight load.

**Schema status: implemented.** `profiles` carries `sales_rep_key` and
`rep_group_vendor_id` (the free-text `rep_group` is gone),
`account_assignments` has the `access` grant/revoke column, and
`has_account_access()` (003) plus the `v_user_accounts` view (006) implement
exactly the resolution above. Access never resolves off free text.

Implementation notes:

- `has_account_access()` gains the derived branches. Keep it `security definer`
  and `stable` as it already is. Index `erp.dim_customer (assigned_sales_rep_id)`
  and `erp.dim_sales_rep (vendor_id)` — every RLS check hits both.
- **Null keys must never match each other.** This is the sharpest edge in the
  whole design. Plenty of `SALES_REP` rows will have a null `VENDOR_ID`
  (house/internal codes), and plenty of profiles will have a null
  `rep_group_vendor_id` (ordinary reps, who don't need the group branch). Bare
  SQL equality is safe here — `null = null` is `null`, not true — but the
  usual "helpful" rewrites are catastrophic: `is not distinct from` makes every
  null-vendor rep a principal over every null-vendor account, and
  `coalesce(vendor_id,'')` does the same thing more quietly. **Write the branch
  with explicit `is not null` guards on both sides** and leave a comment saying
  why, because it looks like a redundant check to the next person reading it.
- **Placeholder reps must never grant access.** `WEB`, `HOUSE`, and
  `(Unknown)` are real rep IDs in this data. (There is no placeholder flag on
  `vw_DimSalesRep` — only `IsUnknownSalesRep` — so this is enforced by two
  things: `has_account_access()` hard-excludes null and `(Unknown)` keys, and
  profiles are admin-created only, so a house code never gets stamped on one.
  Don't add a flag column for this; the admin discipline plus the guard is
  enough for an internal tool.)
- Both of the above go in the RLS test suite as named cases — a rep with a null
  `sales_rep_key`, a rep with `sales_rep_key = 'HOUSE'`, and a profile with a
  null `rep_group_vendor_id` must each return zero rows. These are the two ways
  this design fails open, and both fail *silently and totally*.
- **Support negative overrides.** Add `access` (`'grant' | 'revoke'`) to
  `account_assignments` so an account can be pulled from its ERP owner without
  editing the ERP. Revoke beats derive.
- Coverage math (`% of assigned accounts contacted`) uses the same resolution,
  so the denominator is every account with a real owner — no account can hide
  from the coverage report by being unassigned.
- Since `erp` is truncate-and-loaded, ownership can change silently. Have the
  ETL diff `assigned_sales_rep_id` against the prior load and write changes to
  `job_runs` (or an `ownership_changes` table) so a book moving between reps
  mid-season is visible rather than mysterious.

### 3.5 RLS testing is not optional

PRD acceptance criterion #1 ("querying another account by ID returns nothing")
is a security test, and it's the single most important test in the project —
non-employee rep groups are seeing each other's dealer revenue if it fails.
Encode it as a real test that runs in CI, not a manual check:

- Seed two rep users and one admin in a test project.
- Assert rep A gets 0 rows for rep B's `customer_key`, for **every** exposed
  table and view — including the `erp` schema and the new `v_*` views. New
  views are the likeliest place for a leak, so make the test enumerate
  `information_schema` and fail on any exposed relation without a policy.

---

## 4. ETL & scheduled jobs

### 4.1 ETL

Python in Docker (per the README's planned `etl/` and `docker/`), SQL Server →
Supabase Postgres:

- `pyodbc` (or `pymssql`) to read `bi.vw_*`, `psycopg` v3 with `COPY` to write.
  `COPY` rather than row-by-row inserts — this is the difference between a
  2-minute and a 40-minute load on the fact tables.
- **Straight truncate-and-load, wrapped in one transaction per table** — as
  `002_erp_read_tables.sql` already specifies. No staging tables. `TRUNCATE` is
  transactional in Postgres (unlike MySQL/Oracle), so `BEGIN; TRUNCATE; COPY;
  COMMIT;` means no reader ever observes an empty table: MVCC holds them on the
  old snapshot until commit. The only cost is that `TRUNCATE` takes an
  `ACCESS EXCLUSIVE` lock, so a reader arriving mid-load *blocks* for the load
  duration rather than seeing stale rows.

  That's a non-issue for this deployment: the org is US-only, reps are done by
  ~15:00, and the load runs overnight. Staging tables would be complexity
  bought for a window nobody is awake for.

  **Revisit only if the hourly load in PRD §7 ("daily minimum; hourly capable")
  is ever switched on** — that puts the lock window inside business hours, and
  a rep opening an account mid-load would hang. At that point, move to
  staging + `alter table ... rename` (a brief lock at swap time instead of a
  load-length one). Not before.
- Write a `job_runs` row per table. Fail loudly — a silently stale `erp` schema
  produces confidently wrong recommendations, which is worse than an outage.
- Config via env vars, secrets from the runner (not baked into the image).

### 4.2 The nightly recommendation job — PRD open question, answered

**Recommendation: implement it as a Postgres function
(`public.generate_recommendations()`) and have the ETL scheduler call it as its
final step.**

Reasoning:

- It runs immediately after fresh data lands — no race between "data loaded"
  and "recommendations generated," which a separate cron schedule always has.
- Idempotency is natural in SQL: `insert … select … on conflict (customer_key,
  rule_key) where status = 'open' do nothing`. Doing this in TypeScript means
  round-tripping candidate rows out and back.
- One place to look when a rule misfires, and it's version-controlled next to
  the schema.
- The rules *are* SQL (PRD §7: "runs SQL rules against the read tables").
  Wrapping SQL in Deno to execute SQL adds a layer that only costs.

Fallback if the ETL scheduler can't call a post-step: `pg_cron` scheduled 30
minutes after the expected ETL completion, with a guard that checks `job_runs`
for a successful load that day and no-ops otherwise.

**Not recommended: a Supabase scheduled Edge Function.** It's the option that
most easily drifts out of sync with the data load.

Every generated row carries `rule_key` (PRD §7 P2 note) so outcome-by-rule
analysis stays a query. Thresholds live in the `rule_settings` table
(005) from day one — the PRD lists admin-configurable rules as P1, but making
the *values* table-driven now (even if the editing UI is P1) costs nothing and
avoids a migration later. This also unblocks the PRD's blocking open question
about launch thresholds: the schema doesn't need the answer, only the seed row
does.

---

## 5. AI layer

### 5.1 v1: direct Claude API call, cached

Flow for the account summary:

```
Rep clicks "Summarize"
  → Vue calls Edge Function `ai-account-summary` (user JWT forwarded)
  → Function verifies the caller has access to that account (calls
    has_account_access() as the user — NOT service_role)
  → Function runs 3–4 fixed SQL queries to build a compact JSON context
    (12-mo revenue trend, recent orders/shipments, open recs, last 5 notes,
     last visit survey)
  → One Claude call, structured prompt, low temperature
  → Insert into public.ai_summaries with generated_at + a hash of the context
  → Return to client; client shows the cached copy with "as of <timestamp>"
```

Details that matter:

- **Model:** Sonnet 5 for this. The task is summarization over a small,
  well-structured context — Opus is not worth the latency or cost per account,
  and reps will hit this button a lot. Revisit for M3's next-best-action, which
  is genuine reasoning.
- **Cache key on a context hash**, not just a timestamp. If nothing about the
  account changed, the regenerate button should return the cached summary
  instantly and for free.
- **Prompt caching** on the system prompt / instruction block — it's identical
  across every account, so it's ~free after the first call each session.
- **Graceful degradation is a requirement** (PRD acceptance criterion #7).
  Handle it *before* the API call: if the account has < N invoice lines and no
  notes, return "Not enough activity to summarize" without spending a token.
- **Cost ceiling:** put a per-user daily call limit in the Edge Function. An
  internal tool with an unmetered LLM button is a bill waiting to happen.
- **Never send PII you don't need.** Contact names/emails add little to a
  trend summary; exclude them from the context payload.

### 5.2 Prompt lives in the repo, not in a string literal

Keep the summary prompt as a versioned file with a version tag stored on each
`ai_summaries` row. When you tune the prompt you'll want to know which
summaries came from which version — the PRD's whole thesis is tuning based on
outcomes, and that applies to the AI output too.

---

## 6. MCP — where it belongs

MCP is genuinely useful here, but it is being over-applied industry-wide to
problems that are just "call an API." Three distinct places, in order of value:

### 6.1 Dev-time MCP — use it now, it's already working

You already run an MCP server against the BI/SQL Server layer (`server-toolbox`:
schema browsing, saved queries, entity graph). That is the highest-value MCP in
this project *today*, because it's how the `bi.vw_*` semantic layer and these
migrations got written. Extend it rather than replace it:

- Add the **Supabase MCP** to the dev loop for migrations, advisors, and
  type generation against the portal project.
- The payoff: writing `generate_recommendations()` becomes "show me the
  invoice-line grain and the customer dim, then draft the rule" in one context.

**No production dependency. No user ever touches it.**

### 6.2 v1 product AI — deliberately *not* MCP

For the account summary, MCP would mean: give Claude tools and let it decide
what to query. That's the wrong trade for this use case.

| | Direct SQL → prompt | MCP tool-loop |
|---|---|---|
| Latency | One API call | 3–6 round trips |
| Cost | Predictable | Variable, unbounded |
| Cacheable | Yes (context hash) | Not really |
| Access control | Enforced in SQL before the call | Must be enforced per-tool, per-call |
| Output shape | Consistent across accounts | Varies with which tools it chose |

For a fixed-shape summary of known fields, the deterministic path wins on every
axis. **Use MCP when the question is open-ended, not when the answer template
is fixed.**

### 6.3 M3 product MCP — build toward it

The PRD's M3 ("AI next-best-action," distributor intelligence, conversational
access to outcome history) *is* the open-ended case, and there MCP is the right
tool. Two concrete forms:

1. **A portal MCP server for sales ops (internal, high value, low effort).**
   Exposes read tools over the portal's own data: `coverage_status(rep, window)`,
   `recommendation_outcomes(rule_key)`, `untouched_accounts()`,
   `visit_survey_trends(account)`. Then you can ask, in Claude Desktop or Claude
   Code, "which rules produced the most 'false positive' outcomes last month,
   and what do those accounts have in common?" — which is exactly the PRD's
   rule-tuning loop, without building an analytics UI for an audience of one.
   This is worth building as soon as there's outcome data to query, likely well
   before M3 formally starts.

2. **In-app conversational assistant for reps (later, higher risk).** "What
   should I do about Anderson Hardware?" backed by MCP tools. Gate this on the
   summary feature proving out. The hard part isn't MCP, it's that every tool
   must enforce the rep's own RLS scope — a tool that queries with
   `service_role` and filters afterward is a data leak with extra steps.

**Design-for-it now, at zero cost:** keep the read logic for account context in
SQL views/functions rather than inline in the Edge Function. Then the MCP
server in M3 exposes the *same* functions the summary already uses, instead of
reimplementing them.

---

## 7. Repo layout & tooling

```
christensencrm/
├── docs/                    PRD, this doc, bi_schema/ (SQL Server view DDL)
├── supabase/
│   ├── migrations/          001_… (numbered, forward-only)
│   ├── functions/           ai-account-summary/, admin-create-user/
│   ├── seed.sql             test users, sample assignments, rule thresholds
│   └── tests/               RLS assertions (pgTAP or plain SQL)
├── frontend/                Vue 3 SPA → Vercel
├── etl/                     Python jobs, SQL Server → Supabase
├── docker/                  ETL image, local compose
└── packages/shared/         zod schemas + generated Supabase types (shared FE/functions)
```

Note: `supabase-sql/` has been renamed to `supabase/` so the Supabase CLI can
manage it directly (`supabase db push`, `supabase db diff`, branching).

- **pnpm workspaces** for the JS side. `packages/shared` is what stops the
  visit-survey field names from drifting between the form, the Edge Function,
  and the table.
- **Generated types:** `supabase gen types typescript` into
  `packages/shared/database.types.ts`, regenerated in CI on migration change.
  This is what makes the "no application server" approach safe — the client
  is type-checked against the actual schema.
- **ESLint + Prettier**, **Ruff** for Python. Not interesting, just decide once.

---

## 8. Environments, secrets, deploy

**Two Supabase projects: `dev` and `prod`.** Not one. The ETL truncates and
reloads tables; you do not want to discover a column-mapping bug against
production during order season. Supabase branching can cover the dev project if
you prefer.

| Secret | Lives in |
|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | Vercel env (public by design — RLS is the boundary) |
| `SUPABASE_SERVICE_ROLE_KEY` | Edge Function secrets + ETL runner **only**. Never in Vercel, never in the frontend bundle. |
| `ANTHROPIC_API_KEY` | Edge Function secrets only |
| SQL Server creds | ETL runner only |

Deploy triggers:

- Frontend: Vercel on push to `main`, preview deploys on PRs pointed at `dev`.
- Migrations: GitHub Action runs `supabase db push` on merge to `main` after
  tests pass. Forward-only migrations; no editing an applied file.
- ETL: image built on push, run by the existing scheduler.

---

## 9. Testing & observability

Scoped to what actually protects the PRD's acceptance criteria — this is not a
project that needs 90% coverage.

| What | How | Why it's on the list |
|---|---|---|
| RLS isolation | SQL/pgTAP test in CI, enumerating every exposed relation | Acceptance criterion #1; a leak exposes dealer revenue to third-party rep groups |
| RLS fail-open cases (§3.4) | Named cases: null `sales_rep_key`; `sales_rep_key = 'HOUSE'`; null `rep_group_vendor_id`. Each must return **zero** rows | These are the two ways derived ownership fails, and both fail silently and totally |
| Revoke beats derive | Assert an account with a `revoke` override is invisible to its ERP-derived owner | Override precedence is easy to get backwards and impossible to notice |
| Recommendation idempotency | SQL test: run the job twice, assert no duplicates | Acceptance criterion #2 |
| Outcome-required-to-close | DB constraint + one test | Acceptance criterion #3 — enforce in the schema, not the form |
| Visit survey submit (mobile viewport, with photo) | Playwright, throttled network | Acceptance criterion #5 |
| Component logic | Vitest + Vue Test Utils, only where logic is non-trivial | Don't test that Vue renders |
| ETL row counts | Assertion in the job: loaded rows within tolerance of source | Silent partial loads are the dangerous failure |

Observability:

- **Sentry** on the frontend. Reps will not file bug reports; they'll stop
  using the app. You need to see errors you were never told about.
- **`job_runs`** as the ETL/recommendation audit trail, surfaced on the admin
  dashboard — if last night's job failed, the admin should see it before the
  reps do.
- **Supabase logs + advisors** checked on a schedule (the advisors catch
  missing RLS policies and unindexed foreign keys, which is exactly the class
  of mistake this schema is exposed to).

---

## 10. Decisions I'd lock now

1. Vite SPA, not Nuxt. (§2.1)
2. No application server; PostgREST + RLS, with exactly two Edge Functions —
   photos upload direct to Storage under path-based RLS, no signed-URL
   function. (§3)
3. Nightly recommendation job as a Postgres function called by the ETL
   scheduler. (§4.2) — *answers a PRD open question*
4. Photo compression client-side to ~300 KB. (§2.5) — *answers the PRD Storage
   cost question*
5. AI summary via direct Claude API (Sonnet 5) with context-hash caching, not
   MCP. (§5, §6.2)
6. `rule_settings` table from day one, even though the editing UI is P1. (§4.2)
7. `supabase-sql/` renamed to `supabase/` for CLI compatibility — done. (§7)
8. Two Supabase projects, dev and prod. (§8)
9. Tailwind + shadcn-vue, with TanStack Table for admin grids. (§2.4)

10. Account ownership derived from the ERP hierarchy — `assigned_sales_rep_id`
    for the individual, `dim_sales_rep.vendor_id` for the rep group — with
    `account_assignments` as a grant/revoke override layer. Implemented in
    migrations 003/006; principal-facing UI stays P1. (§3.4) — *answers the
    PRD's blocking open question*
11. Offline survey draft + submit queue ships in **v1**, minimum scope. (§2.5)

### Still open / needs your input

- **Launch rule thresholds** (PRD §11, blocking for go-live, not for schema) —
  N days-since-order and X% YoY decline. The `rule_settings` table means this
  is a seed value, not a migration (currently seeded at 120 days / 30%), so it
  can be answered as late as the week before launch — but it does have to be
  answered.
- **Dealer-data sensitivity confirmation** (PRD §11) — exposing account revenue
  to non-employee rep groups. Assumed fine since Tableau already does it, but
  §3.4's derived ownership means a mis-set `sales_rep_key` shows a rep someone
  else's book. Worth the explicit sign-off before launch.

---

## 11. Build order for M1

Sequenced so the riskiest and most-blocking things land first.

1. **Foundation** — dev + prod projects, migrations applied (001–010),
   generated types, CI with the RLS test harness in place *before* there are
   tables to leak.
2. **ETL** — `erp` tables loading on schedule, one transaction per table, with
   `job_runs` logging. Everything downstream is blocked on real data.
3. **Auth + access** — admin user creation Edge Function, `has_account_access()`
   extended with both derived branches (§3.4), and RLS proven by the test suite
   including the null-key and placeholder-rep fail-open cases. The only
   per-user admin work is stamping `sales_rep_key` (plus
   `rep_group_vendor_id` for principals) on each profile; there is no bulk
   assignment exercise, because ownership comes from the ERP. The override UI
   and the principal-facing screens are both thin and can trail the rest — but
   the access branches land here, not later.
4. **Account page read path** — the `v_*` aggregate views, then the account
   screen with charts. Highest-value screen; validates the whole data model.
5. **Recommendations engine** — rules table, `generate_recommendations()`,
   idempotency test, needs-attention list on the rep dashboard.
6. **Action logging + visit survey** — including the offline draft queue and
   photo compression. Test on an actual phone on cellular, not on desktop
   Chrome's device emulator.
7. **AI summary** — Edge Function, caching, degradation path.
8. **Admin execution + coverage dashboard** — TanStack Table grids, the
   untouched-accounts list, `job_runs` status.

Items 4–8 are independently shippable; if the season squeezes the timeline, the
first thing to cut is #7 (AI summary), not #8 (coverage) — coverage is the P0
business goal, the AI summary is a delighter.
