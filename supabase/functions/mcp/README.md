# mcp — the sales team's MCP endpoint

An [MCP](https://modelcontextprotocol.io) server over the rep portal, so a rep
can point Claude at their own sales data and ask questions in English.

```
https://<project-ref>.supabase.co/functions/v1/mcp
```

Read-only. Nineteen tools. No new access model: a token identifies a user, and
that user's existing RLS decides everything they can see.

---

## The one-paragraph version of the security design

The function resolves the incoming token to a `user_id` with **one**
`service_role` call (`mcp_token_resolve`, which returns no account data), then
mints a **five-minute `authenticated` JWT** for that user and does every read
through an ordinary supabase-js client carrying it. From that point it is
indistinguishable from the SPA — same anon key, same PostgREST, same policies,
same `my_customer_keys()`.

That is the whole point. The obvious alternative — read with `service_role` and
filter by the rep's book in TypeScript — would put a **second implementation of
the access rules** in a language with no RLS, which is exactly what the
`010_access_performance.sql` header and `_shared/supabase.ts` argue against. Not
one tool in `tools.ts` carries a customer-scoping predicate; `search_accounts`
selects from `v_account_list` unfiltered and gets precisely the caller's book,
because the view is `security_invoker`.

If you change one thing in this directory, do not make it that.

---

## Deploy

```bash
supabase functions deploy mcp --no-verify-jwt
supabase secrets set MCP_JWT_SECRET=<Settings → API → JWT Secret>
```

`--no-verify-jwt` for the same reason as every other function here: the
gateway's check would reject an MCP token, which is not a Supabase JWT. The
function authenticates every request itself before reading anything, and an
unauthenticated request gets a `401` from our own code.

### MCP_JWT_SECRET

The project's HS256 JWT secret — the same key PostgREST already validates every
browser token against. It is **not** auto-injected like
`SUPABASE_SERVICE_ROLE_KEY`; set it explicitly. Without it the function returns
`500 missing_env` rather than failing halfway through a request.

**If this project has migrated to asymmetric JWT signing keys and revoked the
legacy secret**, HS256 tokens stop validating and this function stops working
in one specific way: auth succeeds, every read comes back `401` from PostgREST.
The fix is to sign with the current key instead — swap `mintUserJwt()` in
`_shared/mcpAuth.ts` for ES256/RS256 against the active private key. Nothing
else in the design changes; the signing algorithm is the only assumption.

### Optional

| Variable | Default | What it does |
|---|---|---|
| `MCP_DISABLED_TOOLS` | *(empty)* | Comma-separated tool names to turn off without a deploy. |
| `MCP_ALLOWED_ORIGIN` | `*` | CORS origin. Pin it if browser-based MCP clients are ever the only consumers. |

`MCP_DISABLED_TOOLS` exists mainly for `list_contacts`. `ai-account-summary`
deliberately keeps contact PII out of a model's context (see the PII note in
`../README.md`); a rep asking "who do I call at this dealer" is a different
question from bulk-feeding a prompt, so the tool ships enabled — but that
judgement should be reversible from the dashboard, not from a pull request.

---

## How a rep connects

They do it themselves, from **account menu → Connect Claude** (`/connect`) in
the portal. The page mints a token, shows the plaintext **once**, and hands
over both connection forms. There is no admin step.

**claude.ai (web or desktop)** — Settings → Connectors → Add custom connector,
paste the URL form:

```
https://<project-ref>.supabase.co/functions/v1/mcp?token=crp_…
```

**Claude Code / anything with a headers block** — preferred, because the secret
never enters a URL:

```bash
claude mcp add --transport http rep-portal \
  https://<project-ref>.supabase.co/functions/v1/mcp \
  --header "Authorization: Bearer crp_…"
```

The token is also accepted as `x-mcp-token`, and as a trailing path segment
(`/functions/v1/mcp/crp_…`) for clients that mangle query strings.

### On putting a secret in a URL

It is a real trade, taken deliberately: claude.ai custom connectors accept a URL
and nothing else, and a sales team that cannot connect is a feature that does
not exist. What makes it acceptable is that the credential is per-user,
expiring, revocable on its own from `/connect`, read-only, and scoped to data
its holder can already see. Reps whose client can send a header should send a
header, and the Connect page says so.

---

## Tools

All read-only, all scoped automatically. `whoami` first — it reports
`data_through`, the newest invoice date in the warehouse, which is what "today"
means for every other answer.

