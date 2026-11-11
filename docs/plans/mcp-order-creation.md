# Plan: creating orders through the MCP server

This is research only. No files were edited and no SQL was run. Paths without a prefix are relative to the CRM worktree `C:/Users/TylerW/ChristensenCRM/.claude/worktrees/mcp-order-creation-plan-c50f36`. Paths starting `visual-api/` are under `C:/Users/TylerW/infor-api/.claude/worktrees/api-development-90ed7e/visual-api`. Anything marked **[UNCONFIRMED]** has not been checked against code or the VECA schema.

## Scope confirmed by Tyler (2026-11-11)

- **In scope:** Claude creates and edits orders through MCP as **drafts saved in the portal**. Nothing more.
- **Human accept step:** the rep signs in to the portal, opens the draft, confirms the order is correct with an explicit acknowledgement, and submits it. Claude never submits.
- **Handoff:** a separate project of Tyler's pulls *submitted* orders from the portal, validates them and commits them to VISUAL.
- **Out of scope:** everything that touches the ERP. That covers section 5 (the VISUAL gateway changes and `etl/push_orders.py`), the `erp_push_*` columns in migration 3, the ERP-push gaps in section 6 (items 9-12), and the v2 phase in section 9. The pull tool needs a stable, documented read of submitted orders. It needs no push state in the portal.
- **Added for the accept step:**
  - `orders.acknowledged_at` / `acknowledged_by`, stamped by `submit_order` when it receives an explicit acknowledgement flag.
  - For orders with `source='mcp'`, the portal blocks Submit until the rep ticks "I've reviewed this order and it is correct". The MCP badge and warnings are shown next to the checkbox.
  - Open: should the acknowledgement apply to all orders, or only to MCP-created ones?
- **Phase 0 is done** (2026-11-11): the three FFL migrations are live and the order guard tests pass.

## Revised design (2026-11-11, after Tyler's use cases)

Where this section and the older sections below disagree, this section wins.

**Who creates drafts, and how**

| Who | Client | Customers they can draft for | Can they submit? |
|---|---|---|---|
| Tyler (pilot, admin) | Claude Desktop/Code, header token | any customer | yes, in the portal |
| Inside sales (`order_entry` role) | Claude or ChatGPT, with an email dragged in | any customer | yes, in the portal, after acknowledging |
| Rep on the road | Claude or ChatGPT mobile, by voice | their own book (`my_customer_keys()`) | yes, from a phone deep link |
| Inbox bot (service profile) | scheduled agent reading a shared inbox | any customer | **no**, drafts only. Inside sales submits. |

**Gating.** There are two independent switches. `feature.orders` turns on hand entry in the portal. `feature.mcp_orders` turns on drafting over MCP; who may draft is the `public.mcp_order_users` table (one row per person, managed by admins in the portal); for now that holds only Tyler. The draft review and submit screen shows when either switch is on. Today that screen sits behind `feature.orders` in the router, so the router has to be split.

**Ownership changes** (these replace the "rep owns everything" assumption):
- `orders.created_by` is the person or bot that made the draft. `orders.user_id` stays the owner. `orders.sales_rep_key` is the rep the order is for, resolved from the customer when not given.
- `orders.source` takes one of `portal` / `mcp` / `inbox`. `orders.source_ref jsonb` holds email metadata when the order came from an email: sender, subject, received_at, message id, and the original text, which reviewers see next to the order.
- `submit_order` lets these submit: the owner, an admin, or an `order_entry` user when `source <> 'portal'`. It also requires `p_acknowledged=true` for non-portal orders and stamps `acknowledged_at` / `acknowledged_by`.
- RLS: `order_entry` can see drafts where `source <> 'portal'`. That is the new **"Drafts to review"** queue. Inside sales and admins can create MCP drafts for any customer. Reps stay limited to their own book.

**Clients.**
- **v1 (Tyler):** header tokens from Claude Desktop/Code, as already planned.
- **For claude.ai, mobile and ChatGPT:** turn on the Supabase Auth OAuth 2.1 server (Dashboard only, since there is no CLI or token for it here). Then add a `/oauth/consent` page in the portal and protected-resource metadata on the MCP function. OAuth replaces the "write scope only in a header" rule, because the token no longer sits in a URL.
- **Not doing:** opening write scope to URL tokens as a stopgap. Drafts can't be submitted, so the risk would be small, but a leaked URL could still flood the review queue.

**Product resolution for voice and email** ("one 6.5 Creedmoor Ridgeline FFT in black and grey"):
- `search_order_products` takes free text and matches it against the family, chambering, finish, barrel length and description fields in `dim_part`.
- It uses a small synonym table: `6.5 CM` / `6.5 Creedmoor` / `6.5CM`, `FFT`, finish colour names.
- It returns ranked candidates with a `match_confidence`. With one clear match, Claude drafts. With more than one, Claude asks a single short question.
- The draft response includes a **portal deep link**. The rep taps it, ticks the acknowledgement and submits, so the order writer's review screen has to work on a phone.

**Inbox bot.**
- A scheduled agent reads a dedicated mailbox through the Outlook connector and calls the same MCP tools with the bot's token.
- Email text is untrusted. The bot cannot submit, it is held to the caps and the daily limit, and the reviewer sees the original email. That keeps the damage from a malicious or garbled email to one bad draft that a person rejects.
- The bot replies to no one. Inside sales handles the conversation.

**Middleware handoff.** `v_orders_ready_for_erp` is a stable view over submitted orders, with their lines, ship-to and FFL snapshot, acknowledgement and source. Tyler's middleware reads it with its own key and takes it from there. Nothing in the portal touches the ERP.

**Rollout (replaces section 9)**
1. **v1, Tyler only:** the flag split, ownership columns, `get_order_context`, `search_order_products` (fuzzy matching), create/update/cancel draft, `get_order_status`, acknowledge plus submit in the portal, and the middleware view.
2. **v1.1, inside sales:** the `order_entry` review queue, drafting for any customer, `source_ref` from dragged-in emails.
3. **v1.2, reps on mobile and ChatGPT:** the OAuth 2.1 server and consent page, and a phone-friendly review screen.
4. **v1.3, inbox bot:** the bot profile and token, the mailbox, and the scheduled agent.

## TL;DR

- **The mechanics are easy.** The MCP edge function already runs every call as the rep. It mints a 5-minute `authenticated` JWT whose `sub` is the rep (`supabase/functions/_shared/mcpAuth.ts:182-224`). Because of that, the existing orders RLS and `submit_order()` already apply to MCP calls without any change (`supabase/migrations/20260817000200_orders.sql:155-227`; the latest `submit_order` is in `20261030140000_order_ffl_when_needed.sql:140-299`).
- **The safety gaps are the real work.** Tokens have no scope (`20260816120000_mcp_access.sql:59-73`). Nothing in SQL checks `feature.orders` (`20260817000200_orders.sql:163-170`). There is no idempotency, no record of where an order came from, and no audit trail.
- **Recommended shape:**
  - A new `feature.mcp_orders` flag, which also requires `feature.orders`.
  - A per-token `orders:draft` scope, sent only in a header.
  - Read tools: `get_order_context` (customer, ship-tos, contacts, FFL, price lists) and `search_order_products` (price, stock and FFL for that customer).
  - Write tools: `create_order_draft`, `update_order_draft`, `cancel_order_draft` and `get_order_status`. Each write tool is one SECURITY DEFINER RPC that runs the gate, sets prices on the server, and does a dry run of `submit_order`.
