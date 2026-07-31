# ChristensenCRM — Sales Execution Portal

Lightweight rep portal built around one loop:
**Analytics → Recommendation → Rep Action → Outcome → AI Summary → better rules.**

- [docs/PRD.md](docs/PRD.md) — full project definition: problem, scope, requirements
- [docs/TECH_STACK.md](docs/TECH_STACK.md) — stack choices, architecture decisions, build order

## Repo layout

| Folder | Purpose |
|---|---|
| `docs/` | PRD, tech-stack decisions, and the SQL Server `bi` schema (source-of-truth view definitions) |
| `supabase/` | Supabase Postgres migrations: `erp` read-model landing tables, app-owned writable tables, RLS, recommendation engine |
| `etl/` | Jobs that push the SQL Server `bi.vw_*` views into Supabase (`erp` schema) |
| `frontend/` | Vue 3 SPA (Vercel) — not scaffolded yet |
| `docker/` | Container definitions (ETL job image, local tooling) |

## Data flow

```
SQL Server (VECA/VFIN)
  → bi.vw_* views            (docs/bi_schema — governed semantic layer)
  → ETL push (etl/)          (truncate-and-load, daily min / hourly capable)
  → Supabase Postgres
       erp.*   read-only landed data  (ETL-owned, app never writes)
       public.* app tables            (assignments, recommendations, visits, notes…)
  → Vue 3 SPA on Vercel  +  Claude API for account summaries
```

Hard rule: **nothing ever writes back to the ERP.** The `erp` schema in Supabase
is written only by the ETL service role; the app has SELECT only.