| Tool | Reads | Answers |
|---|---|---|
| `whoami` | `v_account_list`, `v_data_freshness` | Who am I, how big is my book, how fresh is this |
| `search_accounts` | `v_account_list` | Name → `customer_key` |
| `get_account` | `v_account_summary`, `account_signals`, `v_account_goal_progress`, `recommendations` | Everything about one account, in one call |
| `get_account_sku_sales` | `v_sku_sales_by_account` | What they buy, pivoted by year — dropped SKUs, mix shift |
| `get_account_revenue_trend` | `v_account_revenue_monthly` | The month-by-month line — seasonality, momentum, when a slowdown started |
| `get_account_sku_gaps` | `report_account_sku_gaps()` | In-stock SKUs this dealer doesn't carry, ranked by dealer breadth |
| `get_territory_summary` | `v_territory_account_yoy`, `v_my_goal_rollup` | How am I doing; growers, decliners, gone quiet |
| `list_territory_accounts` | `v_territory_account_yoy` | Rank the book by any revenue/backlog measure |
| `get_sku_sales` | `v_territory_sku_sales` | What sells across the whole territory |
| `list_backlog` | `v_backlog_by_sku` | What customers are owed, and when it ships |
| `check_availability` | `v_ats_list` | Company-wide stock / available-to-sell |
| `list_orders` | `v_account_recent_order_headers`, `v_account_order_lines` | Order history and one order's lines |
| `list_shipments` | `v_account_recent_shipment_headers`, `v_account_shipment_lines` | Did it ship, where is it, tracking number |
| `lookup_order` | `lookup_orders()` | Which order is PO 44182 / tracking 1Z…, across the whole book |
| `get_goal_progress` | `v_account_goal_progress`, `v_my_goal_rollup` | Goal attainment and seasonal pace |
| `list_recommendations` | `recommendations` | The generated work list, with why-now |
| `list_account_activity` | `notes`, `actions`, `visits` | What the team has actually done there |
| `list_contacts` | `v_account_contacts` | Who to call (ERP + rep-entered) |
| `get_global_product_sales` | `report_global_product_sales()` | Company-wide units, for benchmarking |

Two deliberate omissions:

- **No write tools.** Logging a call or closing a recommendation are portal
  actions with outcome constraints and triggers behind them (`005`, `016`,
  `020`). Exposing them through a chat client is a separate decision with its
  own audit story, not a bonus feature of a read endpoint.
- **No company-level revenue.** `get_global_product_sales` returns units and
  counts only, because `033_global_intel_units_only.sql` says reps see
  company-wide units and never company-wide dollars. The function it calls
  structurally cannot return either dollars or customer keys.

### Context sizing

`tools/list` is ~4k tokens. Every list tool caps `limit`. Ranking and totals
happen in Postgres; the only client-side aggregation left is the SKU pivots,
which page under a unique ORDER BY and a hard row cap and report `has_more`
(more SKUs than `limit`) separately from `capped_at` (the source-row ceiling
was hit — totals may undercount). Nothing silently returns a prefix. Nulls are
stripped from every row and money is rounded to cents.

---

## Transport

Streamable HTTP, **stateless, JSON only**. One POST carries one JSON-RPC
message and gets one JSON response. No sessions, no SSE, no server-initiated
messages — all optional in the spec, and none of them useful to a
query-the-warehouse server. Statelessness is what lets this be an Edge Function
at all: any instance can answer any request, because the only state is the
bearer token the client sends every time.

- `GET` → `405` (we never open a stream)
- `DELETE` → `204` (nothing to tear down, but erroring on a client's tidy-up is rude)
- Notifications → `202`, no body
- Protocol versions: `2025-06-18`, `2025-03-26`, `2024-11-05`; we answer in the
  client's if we know it
- Batch arrays are still handled, though the protocol dropped them in
  `2025-06-18`

A tool that fails returns a **successful** JSON-RPC response with
`isError: true` and a message telling the model what to do differently.
JSON-RPC `error` objects are reserved for protocol problems — an unknown method
or an unknown tool name.

---

## Files

```
mcp/
├── index.ts        transport, JSON-RPC dispatch, auth handover
├── tools.ts        the nineteen tools + the registry
└── README.md       this file
../_shared/mcpAuth.ts   token extraction, resolution, JWT minting
```

Database side: `supabase/migrations/20260816120000_mcp_access.sql`
(`mcp_tokens`, `mcp_token_create/revoke/resolve`), tested by
`supabase/tests/034_mcp_access.sql`.

---

## Testing it by hand

```bash
TOKEN=crp_…    # from /connect
URL=https://<project-ref>.supabase.co/functions/v1/mcp

# handshake
curl -s -X POST "$URL" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'

# what can it do
curl -s -X POST "$URL" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

# who am I, and how fresh is the data
curl -s -X POST "$URL" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"whoami","arguments":{}}}'
```

Locally: `supabase functions serve --env-file ./supabase/.env.local` with
`MCP_JWT_SECRET` set, against `http://localhost:54321/functions/v1/mcp`.

### The check worth running after any change here

Two reps, two tokens, one `customer_key` belonging to the first. The second
rep's token must return "not visible to you" from `get_account` — not an empty
result, not a row. If it ever returns a row, something in this directory has
started reading with `service_role`.