- **Claude never submits.** The rep clicks Submit in the portal. Order entry, or a later ERP pusher, takes the order from there. Any confirm token Claude can see is not a human check (see section 7).
- **The data is mostly there for drafts.** Customers, ship-tos with ADDR_NO and FFL, contacts, priced firearms for DEALER and BUY_GROUP, and SHIPPING stock are all synced. Two things block it:
  - The ship-to/FFL migrations are not live.
  - Prices exist only for DEALER and BUY_GROUP, and only for 403 firearm SKUs.
- **The automatic push to VISUAL is a separate, larger project.** The gateway accepts only WooCommerce orders on one fixed customer (`visual-api/gateway/src/visual_api/customer_orders/models.py:61-74`; `preview.py:65-75`). It would need a dealer profile, a crm-portal source, a decision on firearms (they get TRACED_PART today) and a PO-marker decision first.

## Is the data there?

| Need | Synced today? | Source | Gap fix | Blocks v1 (Claude drafts)? |
|---|---|---|---|---|
| Customer lookup (name, key, type, status) | Yes, loaded hourly | `erp.dim_customer` (`supabase/migrations/002_erp_read_tables.sql:35-98`), `v_account_list` via `search_accounts` (`supabase/functions/mcp/tools.ts:274-348`) | none | No |
| Customer type → price list | Partly. `customer_type` is null on 32,919 of 41,817 customers, including 1,955 that ordered in the last 365 days | `dim_customer.customer_type`, `effective_price_lists()` (`20260817000100_price_lists.sql:139-171`, which returns no list for a null type) | Fix types in VISUAL, or block with a clear reason | Only for untyped customers |
| Credit hold | Status yes (VFIN words: APPROVED/HOLD/HOLDORD/HOLDSHIP). Exposure and open AR are not synced | `dim_customer.credit_status` (`docs/bi_schema/vw_DimCustomer.sql:39-41,158-159`) | Warn or block on HOLD and HOLDORD. Credit headroom is out of scope | No |
| Ship-tos with ADDR_NO, active flag, FFL | Yes, twice a day (full run). 21,452 real ship-tos | `erp.dim_ship_to` (`002_erp_read_tables.sql:107-135`; `docs/bi_schema/vw_DimShipTo.sql:26-92`) | Show an "as of" time | No |
| FFL rule functions and order ship-to/FFL columns | **Not live.** Migrations 20261030120000, 140000 and 150000 are in the repo but not deployed. Live `orders` has 19 columns | `20261030120000_order_ship_to_ffl.sql:35-45`; `20261030140000_order_ffl_when_needed.sql:26-135`; `20261030150000_ffl_rule_alignment.sql` | Apply them with `etl/deploy_migrations.py`, then run `supabase/tests/20261030_order_ship_to_ffl.sql` | **Yes** |
| FFL on file | Partly. About 1,027 of 3,054 active dealer ship-tos have a 15-character FFL. Expiry is free text | `dim_ship_to.ffl_license_number` / `ffl_expiration_raw` | The rep enters missing FFLs in the portal (see section 7) | No, but most firearm drafts will need FFL work |
| Contacts / buyer | Yes. 44,118 ERP contacts plus rep-entered contacts | `erp.dim_customer_contact` (`032_tracking_ats_contacts_reporting.sql:227-257`), `v_account_contacts`, `list_contacts` (`tools.ts:1740-1826`) | Add an order column for the contact (section 4.1) | No |
| Orderable parts | Approximated as status `A` plus being on an effective list. No sellable flag. 1,081 parts have a null status | `erp.dim_part` (`docs/bi_schema/vw_DimPart.sql:47-117`) | none (use the approximation) | No |
| Firearm or not | Heuristic: product code is not "component" and the part has a real family or chambering. An unknown part counts as a firearm (fails safe) | `part_requires_ffl()` (`20261030150000_ffl_rule_alignment.sql:27-38`), not live | Comes with the FFL migrations | Yes (same blocker as above) |
| Prices | **Partly.** Two lists, 2026 Dealer and 2026 Buy Group, 403 firearm SKUs each, no specials. MSTR_DLR (55 customers), DISTRIBUTOR (23), accessories and parts have no price | `public.price_lists` / `price_list_items`, uploaded as CSV by an admin (`20260817000100_price_lists.sql:10-84`), `v_price_list_items` (`20260818000100_price_list_item_lookup.sql:32-53`) | Upload more lists. v1 restricts to DEALER and BUY_GROUP | Only for unpriced types and SKUs |
| Customer-specific ERP pricing | No. `price_group` is 100% null and `standard_unit_price` is null or 0 on 79% of parts | — | Out of scope | No |
| Stock | Partly. ATS covers only TDJ/SHIPPING (838 rows, 54 positive). 27 of the 403 priced SKUs are in stock and 227 have no ATS row at all. There is no next-available date | `erp.fact_available_to_sell` (`docs/bi_schema/vw_FactAvailableToSell.sql:1-56`), `v_ats_list` | Label a null as "no stock data". Add MAIN on-hand from `fact_inventory_on_hand` in the next phase | No (stock never blocks a draft) |
| Warehouse for lines | Not on ship-tos: `warehouse_id` is null on every dealer ship-to. History shows MAIN (1,603 of 1,823 lines in 90 days). Part-warehouse setup is not synced | — | Profile default MAIN. Add `erp.dim_part_warehouse` for the ERP push | No (needed for the ERP push) |
| Terms, freight terms, customer ship via | No. Only VFIN `ar_terms_rule_id` is synced. `ship_via` is null on 96% of ship-tos | `docs/bi_schema/vw_DimCustomer.sql:162` | Let VISUAL default them, which needs a gateway change (section 5). Or add the columns to `bi.vw_DimCustomer` (needs the BI view owner, `docs/erp_changes/2026-10-27_bi_view_changes.md:3-5`): add-column migration first, then a full push | No (needed for the ERP push) |
| Tax group | Ship-to default is synced | `dim_ship_to.default_sales_tax_group_id` | Decide in the gateway (section 5) | No (needed for the ERP push) |

---

## 1. Goals and non-goals

**Goals**
- Through the existing MCP server, Claude can:
  - resolve a dealer, then its orderable ship-tos, contacts, FFL status, credit status and applicable price lists;
  - find parts priced for that customer, with stock and whether each one needs an FFL;
  - build a portal order that passes exactly the same server checks as an order typed into the portal.
