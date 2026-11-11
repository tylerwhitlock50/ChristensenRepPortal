-- MCP order drafting: any valid MCP token, for an allowed user (2026-11-11).
--
-- Decision (Tyler): Claude.ai connectors can only carry the token in the URL,
-- so the orders:draft scope (header-only in v1) could never reach the gate
-- from a connector. From now on being on public.mcp_order_users (plus
-- feature.mcp_orders on, plus an active account) is the only thing needed to
-- draft orders over MCP - with ANY live MCP token of that user, read-only
-- tokens and URL-delivered tokens included. OAuth (v1.2) will bring back
-- per-connection consent.
--
-- Tradeoff: a leaked connector URL can create/update/cancel DRAFTS as that
-- user (never submit - the mcp_* RPCs have no submit path and the
-- protected_status guard is unchanged) until the token is revoked on the
-- Connect page.
--
-- Only mcp_orders_gate() changes: both scope checks (JWT claim and token
-- row) are dropped and mcp_scope_missing is no longer raised. Every other
-- check and its order is kept. Body = the live pg_get_functiondef
-- (2026-11-11) minus the scope blocks. CREATE OR REPLACE keeps the existing
-- ACL (postgres, authenticated, service_role EXECUTE; no PUBLIC/anon).
--
-- Left alone on purpose: mcp_tokens.scopes, its CHECK, mcp_token_create's
-- p_scopes (harmless; future OAuth), and every mcp_* RPC.

create or replace function public.mcp_orders_gate()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_app    jsonb := coalesce(auth.jwt() -> 'app_metadata', '{}'::jsonb);
  v_set    record;
  v_tok    text;
begin
  select s.enabled, s.params into v_set
  from public.app_settings s where s.setting_key = 'feature.mcp_orders';
  if not found then
    raise exception 'mcp_orders_disabled: drafting orders over MCP is turned off';
  end if;
  if not coalesce(v_set.enabled, false) then
    raise exception 'mcp_orders_disabled: drafting orders over MCP is turned off';
  end if;

  if v_uid is null or v_app ->> 'provider' is distinct from 'mcp' then
    raise exception 'not_mcp_session: order drafting is only available to an MCP client';
  end if;

  -- The claim is signed by the edge function; the token row is the truth.
  -- A token revoked in the last five minutes (JWT lifetime) stops here.
  v_tok := v_app ->> 'mcp_token_id';
  if v_tok is null or v_tok !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'not_mcp_session: the session carries no MCP token';
  end if;
  perform 1
  from public.mcp_tokens t
  where t.id = v_tok::uuid
    and t.user_id = v_uid
    and t.revoked_at is null
    and t.expires_at > now();
  if not found then
    raise exception 'not_mcp_session: the MCP token is revoked, expired or not yours';
  end if;

  -- Active first: mcp_orders_user_allowed() is false for an inactive
  -- profile too, and the clearer reason should win.
  if not exists (select 1 from public.profiles p where p.user_id = v_uid and p.active) then
    raise exception 'account_inactive: your account has been deactivated';
  end if;

  if not public.mcp_orders_user_allowed(v_uid) then
    raise exception 'mcp_user_not_allowed: your account is not enabled for drafting orders over MCP';
  end if;

  return v_set.params;
end;
$$;

comment on function public.mcp_orders_gate() is
  'Every mcp_* write RPC calls this first. Any live MCP token of an allowed, '
  'active user passes (token scopes are not checked since 2026-11-11). Raises '
  'mcp_orders_disabled, not_mcp_session, account_inactive or '
  'mcp_user_not_allowed (message ''code: text''); returns feature.mcp_orders params.';

comment on column public.mcp_tokens.scopes is
  'Reserved for future OAuth consent. Not consulted by mcp_orders_gate() since '
  '2026-11-11: any live token of a user on mcp_order_users can draft orders '
  '(never submit) while feature.mcp_orders is on.';
