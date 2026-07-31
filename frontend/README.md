# frontend — Sales Execution Portal SPA

Vue 3 + Vite + TypeScript. Talks straight to Supabase PostgREST with the signed-in
user's JWT; there is no application server (TECH_STACK §3.1).

```bash
npm install
cp .env.example .env.local   # fill in the project URL + publishable key
npm run dev
npm run build                # vue-tsc -b && vite build
```

## Layout

| Path | Purpose |
|---|---|
| `src/lib/supabase.ts` | The single client. `supabase` for `public`, `erp` for the read models. |
| `src/lib/queryClient.ts` | TanStack Query defaults + the `qk` query-key registry |
| `src/stores/session.ts` | Pinia: session, profile, role. **Nothing server-derived lives here.** |
| `src/composables/` | One file per read path; every DB read goes through TanStack Query |
| `src/types/database.types.ts` | Generated — regenerate after every migration |
| `src/types/domain.ts` | The CHECK-constraint vocabulary the generated types widen to `string` |
| `src/components/ui/` | Generic primitives. Business logic goes in `src/components/`. |

## Rules worth not re-litigating

- **Pinia holds session state only.** Server data goes through TanStack Query
  (TECH_STACK §2.3). This is what keeps the app off manual
  `loading`/`error`/`data` triples.
- **RLS is the security boundary.** Queries are written unscoped on purpose —
  `select * from erp.dim_customer` returns exactly the rep's book because
  `has_account_access()` says so. Never add a client-side owner filter and
  treat it as security.
- **Never aggregate ERP facts in the browser** (TECH_STACK §3.3). Revenue
  rollups belong in `public.v_*` views.
- **Field UI floor:** 44px touch targets (`.tap-target`), no hover-only
  affordances, no horizontal page scroll, state changes confirmed inline rather
  than in a modal.

## Not built yet

- Account mini-dashboard + charts — blocked on the `public.v_*` rollup views
- Visit survey, photo upload, offline draft queue (TECH_STACK §2.5)
- AI account summary (needs the `ai-account-summary` Edge Function)
- Admin user creation (needs the `admin-create-user` Edge Function)
- CSV export on the coverage list