- `submit_order()` stays the only authority on price, ship-to, FFL and promo (`20261030140000_order_ffl_when_needed.sql:140-299`). No validation is copied into new code.
- The feature is off unless the new MCP order setting is on, and that is enforced in SQL, not only in the UI or in TypeScript.
- Orders carry where they came from and a stable key, so a later on-prem push into VISUAL through visual-api is safe and cannot double-enter an order.

**Non-goals**
- The edge function never writes to VISUAL directly. The ERP push runs as an on-prem job.
- No new pricing logic and no ERP customer pricing. Only the app price lists are used.
- No creating customers or ship-tos and no editing addresses, matching the gateway's OQ-15 decision (commit 7317816 on visual-api main). If a ship-to is missing, Claude tells the rep to add it in VISUAL first.
- Claude cannot submit, recall, reopen, or cancel a submitted order. Those stay portal actions.
- No MCP elicitation. The server is stateless and sends nothing to the client on its own (`supabase/functions/mcp/index.ts:5-12, 239-251`; capabilities at `:152`).

---

## 2. The new setting

### 2.1 Global flag: `feature.mcp_orders` in `public.app_settings`
It uses the existing setting_key / `enabled` / `params jsonb` pattern (`supabase/migrations/024_app_settings.sql:37-44`). It is seeded **off**, and it has no effect unless `feature.orders` is also on (`20260817000200_orders.sql:715-718`).

```json
{
  "allow_admin_tokens": false,     // see 2.4; the pilot decides this
  "max_lines": 40,
  "max_units_per_line": 200,
  "max_order_value": 250000,
  "max_drafts_per_user_per_day": 25,
  "duplicate_window_days": 14,
  "customer_types": ["DEALER","BUY_GROUP"]
}
```

**Who may draft: `public.mcp_order_users`** (not a params key, so the list changes without a config edit or deploy). Columns: `user_id` (PK, FK `profiles`, cascade), `added_by` (default `auth.uid()`), `added_at`, `note` (<= 200 chars). No row = not allowed; there is no wildcard. RLS: admins select/insert/delete; any user may select only their own row (the edge function and the portal nav read that). No UPDATE (delete + insert). It carries the view-as write-block trigger, and a second trigger refuses any insert/delete from an MCP session (`mcp_cannot_change_allow_list`), so Claude can never grant itself drafting. `mcp_orders_user_allowed(uid)` = a row exists AND the profile is active. Seeded with Tyler (`note = 'v1 pilot'`).
There is no `allow_submit` param, because Claude never submits (see section 7).

**Admin UI:** `frontend/src/components/admin/FeatureFlagsCard.vue:26-36` toggles only `enabled`, through a hard-coded `LABELS` map. v1 needs two changes there:
- Add a `'feature.mcp_orders'` label.
- Either build a small params editor (an allow-list picker, caps, customer types) or document that admins set params with SQL. I recommend the small editor, because otherwise the allow-list cannot be changed without SQL.

### 2.2 Enforced in two layers
1. **SQL (the authority).** Add two new functions:
   - `public.feature_enabled(p_key text) returns boolean`: STABLE, SECURITY DEFINER, with `search_path` pinned.
   - `public.mcp_orders_gate() returns jsonb`: raises `orders_disabled`, `mcp_orders_disabled`, `not_mcp_session`, `mcp_scope_missing`, `mcp_user_not_allowed` or `mcp_admin_not_allowed`, and returns the params when every check passes.

   Every `mcp_*` write RPC calls the gate first. Today no SQL checks `feature.orders`. Only the router (`frontend/src/router/index.ts:158, 391`) and the ETL (`etl/views.yml:273`) do.
2. **Edge function (what the model sees).** `tools/list` and `tools/call` compute the tool set for each request (section 3.4). A hidden tool is left out of the list and refused if it is called.

### 2.3 Per-token opt-in: `mcp_tokens.scopes text[] not null default '{}'`
- Without a scope column, turning the flag on would give write access to every existing token. That includes claude.ai URL tokens that reps minted under the "it cannot change anything" promise (`frontend/src/pages/ConnectView.vue:98-102`; `mcpAuth.ts:78-81`).
- **Scope:** `orders:draft` is the only one.
- **Changing `mcp_token_create` changes its signature.** `create or replace` with a new argument list adds a second overload instead of replacing the function. Migration 2 must therefore:
  - run `drop function public.mcp_token_create(text, uuid, int)`;
  - create the version that takes `p_scopes text[] default '{}'`;
  - re-issue revoke and grant on the new signature, which today is done by exact signature at `20260816120000_mcp_access.sql:355-358`;
  - update the rpc call in ConnectView.
- **Rules for write tokens:**
  - only while `feature.mcp_orders` is on;
  - lifetime of 90 days at most;
  - one live write token per user;
  - the user must have a row in `mcp_order_users`.
- **Returning the scope:** `mcp_token_resolve` (`20260816120000_mcp_access.sql:271-343`) returns `scopes`. `McpCaller` (`mcpAuth.ts:56-64`) gains `scopes` and `realRole`; today every non-admin role is mapped to `'rep'` (`mcpAuth.ts:136`). Update the comment about turning a read endpoint into a write endpoint (`20260816120000_mcp_access.sql:~270-275`).
- **Signed claims:** `callerClient` adds `app_metadata.mcp_token_id` and `app_metadata.mcp_scopes` to the JWT it mints, next to the existing `provider:'mcp'` (`mcpAuth.ts:195-196`). Only the function holds the signing secret, so SQL can trust `auth.jwt()->'app_metadata'`. The gate reads the scope from there. That gives a second scope check inside the database, and it means a normal portal session cannot call the `mcp_*` RPCs (`not_mcp_session`).
- **Header-only write scope (decide before v1).** Tokens can arrive by `?token=` or in the path (`mcpAuth.ts:83-104`). The existing code justifies that only because tokens are read-only (`mcpAuth.ts:78-81`). `extractToken` will report how the token arrived. If it arrived in the URL, the function drops the write scope for that request: the read tools still work and the write tools are hidden. As a result, order drafting works from Claude Code and Desktop (custom headers), and does not work from a claude.ai URL connector (`supabase/functions/mcp/README.md:102-109`) until OAuth is supported.
- **ConnectView:** add a "Let Claude draft orders" checkbox, shown only when the flag is on and the user is allowed. It needs re-consent wording and should show the header-only setup snippet. Existing tokens stay read-only.

### 2.4 Admin and pilot identity (decide before building)
`my_customer_keys()` has **no admin branch**. It returns the caller's own book, their group's book and explicit grants, all through `effective_user_id()` (`20260816140000_admin_view_as_rep.sql:194-246`). An owner or admin profile with no `sales_rep_key` therefore gets an empty set. The RLS insert policy has a separate `is_admin()` branch (`20260817000200_orders.sql:163-170`) that a SECURITY DEFINER check would skip. If the pilot is "Tyler" under an admin profile, every draft would be refused. Two options:
- **(a)** Pilot with a real rep account that has a `sales_rep_key`, or give Tyler `account_assignments` grants for the pilot dealers. This is my recommendation.
- **(b)** Set `allow_admin_tokens=true` and check `customer_key = any(my_customer_keys()) OR is_admin()`, matching RLS. In that case the draft response must clearly name the customer and book, and an admin token reaches every account.

