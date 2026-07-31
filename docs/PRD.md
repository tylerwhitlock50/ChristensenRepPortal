# Sales Execution Portal — Project Definition & Requirements

**Working name:** Rep Portal / Sales Execution Portal (deliberately not "CRM")
**Owner:** Tyler Whitlock (Sales Operations)
**Date:** 2026-07-31
**Status:** Draft for review

---

## 1. Problem Statement

Sales reps, rep groups, and outside sales agents have no practical way to receive direction from sales operations or to send field intelligence back. The current delivery mechanism — Tableau dashboards and emailed Excel reports — exceeds the data literacy of most of the field organization, provides no way to capture what reps actually did, and gives sales ops zero visibility into whether information was even seen. The result: sales ops knows *what happened* on every account but has no idea *why*, whether accounts are being worked, or whether recommendations are being acted on. During order season this is acute — there is currently no way to verify that every assigned account has been contacted.

**The core insight: the problem is not the data, it's the delivery and the missing feedback loop.** This is a sales *execution* problem, not a reporting problem.

## 2. Product Vision

An opinionated, lightweight execution tool built around one loop:

```
Analytics → Recommendation → Rep Action → Feedback → AI Summary → Better Recommendation
```

The data warehouse tells us what happened. The portal captures why it happened. A rep logs in each morning and immediately knows: what changed on my accounts overnight (ERP activity), what needs my attention (recommendations/assignments), and where to log what I did (actions, visits, surveys). Sales ops gets execution metrics and structured field intelligence in return.

## 3. Goals

1. **Contact coverage during order season (P0 business goal):** Sales ops can answer "has every assigned account been contacted?" at any time, per rep, with dates and outcomes. Target: 100% of assigned accounts have a logged contact or an explicit dispensation within the season window.
2. **Close the feedback loop:** ≥80% of system-generated recommendations receive a logged action + outcome within 14 days of creation.
3. **Replace Tableau as the field-facing surface:** Reps get account-level revenue, orders, open orders, and shipments in the portal without touching Tableau. Target: ≥90% of active reps logging in at least weekly within 60 days of launch.
4. **Capture structured field intelligence:** Visits, surveys, photos, and contacts flow back as structured data (GoSpotCheck-style), not free text — enabling future analytics and AI on top. Target: a completed structured visit survey for every in-person visit logged.
5. **Execution visibility for management:** Per-rep metrics (last login, task completion, overdue recommendations, days since activity) available on an admin dashboard.

## 4. Non-Goals (explicitly out of scope)

These are "CRM things" this product will **not** do, in any phase:

- **Opportunity pipeline / deal stages** — we don't run pipeline; recommendations + tasks are the workflow unit
- **Quoting** — stays in the ERP
- **Forecasting** — not this tool's job
- **Calendar / email integration** — actions are logged in-app, not synced
- **Customer support / ticketing** — out of scope
- **Marketing automation** — out of scope
- **Commission tracking** — out of scope
- **Lead management / prospecting** — this tool works existing accounts
- **Self-service signup** — users are created and credentialed by the admin only
- **Writing back to the ERP** — the ERP data path is strictly one-way, read-only (this killed the Salesforce deployment; we're not repeating it)

## 5. Users & Personas

| Persona | Description | Primary needs |
|---|---|---|
| **Field rep / outside sales agent** | Varying (generally low) data literacy; works for independent rep groups; not employees | One screen that says what to do today; simple account view; fast mobile-friendly logging of visits/calls |
| **Rep group principal** | Oversees several reps in a group | See their group's accounts and activity |
| **Sales ops admin (Tyler)** | Builds the data pipeline, assigns accounts, creates users, defines recommendation rules | User management, assignment, execution dashboard, recommendation rule tuning, outcome analytics |
| **Inside sales / management (secondary)** | Consumes execution metrics | Read access to activity and coverage reporting |

## 6. User Stories

### Rep — daily loop
- As a rep, I want to log in and immediately see overnight ERP activity on my accounts (new orders, shipments, invoices) so that I start the day knowing what changed.
- As a rep, I want a prioritized "needs attention" list (recommendations + assignments) so that I know exactly what to do today without interpreting a dashboard.
- As a rep, I want to open an account and see a simple summary — trailing-12-month revenue, recent orders, open orders, recent shipments, a couple of charts — so that I'm prepared before I call or visit.
- As a rep, I want an AI-generated plain-English account summary so that I don't have to interpret charts.
- As a rep, I want to log an action against a recommendation (called / visited / emailed) with an outcome so that the assignment is closed out.
- As a rep, I want to complete a short structured visit survey (inventory level, store condition, competition seen, display quality, photos, comments) in under a minute so that reporting a visit isn't a burden.
- As a rep, I want to add/update account contacts (buyer name, phone, email, notes) so that contact info stays current.
- As a rep, I want to add free-text notes and photos to an account so that context is captured where the next person can find it.

### Sales ops admin
- As the admin, I want to create users and set their passwords myself, with no self-signup, so that access is fully controlled.
- As the admin, I want to assign accounts to reps/rep groups so that every account has an owner and every rep sees only their book.
- As the admin, I want to create manual assignments ("contact this account") with a due date so that order-season coverage is directive, not optional.
- As the admin, I want a nightly job to generate recommendations from SQL rules (no order in N days, revenue down X%, etc.) so that prioritization is automatic and consistent.
- As the admin, I want every recommendation to require an outcome (order received / inventory issue / competitor / seasonal / false positive / could not contact) so that the rule set can be tuned on real results.
- As the admin, I want an execution dashboard (last login, tasks completed, overdue, days since activity, coverage % per rep) so that I can manage by follow-through, not just sales results.
- As the admin, I want to see which accounts have *not* been touched so that nothing falls through during order season.

### Edge cases
- As a rep, I want to mark a recommendation "bad recommendation / false positive" so that noise gets reported instead of ignored.
- As a rep with no open items, I want the dashboard to say so clearly (empty state) rather than look broken.
- As the admin, I want to deactivate a user and reassign their accounts so that rep-group turnover is handled cleanly.

## 7. Requirements

### P0 — Must have (v1, order-season ready)

**Auth & access**
- Admin-created users only (Supabase Auth, email + admin-set password); no signup flow, no password self-registration
- Roles: `admin`, `rep` (rep-group principal can be a rep with multiple assignments in v1)
- Row-level security: reps see only accounts assigned to them; admin sees everything
- Login events recorded (who, when) for execution metrics

**Data foundation**
- Read-only sales data (accounts, orders, invoices, shipments, sales history) landed in Supabase Postgres from existing SQL Server views via the existing ETL/scheduler (daily minimum; hourly capable)
- Read tables are never written by the app; writable tables are app-only. Clean separation.

**Rep dashboard (home screen)**
- Activity feed: overnight/recent ERP events on my accounts (new sales orders, shipments, invoices)
- "Needs attention" screening section: open recommendations, assignments, follow-ups, overdue items with counts
- Zero analytics beyond that — the home screen is a to-do list, not a dashboard

**Account page (the 80% screen)**
- Header: account name, assigned rep, key contact
- Mini-dashboard: current vs prior year revenue, order history (last 12 months), open orders, recent shipments — with 2–3 simple charts
- AI account summary (see below)
- Open recommendations/assignments for this account
- Notes (chronological), contacts, photos, visit/action history

**Recommendations & assignments engine**
- Nightly scheduled job (script/cron, e.g. Supabase scheduled function or the existing scheduler) runs SQL rules against the read tables and creates recommendation records; idempotent (no duplicates for the same open condition)
- Initial rule set: no order in >N days (configurable), revenue down >X% YoY, open/aging condition per admin definition
- Admin can also create manual assignments with due dates
- Recommendation lifecycle: `open → acted → closed` (or `dismissed`)
- **Outcome required to close**: order received / inventory issue / competitor activity / customer shrinking / seasonal / false positive / could not contact — plus optional note
- Reps cannot create arbitrary recommendations; they act on system/admin-created ones (they can create simple personal follow-up tasks)

**Action logging**
- Log an action from a recommendation or an account: type (call / visit / email), date, note, optional photos
- Actions link back to the recommendation they resolve

**Structured visit survey (GoSpotCheck-style)**
- Triggered from "log visit": visit type (in person/phone/email), inventory level (empty/low/good/overstock), store condition (1–5), display quality (1–5), competition seen (checkboxes), staff knowledge (1–5), free comments, photo upload
- All answers stored as structured fields, not free text

**AI account summary**
- On-demand (button) per account; generated from the read data + recent notes/visits/outcomes via Claude API
- Cached with a generated-at timestamp; regenerate on demand
- Plain-English: what the account is, trend, what changed, recommended next steps

**Admin execution dashboard**
- Per rep: last login, open/completed/overdue recommendations, task completion %, days since last activity
- Coverage view: % of assigned accounts contacted in the current period; list of untouched accounts
- Per-account drill-in: full activity history

**Platform**
- Vue 3 SPA, deployed on Vercel; Supabase (Postgres, Auth, Storage for photos, RLS)
- Mobile-friendly (reps are in the field; phone-first for visit logging)

**Acceptance criteria (representative)**
- [ ] A rep logging in sees only their assigned accounts; querying another account by ID returns nothing (RLS enforced)
- [ ] Given the nightly job runs and an account has no order in >N days, a recommendation exists the next morning; re-running the job does not create a duplicate
- [ ] A recommendation cannot move to closed without an outcome selected
- [ ] Admin coverage view shows, for a chosen date range, every assigned account with contacted-yes/no and the untouched list exports/filters cleanly
- [ ] A visit survey can be completed and submitted from a phone, with photo, in under 60 seconds
- [ ] ERP-sourced tables are not writable by any app role (verified via RLS/grants)
- [ ] AI summary renders for an account with data and degrades gracefully ("not enough data") for one without

### P1 — Should have (fast follow)

- Photo gallery per account with categories (storefront, counter, display, competition)
- Rep-facing "my performance" widget (own completion rate, streaks) to encourage follow-through
- Contact enrichment fields (birthday, interests, preferences — relationship notes)
- Admin-configurable recommendation rules via a settings table (thresholds editable without code changes)
- Push/email nudge for overdue recommendations
- CSV export of activity and coverage for management reporting
- Rep-group principal role that aggregates their reps' books

### P2 — Future (design for, don't build)

- **Distributor & key-account intelligence:** land Scope and SPS Analytics data (distributor inventory, sell-through, backorders) as additional read models; distributor account pages and derived recommendations ("distributor inventory depleted on model X")
- **Recommendation-rule learning:** analytics over outcomes — which rules generate orders, which are noise; tune/retire rules based on false-positive rates
- **AI next-best-action:** move from summarization to AI-proposed recommendations using visit/outcome history
- **Survey trend analytics:** inventory-level and competition trends across accounts over time
- Schema note for now: keep recommendations rule-tagged (`rule_key` on every generated record) and outcomes normalized so outcome-by-rule analysis is a query, not a migration.

## 8. Data Model (summary)

**Read-only (ETL-owned, from SQL Server views):** accounts, sales/invoice history, orders, open orders, shipments, (later: distributor inventory, SPS/Scope data)

**Writable (app-owned):** users/profiles, account_assignments, contacts, notes, photos, recommendations (with `rule_key`, status, outcome), assignments/tasks, actions, visits + visit_survey_responses, ai_summaries (cached), login/activity events

## 9. Architecture

```
SQL Server (ERP)
  → canonical SQL views (existing)
  → existing ETL tool + scheduler (daily, hourly-capable)
  → Supabase Postgres (read models, replace-on-load)
       + writable models (app data, RLS)
  → Vue 3 SPA on Vercel
  → Claude API for account summaries
Nightly recommendation job → reads read-models → writes recommendation records
```

ERP remains authoritative; the portal never writes back. The nightly recommendation job runs as a scheduled function/script — **not** generated on page load — so every rep wakes up to the same pre-computed priority list and the job can be idempotent and auditable.

## 10. Success Metrics

**Leading (first 30–60 days)**
- Weekly active reps ≥90% of provisioned users
- Median time from recommendation creation → first action < 5 days
- Visit survey completion rate ≥90% of logged in-person visits
- Order-season coverage: 100% of assigned accounts contacted or explicitly dispositioned

**Lagging (1–2 quarters)**
- % of recommendations with outcome "order received" (rule effectiveness baseline established)
- False-positive rate per rule trending down as rules are tuned
- Reduction in "no order >N days" account count vs. prior season
- Sales ops time spent chasing reps for status (subjective, but should approach zero)

## 11. Open Questions

- **[Tyler/eng]** Recommendation job placement: Supabase scheduled edge function vs. a step appended to the existing ETL scheduler? (Non-blocking — either works; ETL-appended is simplest since it runs right after fresh data lands.)
- **[Tyler]** Initial rule thresholds: what N days-since-order and X% YoY decline define the launch rule set? (Blocking for the nightly job; needs values before go-live.)
- **[Tyler]** Assignment granularity: are accounts assigned to individual reps, rep groups, or both? Affects RLS design. (Blocking for schema.)
- **[Tyler]** Photo retention/size limits on Supabase Storage — any cost ceiling? (Non-blocking.)
- **[Tyler/legal]** Any dealer-data sensitivity in exposing account revenue to non-employee rep groups? Assumed fine since Tableau already does; confirm. (Non-blocking but confirm before launch.)
- **[Eng]** AI summary: generate on demand only, or pre-generate nightly for accounts with open recommendations? (Non-blocking; start on-demand + cache.)

## 12. Milestones & Timeline

Context: **currently mid order season** — v1 scope is intentionally bigger than a bare MVP because contact-coverage tracking and account mini-dashboards are needed *now*.

**M1 — Execution Portal (v1, order-season target):** auth + admin user management, account assignment, read-data ETL to Supabase, rep dashboard (activity feed + needs-attention), account page with mini-dashboard and charts, recommendations engine + outcomes, action logging, visit survey with photos, AI account summaries, admin execution/coverage dashboard. *Everything in P0.*

**M2 — Field Intelligence hardening:** photo galleries, contact enrichment, configurable rules, nudges, rep-group roles, exports. *P1 list.*

**M3 — Intelligence Engine:** Scope/SPS distributor read models and dashboards, outcome analytics on rules, survey trend analytics, AI next-best-action. *P2 list.*

---

*Parking lot (good ideas, explicitly not now): pipeline, quotes, forecasting, calendar/email sync, support, marketing, commissions, leads.*