An admin who has a view-as session open gets `read_only_while_viewing_as` from the write-block trigger (`20260816140000_admin_view_as_rep.sql:450-462`; `20260901190200_view_as_trigger_sweep.sql`). The tool should map that to a clear message, and `whoami` should report it.

---

## 3. MCP tools

### 3.1 Existing tools reused
| Tool | Role in the order flow | Source |
|---|---|---|
| `search_accounts` | name → `customer_key` | `supabase/functions/mcp/tools.ts:274-348` |
| `list_contacts` | standalone contact ranking | `tools.ts:1740-1826` |
| `check_availability` | wider ATS browsing | `tools.ts:1120-1177` |
| `lookup_order` | ERP-side status after an order is keyed | `tools.ts:1323-1371` |
| `whoami` (**changed**) | adds `capabilities: {orders, mcp_orders, scopes, write_scope_active, viewing_as}` | registry `tools.ts:2069-2091` |

### 3.2 New read tools
These are visible when `feature.orders` is on and the caller holds a write scope. They run as the rep through `ctx.db`, with no service_role (`tools.ts:4-12`).

**`get_order_context`** calls the new RPC `public.order_context(p_customer_key text)`, which is SECURITY INVOKER.
```jsonc
// input
{ "customer_key": "string (required)" }
// output
{ "customer": { "customer_key","customer_name","customer_type","credit_status",
                "ar_terms_rule_id","currency_id",
                "tax_exempt": bool,   // derived from dim_customer.tax_exempt_flag (text)
                "active": bool },      // derived from active_flag (text)
  "orderable": bool,
  "blockers": ["no_price_list_for_type","credit_hold","inactive","type_not_enabled_for_mcp"],
  "price_lists": [{ "price_list_id": "bigint","name","kind":"general|special","promo":{"buy","get"}|null }],
  "ship_tos": [{ "ship_to_key","ship_to_id","addr_no","name","address","city","state",
                 "active": bool, "orderable": bool,
                 "ship_via","free_on_board",
                 "ffl": {"number_on_file","expires_raw","current": bool} }],
  "default_ship_to_key": "string|null",       // only when exactly one ship-to is orderable
  "contacts": { "best_contact": {...}, "ranked": [...] },   // same code path as list_contacts
  "recent_portal_orders": [{ "order_id","status","po_number","created_at","total_amount","source" }],
  "data_as_of": { "customers","ship_tos","contacts" } }   // ship-tos and contacts load twice daily
```
**Ship-to rule.** Start from `orderableShipTos` (`frontend/src/lib/orderShipTo.ts:45-61`): address_source='ShipTo', not unknown, and a non-empty ship_to_id. That function **keeps inactive rows** so the picker can grey them out (`:45`, `:64`). `order_context` must add `orderable = active AND …` to match `submit_order`, which refuses inactive ship-tos (`20261030140000:~185-197`). FFL currency comes from `ffl_on_file_current` (`:99-105`), or from `order_ffl_context` (`:110-126`).

**`search_order_products`** calls `public.order_product_search(p_customer_key, p_query, p_family, p_chambering, p_in_stock_only, p_limit)`, which is SECURITY INVOKER.
```jsonc
{ "items": [{ "part_id","description","family","chambering","barrel_length","finish","status","is_kit",
              "options": [{ "price_list_id","price_list_name","kind","unit_price","promo" }],   // one per applicable list
              "requires_ffl": bool,
              "stock": { "ats_qty": n|null, "warehouse": "SHIPPING",
                         "label": "in_stock|short|no_stock_data" } }],
  "notes": ["Prices from <list>; stock is SHIPPING ATS only. A missing stock row means no data, not zero. Stock never blocks an order."] }
```
- It joins `effective_price_lists(customer_type)`, `v_price_list_items` and `v_ats_list`, and uses `part_requires_ffl`.
- It returns no cost columns. The column grants prevent that (`20260901190300_erp_column_grants.sql:1-35`).
- It returns `is_kit` from `dim_part.is_kit_flag` (`002_erp_read_tables.sql:189`). v1 refuses kits until we know how they price.
- **Choosing a list.** Promos exist only on special lists (`20260817000100_price_lists.sql:61`). The SPA preselects the general list and the rep picks a special explicitly (`frontend/src/pages/orders/OrderWriterView.vue:40, 239, 254`). The draft RPC therefore uses the general list unless `price_list_id` is passed. If a part appears on several lists, the tool returns every option, and the INSTRUCTIONS tell Claude to ask the user which one.

### 3.3 New write tools
These are visible only when the gate would pass for this caller. Each one is a thin wrapper over one RPC.

**`create_order_draft`** calls `mcp_create_order_draft(p jsonb)`.
```jsonc
// input
{ "idempotency_key": "string 8-100 (required)",
  "customer_key": "string (required)",
  "ship_to_key": "string (required)",
  "po_number": "string <= 40",              // dealer PO; length aligned with VISUAL's 40-character limit (see section 5 for where it goes)
  "requested_ship_date": "YYYY-MM-DD, >= today",
  "customer_contact_key": "string|null",    // checked against erp.dim_customer_contact for this customer
  "ship_via": "string|null",                // checked against carrier codes seen in dim_ship_to [UNCONFIRMED list]
  "ship_complete": bool,                    // false = partial shipment / backorder allowed
  "notes": "string <= 1000",
  "allow_duplicate": false,                 // must be true to proceed past a duplicate block; Claude only sets it after the user says so
  "lines": [{ "part_id": "string", "qty": "integer 1..max_units_per_line", "price_list_id": "bigint|null" }] }
// There is NO price field and NO FFL field.
// output
{ "order_id": "bigint", "status": "draft", "replayed": bool, "source": "mcp",
  "customer_name", "ship_to": {...}, "contact": {...}|null,
  "requires_ffl": bool, "ffl_source": "on_file|missing",
  "lines": [{ "part_id","description","qty","price_list_name","unit_price","discount_pct","effective_unit_price","line_total","stock" }],
  "total_amount",
  "would_submit": { "ok": bool, "error": "ffl_required|ship_to_not_orderable|price_changed|…"|null },
  "warnings": ["qty exceeds SHIPPING ATS for X", "no FFL on file: rep must enter it in the portal before submitting"],
  "portal_url": "https://<portal>/orders/<id>",
  "next": "Show the user this preview. The rep reviews and submits in the portal." }
```
**FFL.** The model may not supply an FFL. In `submit_order`, a rep-entered `ffl_license_number` takes priority over the licence on file even when the one on file is current. The only checks are the length and an unexpired date (`20261030140000:~200-224`). A licence number that is hallucinated or injected would therefore become the FFL of record. When no current FFL is on file, the draft is created with `would_submit.error='ffl_required'`, and the rep enters the licence in the portal. That is the existing UI, and it applies the existing checks.

**`update_order_draft`** (in v1, because conversational fixes are the common case) calls `mcp_update_order_draft(p_order_id bigint, p jsonb)`.
- Input has the same shape as create, minus the idempotency key, plus a `lines` replacement.
- It replaces the header and lines inside one transaction, so it avoids the delete-then-insert risk at `OrderWriterView.vue:366-372`.
- It works only on a `draft` where `source='mcp'` and the caller is the owner.
- It returns the same preview. Updates do not count against the daily draft cap.

**`cancel_order_draft`** calls `mcp_cancel_order_draft(p_order_id)`.
- **Drafts only.** `cancel_order` also allows `submitted` (`20260817000300_order_review_hardening.sql:211-216`), so the wrapper adds `status='draft'` on top of the gate, the owner check, the source check and the audit.
- Cancelling a submitted order stays a portal action.
- Annotations: destructiveHint true.

**`get_order_status`** (read). Input `{order_id?: bigint, idempotency_key?: string}`. Output `{order_id, status, source, submitted_at, entered_at, erp_order_number, qc: [{result, detail}], erp_push: {state, request_id, visual_order_id, error}|null}`, read from `public.orders` and `order_qc_results` (`20260817000200_orders.sql:106-120`) and scoped by `my_order_ids()` (`:128-137`).

**`list_my_order_drafts`** takes `{status?: 'draft'|'submitted', source?: 'mcp'|'any', limit}`. It lets Claude resume work or clean up.

No submit tool exists, for the reasons in section 7.

### 3.4 Edge-function changes
- `ToolDef` (`tools.ts:38-49`) gains `annotations?`, `requires?: 'orders'|'mcp_orders'` and `scope?: 'orders:draft'`. `describeTool` (`tools.ts:2113-2121`) stops forcing `READ_ONLY` (`:58-63`). Write tools get readOnlyHint false, destructiveHint false (true for cancel), idempotentHint true for create (keyed), and openWorldHint false.
- The new file `supabase/functions/mcp/orderTools.ts` is spread into `ALL_TOOLS` (`tools.ts:2069`). `MCP_DISABLED_TOOLS` (`:2101-2108`) still works as a deploy-level kill switch.
- In `index.ts` `tools/list` (`:165-168`) and `tools/call` (`:192-222`), build the set for each request from `caller.scopes` (after the URL-token downgrade) plus one `ctx.db.from('app_settings').select(...).in('setting_key',['feature.orders','feature.mcp_orders'])`. Nothing is cached at module scope. A hidden tool gets `-32602` "unknown tool". Keep `listChanged:false` (`:152`) and document that changing the flag requires reconnecting.
- **Audit logging happens in the edge function, outside the RPC's transaction.** A refusal is a RAISE, so a log row written inside the RPC would roll back with it. After every write-tool call, success or failure, call `ctx.db.rpc('mcp_log_call', {...})` in its own request. `mcp_log_call` only accepts JWTs carrying `app_metadata.provider='mcp'`.
- The INSTRUCTIONS (`index.ts:50-51`) gain an "Ordering" paragraph only when write tools are listed. It covers:
  - the order of calls: get_order_context, then search_order_products, then create_order_draft, then update_order_draft as needed;
  - always show the preview, and tell the rep to submit in the portal;
  - stock never blocks a draft;
  - never invent an FFL;
  - ask before using `allow_duplicate`;
  - if a ship-to is missing, it must be added in VISUAL first.
- Map RPC error codes to `ToolError` text the model can act on (the `isError:true` path at `index.ts:205-221`).
- Update the read-only wording in: `tools.ts:4`; `README.md:10, 157-162` (change "No write tools" to "Order drafting, gated"); `ConnectView.vue:98-102`; the comment at `mcpAuth.ts:78-81`; and `20260816120000_mcp_access.sql:~270-275`.

---

## 4. Server-side flow and SQL

### 4.1 Migrations
Apply them only through `etl/deploy_migrations.py`, and commit and baseline each one on the same day.

0. **Prerequisite:** deploy `20261030120000_order_ship_to_ffl.sql`, `20261030140000_order_ffl_when_needed.sql` and `20261030150000_ffl_rule_alignment.sql`. Live `deployed_migrations` stops at 20261028100000.
1. `…_mcp_orders_flag.sql`: `feature_enabled()`, `mcp_orders_gate()`, `caller_is_active()`, and the seed row `feature.mcp_orders` (off).
   - `caller_is_active()` is a **new** helper. Today every RPC checks `profiles.active` inline, for example `20260817000300_order_review_hardening.sql:198-202`, and no `is_active` function exists.
2. `…_mcp_token_scopes.sql`: the `scopes` column; drop the old `mcp_token_create` and recreate it (section 2.3); restate `mcp_token_resolve`; re-issue the grants.
3. `…_order_provenance.sql`, adding these columns to `public.orders`:
   - `source text not null default 'portal' check (source in ('portal','mcp','api'))`
   - `mcp_token_id uuid references mcp_tokens(id)`
   - `client_request_id text`, `request_hash text`, plus a unique index on `(user_id, client_request_id) where client_request_id is not null`
   - `customer_contact_key text`. The ERP column is `customer_contact_key`, per `032_tracking_ats_contacts_reporting.sql:228`.
   - `ship_via text`, `ship_complete boolean`
   - `mcp_warnings jsonb`. This stores the final preview warnings so order entry can see them.
   - ERP push columns, added once here: `erp_push_state text check (... in ('claimed','queued','in_progress','in_doubt','created','linked_existing','failed','needs_attention'))`, `erp_request_id text`, `erp_pushed_at timestamptz`, `erp_push_error jsonb`.

   Show the contact, ship via, ship complete and the MCP warnings in `OrderQueueView.vue` and `OrderDetailView.vue`.
4. `…_mcp_tool_calls.sql`: an append-only `public.mcp_tool_calls` table with id, created_at, user_id, token_id, tool, args jsonb (contact PII stripped), outcome `ok|refused|error`, error_code and order_id.
   - RLS: a user reads their own rows, admins read everything, and order_entry reads rows for non-draft orders.
   - Rows are written only by `mcp_log_call()`, which is SECURITY DEFINER and follows the `impersonation_events` precedent (`20260816140000_admin_view_as_rep.sql:86-101`).
   - Exclude the table from the view-as write-block sweep (`20260901190200_view_as_trigger_sweep.sql:6-23`).
5. `…_mcp_order_rpcs.sql`: the RPCs in section 4.2.

### 4.2 RPCs
- **`order_context` and `order_product_search`** are SECURITY INVOKER, so RLS on `dim_customer` and `dim_ship_to` (`010_access_performance.sql:193-200`) limits them to the rep's book. They reuse `effective_price_lists`, `order_ffl_context`, `part_requires_ffl` and `ffl_on_file_current`.
- **`mcp_create_order_draft(p jsonb)`** is SECURITY DEFINER and runs as one transaction:
  1. Call `mcp_orders_gate()` to get the params.
  2. Idempotency. If `(auth.uid(), client_request_id)` already exists, compare `request_hash` (sha256 of the normalised jsonb). Same hash: return the existing draft with `replayed:true`. Different hash: raise `idempotency_conflict`. This mirrors `visual-api/docs/transactions/customer-orders.md:232-239, 288-296`.
  3. Repeat the RLS conditions explicitly, because DEFINER bypasses RLS:
     - `caller_is_active()`;
     - `customer_key = any(my_customer_keys())`, plus `OR is_admin()` only when `allow_admin_tokens` (section 2.4);
     - `customer_type` is in `params.customer_types`.
  4. Validate the inputs that nothing checks today:
     - PO is at most 40 characters;
     - ship date is today or later;
     - notes are at most 1000 characters;
     - the contact belongs to this customer;
     - no kits;
     - caps on lines, units per line, order value and drafts per day.
  5. **Server-side duplicate block** (as well as the key, since a model that retries usually invents a new key). If the same caller has a non-cancelled order for the same `customer_key` with the same PO, or with the same normalised line set, within `duplicate_window_days`, raise `possible_duplicate:<order_id>` unless `allow_duplicate=true`. Drafts that were cancelled or replaced through update do not count.
  6. Set every price on the server. For each line, use the general list in `effective_price_lists(customer_type)`, or the `price_list_id` passed if it is effective for this customer. `unit_price` comes from `price_list_items`. A part with no price raises `part_not_orderable:<id>`.
  7. Insert the header (`status='draft'`, `source='mcp'`, `mcp_token_id` from the JWT claim) and the lines.
  8. **Dry run of submit, with no duplicated validation.** Inside a PL/pgSQL `BEGIN … EXCEPTION` block:
     - `PERFORM submit_order(id)`, then raise a sentinel `__dry_run_ok`;
     - the sentinel means `would_submit.ok`, and any other SQLERRM is the first refusal;
     - the subtransaction rolls back, so the order stays a draft.

     The promo `discount_pct` and `effective_unit_price` for the preview are recomputed with the same formula (`20260817000200_orders.sql:258-272`; `20261030140000:248-273`). **[Spike: confirm the subtransaction approach and the exact error strings.]**
  9. Store `mcp_warnings` and return the preview. The edge function writes the audit row (section 3.4).
- **`mcp_update_order_draft` and `mcp_cancel_order_draft`** run the gate, then check the owner, `source='mcp'` and `status='draft'`, then do their work. Update repeats steps 3-8. Cancel delegates to `cancel_order` (`20260817000300_order_review_hardening.sql:190`).
- **`submit_order` is unchanged.** It is called only from the portal. One recommended hardening for every caller: `submit_order` does not re-check that `customer_key ∈ my_customer_keys()` at submit time. Consider adding that when it is next restated, starting from the 20261030140000 body plus the 20261030150000 helpers.

Submitted orders land in the existing queue (`frontend/src/pages/orders/OrderQueueView.vue:16-24, 64-80`). From there, `mark_order_entered` (`20260817000200_orders.sql:422-462`) and `run_order_qc` (`:554-691`) work as they do today.

### 4.3 Frontend
- An "MCP / Claude" badge and the `mcp_warnings` on order rows and on `OrderDetailView.vue`, plus a source filter in the queue.
- Header fields for contact, ship via and ship complete in `OrderWriterView`, so the rep can see and edit them.
- The FeatureFlagsCard label and a params editor (section 2.1).
- The ConnectView scope checkbox (section 2.3).

---

## 5. Mapping to the VISUAL gateway and what must change there

What the gateway does today:
- It accepts only `source.system='woocommerce'` with `extra='forbid'` (`visual-api/gateway/src/visual_api/customer_orders/models.py:56-74`).
- It always writes CUSTOMER_ID, TERMS_ID and WAREHOUSE_ID from the profile (`preview.py:32, 65-75`).
- `terms_id` and `warehouse_id` are required on the profile (`config.py:65-66`).

The worker accepts any `^[A-Z][A-Z0-9_]*$` column (`contracts/worker-commands/customer-order.create.v1.schema.json:18-31, 44-49`). However, the header apply order is a shared, tested contract. It is hard-coded as SITE_ID, CUSTOMER_ID, TERMS_ID, WAREHOUSE_ID, and every other column follows in byte-wise name order (`worker/src/VisualApi.Worker.Core/Commands/CustomerOrderCreateCommand.cs:27`; `preview.py:32`; `contracts/README.md` "Field apply order"). So most of the changes are in the gateway, and **the apply order is a contract change across worker, gateway and README together.**

| Portal field | Gateway command (new `crm-portal` source / dealer profile) | VISUAL column | Status |
|---|---|---|---|
| orders.id | discriminated SourceRef `{system:'crm-portal', store:'crm-portal', order_id: orders.id, order_number: str(id)}`, no order_key (or a fixed one); Idempotency-Key `crm-order-<id>` | journal / dedup | model change: today SourceRef requires store, order_number, order_key and modified_at (`models.py:61-74`) |
| (marker) | **profile `po_ref_format='CRM-{number}'`** (`config.py:67, 88-94`) | CUSTOMER_PO_REF | **Decided:** layer 3 searches CUSTOMER_PO_REF across every customer and every status (`customer-orders.md:297-317`; `contracts/README.md` worker step 2). A shared dealer PO such as "1234" would link to another dealer's order and write back the wrong VISUAL id. |
| po_number (dealer PO) | new explicit header field | **[UNCONFIRMED column; needs a VECA schema / toolkit spike]** | gateway change |
| customer_key | `customer_id`, per request on the dealer profile | CUSTOMER_ID | gateway change, plus checks in VECA that the customer exists and is active |
| ship_to_addr_no snapshot | `ship_to_addr_no` | SHIP_TO_ADDR_NO (confirmed, `customer-orders.md:504-505`) | gateway change; **add it to HEADER_APPLY_ORDER right after CUSTOMER_ID**, and spike which columns it re-defaults (extend S-7, `customer-orders.md:787`) |
| terms | omitted, so VISUAL uses the customer's terms | TERMS_ID | **gateway change:** make `terms_id` optional, or add a "customer default" mode, and have `build_header` skip it. Today the profile forces one TERMS_ID on every dealer (PREPAY, DUR, 10TH and others are all in use). Confirm the defaulting in a spike. |
| warehouse | profile `MAIN` | WAREHOUSE_ID | dealer lines book on MAIN; PART_NOT_IN_WAREHOUSE needs part-warehouse data |
| tax | `taxable` is required on every line, and true applies the profile's single tax group (UTAH for web) whatever the ship-to state (`models.py:84`; `preview.py:86-87`; OQ-17) | SALES_TAX_GROUP_ID | **decide:** send taxable=false and let the customer/ship-to default apply (verify), or accept a per-request group from `dim_ship_to.default_sales_tax_group_id`. Needs Finance sign-off. |
| requested_ship_date | `desired_ship_date` | **[UNCONFIRMED column; needs a new VECA schema spike, not S-7]** | gateway change |
| customer_contact_key | `contact_id` | **[UNCONFIRMED]** | gateway change, plus an apply-order slot |
| ship_via / ship_complete / notes | none | **[UNCONFIRMED]**; neither the gateway nor the worker writes notes | until a writer exists, **any order with notes, ship_via or ship_complete=true goes to human entry, not auto-push** |
| user_id / rep | `requested_by` (journal only) | SALESREP_ID from the customer default | OK |
| lines part_id / qty / effective_unit_price | `part` lines (decimal strings) | PART_ID / USER_ORDER_QTY / UNIT_PRICE | maps. **Send the net UNIT_PRICE.** The gateway's order-level discount line (`preview.py:117-120`) would make `run_order_qc` report price_mismatch on every promo line, because QC compares net price against unit_price × (1 − trade_discount_pct) on non-service lines (`20261030120000_order_ship_to_ffl.sql:300-334`). TRADE_DISC_PERCENT would need the column confirmed plus a re-pricing spike. |
| FFL / requires_ffl | none; `allow_traced_parts=true` on the dealer profile | — | **blocks firearms:** 422 TRACED_PART today (`validation.py:177-185`); OQ-12 (`customer-orders.md:811`). The pusher must refuse any order whose FFL does not match CUST_ADDRESS USER_4/USER_5 in VECA. This is a hard precondition, not optional. |

**Gateway work list:**
- the `crm-portal` SourceRef variant, plus either a status route or reliance on `GET /v1/requests/{id}`;
- a `dealer-portal` profile with per-request customer, ship-to and contact, optional terms, warehouse MAIN, `order_id_mode=auto` (OQ-1) and `po_ref_format='CRM-{number}'`;
- the HEADER_APPLY_ORDER contract change;
- VECA validators for customer, ship-to, active status and credit hold;
- `allow_traced_parts` plus an FFL recheck;
- the tax decision;
- an API key with scope `customer-orders:create` bound to the profile (`auth.py:48-63`);
- merging commit 7317816 into the api-development branch.

Go-live gates for the push:
- V-8 (a non-production VECA) and V-9 (a VISUAL service user);
- OQ-1, OQ-12, OQ-14 (who works needs_attention), OQ-15 and OQ-17;
- spikes S-2 to S-4 (line placeholders, Save atomicity, error mapping; `customer-orders.md:649-661, 781-784, 800, 814`) and S-7.

**On-prem pusher, `etl/push_orders.py`.** It is scheduled with the `\CRM\` tasks. **[ASSUMED: the Supabase edge cannot reach the on-prem gateway.]** The gateway has no callbacks, so status is polled with `GET /v1/requests/{id}` (`api.py:233-252`). The pusher:
1. **Claims** each order atomically. It sets `erp_push_state='claimed'` only where `status='submitted' and erp_push_state is null` and the order is eligible:
   - **pilot on portal-typed orders first**, which a rep entered by hand;
   - `source='mcp'` orders also need an explicit order-entry "approve for push" step;
   - orders with notes, ship_via or ship_complete are excluded.
2. Dry-runs (`?dry_run=true`), then posts, then polls until the request reaches a terminal state.
3. Writes back through a new service-only RPC `record_erp_push(order_id, state, request_id, visual_order_id, error)`. It uses the same normalisation and duplicate rejection as `mark_order_entered`, then moves the order to `entered`, and QC verifies as it does today.
   - `EXISTING_ORDER_CANCELLED`, `MULTIPLE_VISUAL_ORDERS` and in_doubt for more than 10 minutes all map to `needs_attention`, which an admin or order entry resolves in the portal.

**Coexistence with manual entry:**
- An order with `erp_push_state` set to claimed, queued, in_progress or in_doubt is read-only in the queue.
- `mark_order_entered` refuses while a push is in flight.
- When order entry keys an order by hand, they type `CRM-<id>` as the PO ref so layer 3 still protects it.
- `cancel_order`, `recall` and `reopen` refuse once a push has been claimed.
- `reopen` keeps the VISUAL link, and push state is reset only after a terminal result from the gateway.

The separate `order_loader` (`20261030150000_ffl_rule_alignment.sql:11-14`) overlaps with this pusher, and its code is not on this machine.

---

## 6. Data gaps, ranked

**Blocks the Claude-drafts release (v1)**
1. The FFL and ship-to migrations are not live. Apply them and run the tests.
2. Prices exist only for DEALER and BUY_GROUP, and only for 403 firearm SKUs. v1 restricts to those types through `params.customer_types` and reports them in `blockers`. The real fix is for an admin to upload more lists, including parts and accessories.
3. Pilot identity: `my_customer_keys()` is empty for an admin with no rep key (section 2.4).

**Degrades v1 but does not block it**

4. FFL coverage is about 1,027 of 3,054 ship-tos. Many firearm drafts will need the rep to enter the FFL in the portal.
5. Stock covers SHIPPING only, and 227 of the 403 priced SKUs have no row. Show those as "no stock data" and never block on stock. In the next phase, add MAIN on-hand from `fact_inventory_on_hand`.
6. Credit: only the status is synced. HOLD and HOLDORD produce a blocker.
7. Latency: ship-tos and contacts load only in the twice-daily full run (`etl/views.yml:70-74`). Expose `data_as_of`.
8. `customer_type` is null on 1,955 customers that ordered recently. They show the `no_price_list_for_type` blocker.

**Blocks the ERP push**

9. Part-warehouse setup is not synced. Add `bi.vw_DimPartWarehouse` → `erp.dim_part_warehouse`, with a new `etl/views.yml` entry.
10. VECA terms, freight terms and ship via are not on `dim_customer`. Let VISUAL default them once the gateway change is done, or add them to `bi.vw_DimCustomer` (add-column migration, then a full push).
11. Tax group decision (section 5).
12. The dealer-PO column in VISUAL, and the writers for notes, ship via and contact, are all unconfirmed.

**Not blocking:** there is no orderable flag (use status A plus being priced); the firearm rule is a heuristic that fails safe.

---

## 7. Safety design

- **Three gates, all of which must pass:** `feature.orders`; `feature.mcp_orders` with its params (an empty allow-list means nobody); and the token scope. Each is checked in SQL through `mcp_orders_gate`, using the signed JWT claim, and again in the edge function.
- **Write scope only in a header.** If the token arrives in the URL, the write scope is dropped for that request (section 2.3). Write tokens last 90 days at most, one per user, with re-consent on ConnectView.
- **The server sets every price.** There are no price inputs, and the equality check in `submit_order` stays as the backstop.
- **No model-supplied FFL**, because a rep-entered FFL overrides the one on file (section 3.3). The ERP pusher refuses any FFL that does not match VECA.
- **The human approves on a channel the model cannot drive.** A confirm token returned in tool output (`order_id.content_hash`) is not human approval: Claude, or text injected from an email it read, could call create and then submit in the same turn. Annotations are only hints to the client. So Claude can create, update and cancel drafts, and **the rep submits in the portal**, where the order shows an MCP badge and its warnings. Order entry, or the pusher's approval step, is a second check. If Claude submitting is ever wanted, the confirm code must go only to the portal or to the rep's email or SMS, and the user types it back. It must never appear in a tool result.
- **Prompt injection.** The worst that injected text can do is create or change drafts on the rep's own book, within the caps and the daily limit. It cannot submit and cannot cancel a submitted order.
- **Duplicates:** the `(user_id, client_request_id)` key with request-hash conflict detection, plus a server-side duplicate **block** by PO or line set unless `allow_duplicate`, which Claude must confirm with the user.
- **Provenance and audit:** `orders.source`, `mcp_token_id` and `mcp_warnings`, plus `mcp_tool_calls` rows written from the edge function after each call. Because the log write happens outside the failed transaction, refusals are kept. Revoking a token stops it immediately, and its orders can be found by `mcp_token_id`.
- **Admins** are refused by default (section 2.4). A view-as session gets a clear error.
- **No rate limiting** exists (`index.ts:219, 283, 312`). The daily draft cap in SQL is the limiter for v1.
- **ERP push risk order:** pilot the automatic push on portal-typed orders. MCP orders need an explicit approval for push.

---

## 8. Testing plan

- **Deno unit tests**, following `supabase/functions/mcp/tools.test.ts:109-171` with a fake db:
  - `orderTools.test.ts`: argument validation; price and FFL fields are never forwarded; RPC errors map to ToolError; the audit call happens on both success and error.
  - A new **`index.test.ts`** for dispatch, which nothing tests today:
    - flag off: tools are hidden and calls get -32602;
    - flag on with no scope: hidden;
    - scope delivered by URL token: hidden;
    - scope delivered in a header with the flag on: listed with non-read-only annotations;
    - the INSTRUCTIONS ordering paragraph appears only when write tools are listed.
- **SQL guard tests:** a new `supabase/tests/20261115_mcp_orders.sql`, built on `034_mcp_access.sql` and `20261030_order_ship_to_ffl.sql:130-163`, setting `request.jwt.claims` with and without the MCP `app_metadata`. Cases:
  - each gate refuses on its own: feature.orders off, mcp_orders off, no scope, portal JWT, empty allow-list, admin token, and an admin with an empty book;
  - the old 3-argument `mcp_token_create` no longer exists, and `mcp_token_resolve` returns scopes;
  - another rep's customer is refused, and an unpriced part or a kit is refused;
  - a client price key or FFL key is refused or ignored;
  - the caps are enforced;
  - replay returns the same id, and a changed body raises `idempotency_conflict`;
  - the duplicate block works, and `allow_duplicate` overrides it;
  - the dry-run submit leaves the order as a draft and reports ffl_required and ship_to errors;
  - update and cancel are refused on a submitted order and on a portal-sourced order;
  - view-as returns a clean error;
  - an inactive ship-to is marked not orderable in `order_context`.

  Run these with psycopg (no psql and no e2e credentials on this machine), and run a `vue-tsc` build. Say plainly that the authenticated UI was not checked in a browser.
- **Manual pilot:** in Claude Desktop with a header token, find a dealer, look up products, draft, fix the draft with update, open it in the portal, submit, and see it in the order-entry queue.
- **ERP push:** gateway pytest for the `crm-portal` source, the dealer profile, the new apply order and the optional terms. Then the pusher in shadow and dry-run mode against V-8, plus SQL tests that claimed orders refuse cancel, recall and `mark_order_entered`.

---

## 9. Phased rollout

- **Phase 0, prerequisites (about 1-2 days):**
  - Apply the three FFL migrations.
  - Decide the pilot identity (section 2.4).
  - Decide that write tokens are header-only.
  - Confirm the price-list coverage.
- **v1, Claude drafts (about 1-1.5 weeks):**
  - Migrations 1-5.
  - Tools: `get_order_context`, `search_order_products`, `create_order_draft`, `update_order_draft`, `cancel_order_draft` (drafts only), `get_order_status` and `list_my_order_drafts`.
  - `whoami` capabilities, the ConnectView scope checkbox, the FeatureFlagsCard label and params editor, the MCP badge with warnings, and the new header fields in the writer.
  - The rep always submits in the portal, and order entry keys the order as today.
  - Pilot with `mcp_order_users` = [pilot rep], DEALER and BUY_GROUP only.
- **v1.1, after 2-4 weeks of clean drafts:**
  - Widen to selected reps.
  - Add MAIN on-hand stock.
  - Add a warning for duplicates against ERP open orders.
  - Upload more price lists as Tyler supplies them.
- **v2, automatic push to VISUAL:** after the gateway gates in section 5 are met (V-8/V-9, OQ-1/12/14/15/17, S-2 to S-4 and S-7, the dealer profile, the apply-order contract, optional terms, tax, the PO marker and part-warehouse sync).
  - Run `etl/push_orders.py` in shadow mode, then dry-run, then live, **first for portal-typed orders**, then for MCP orders that have order-entry approval.
  - Orders with notes or shipping instructions stay with human entry until writers exist.
  - Order entry then becomes the exception handler for `needs_attention`.

---

## 10. Open questions for Tyler

1. **Pilot identity.** Your profile is an admin, and `my_customer_keys()` has no admin branch, so every draft would be refused. Should the pilot use a real rep account (or grants to specific dealers for you), or should admin tokens be allowed to draft for any account?
2. **Header-only write tokens.** Are you happy for order drafting to work only from Claude Desktop and Code (header token), and not from claude.ai URL connectors, until OAuth is supported?
3. **Submit stays in the portal.** Do you agree that Claude never submits, so the rep always clicks Submit? If not, which out-of-band confirmation would you accept: a code shown in the portal, or one sent by email or SMS?
4. **Who gets write tokens** after the pilot: add selected reps to `mcp_order_users` one by one in the admin card, or add a bulk "add all active reps" admin action to that card?
5. **Dealer PO.** CUSTOMER_PO_REF should be `CRM-<id>` so VISUAL's dedupe is safe. Which VISUAL column should hold the dealer's own PO?
6. **ERP path.** Is the separate `order_loader` (`order_loader/app/ffl.py`) or visual-api the intended route for portal orders into VISUAL, and where does the loader's code live?
7. **Pricing gaps.** For MSTR_DLR, DISTRIBUTOR, untyped customers and accessories or parts: block them in v1, or will you upload lists?
8. **Terms and tax on dealer orders.** Should VISUAL default terms from the customer (this needs a gateway change)? Should part lines be non-taxable with the customer or ship-to tax default (needs Finance sign-off)?
9. **Warehouse.** Is it always MAIN for dealer orders? Should the stock Claude shows be SHIPPING ATS (today's model) or MAIN on-hand?
10. **Caps.** What limits fit for lines, units per line, order value, drafts per day and the duplicate window? Should going over a cap block the order or flag it for review?
11. **Shipping instructions.** Are ship via, ship complete or partial, and a contact enough, or are there other dealer instructions (drop-ship, hold for complete, requested carrier account) Claude must capture?
12. **ERP push approval.** Should MCP orders always need an order-entry "approve for push" step, even after the automatic push is live for portal-typed orders?
