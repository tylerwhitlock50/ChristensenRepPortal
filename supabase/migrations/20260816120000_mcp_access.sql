/*============================================================================
  20260816120000_mcp_access.sql

  Purpose: Long-lived, revocable credentials so a rep can point Claude (or any
           MCP client) at the portal's data — WITHOUT moving the security
           boundary out of Postgres.

  The shape
  ---------
  `public.mcp_tokens` stores a SHA-256 of an opaque token. The plaintext is
  returned exactly once, by `mcp_token_create()`, and never stored. The
  `mcp` Edge Function resolves an incoming token to a user_id with
  `mcp_token_resolve()` (service_role only), then mints a 5-minute
  `authenticated` JWT for that user and does every read as them.

  Why that matters, and why this file is small
  --------------------------------------------
  The alternative — an Edge Function that reads with service_role and filters
  by the rep's book in TypeScript — is the exact failure the 010 header and
  the _shared/supabase.ts header argue against: a SECOND implementation of
  the access rules, in a language with no RLS, that drifts silently. Nothing
  here re-states who can see what. `my_customer_keys()` is still the only
  answer, and an MCP client sees precisely what the same rep sees in the SPA,
  because it IS the same rep hitting the same policies.

  A token is therefore not a new grant. It is a second way to present an
  identity the portal already knows, and it can be taken back on its own
  without touching the account it belongs to.

  Secrecy of the hash
  -------------------
  RLS lets a rep read their OWN token rows (they need the list to manage it),
  which would hand them `token_hash` for free. That is not a live credential,
  but it is a verifier for one, and there is no reason to serve it. The grant
  below is therefore COLUMN-LEVEL: `authenticated` can select every column
  except `token_hash`, so PostgREST cannot return it under any policy. A
  `select=*` against this table fails rather than leaking — the frontend
  names its columns.

  service_role and the one exception
  ----------------------------------
  `mcp_token_resolve()` is the only function here the app roles cannot call.
  It takes a plaintext token and answers "whose is this?", so it is granted to
  service_role alone — the same narrow posture `ai-summary-batch` takes with
  `x-batch-secret` (functions/README.md). The Edge Function uses service_role
  for that ONE call and for nothing else; the moment it knows who the caller
  is, it drops to a user-scoped client. Widening this function's grants, or
  reusing that service client to read sales data, would undo the whole design
  above.
============================================================================*/

--------------------------------------------------------------------------
-- mcp_tokens
--
-- expires_at is NOT NULL on purpose: a credential that lives in a
-- third-party client's settings forever is a credential nobody remembers to
-- revoke. mcp_token_create() clamps the lifetime to two years.
--------------------------------------------------------------------------
create table if not exists public.mcp_tokens (
    id            uuid primary key default pg_catalog.gen_random_uuid(),
    user_id       uuid not null references public.profiles (user_id) on delete cascade,
    name          text not null,
    -- First 12 chars of the plaintext ("crp_" + 8 hex). Enough for a human to
    -- tell two tokens apart in the UI; useless as a credential.
    token_prefix  text not null,
    token_hash    text not null unique,
    created_at    timestamptz not null default now(),
    created_by    uuid references public.profiles (user_id),
    expires_at    timestamptz not null,
    last_used_at  timestamptz,
    revoked_at    timestamptz,
    revoked_by    uuid references public.profiles (user_id)
);

alter table public.mcp_tokens enable row level security;

-- The management read ("my tokens, newest first").
create index if not exists idx_mcp_tokens_user
  on public.mcp_tokens (user_id, created_at desc);

-- The hot path is the unique index on token_hash; this partial index only
-- serves the active-count guard in mcp_token_create().
create index if not exists idx_mcp_tokens_live
  on public.mcp_tokens (user_id)
  where revoked_at is null;

comment on table public.mcp_tokens is
  'Bearer credentials for the mcp Edge Function. Stores a SHA-256 only — the '
  'plaintext is returned once by mcp_token_create() and never again. A token '
  'confers NO access of its own: it identifies a user, and that user''s '
  'existing RLS decides everything (see the file header).';

--------------------------------------------------------------------------
-- Policies. A rep manages their own tokens; an admin sees and revokes any.
-- No UPDATE or DELETE policy for anyone: revocation goes through
-- mcp_token_revoke() so revoked_at/revoked_by are always stamped together,
-- and rows are kept as an audit trail rather than deleted.
--------------------------------------------------------------------------
drop policy if exists "read own mcp tokens" on public.mcp_tokens;
create policy "read own mcp tokens" on public.mcp_tokens
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_admin()));

--------------------------------------------------------------------------
-- Grants. Column-level SELECT so token_hash is unreachable over PostgREST
-- (see header). No INSERT/UPDATE/DELETE — the functions below own writes.
--------------------------------------------------------------------------
revoke all on public.mcp_tokens from anon, public, authenticated;
grant select (
  id, user_id, name, token_prefix, created_at, created_by,
  expires_at, last_used_at, revoked_at, revoked_by
) on public.mcp_tokens to authenticated;

--------------------------------------------------------------------------
-- mcp_token_create — mint one, return the plaintext ONCE.
--
-- Randomness is two gen_random_uuid()s rather than pgcrypto's
-- gen_random_bytes(): ~244 bits from a CSPRNG, with no extension to install
-- or schema-qualify. sha256() is core Postgres (11+), so nothing here needs
-- `extensions` on the search_path.
--------------------------------------------------------------------------
create or replace function public.mcp_token_create(
    p_name    text default 'Claude',
    p_user_id uuid default null,
    p_days    int  default 365
)
returns table (
    token_id   uuid,
    token      text,
    token_name text,
    expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_caller  uuid := auth.uid();
    v_target  uuid;
    v_token   text;
    v_name    text;
    v_days    int;
    v_live    int;
    v_id      uuid;
    v_expires timestamptz;
begin
    if v_caller is null then
        raise exception 'not signed in' using errcode = '42501';
    end if;

    v_target := coalesce(p_user_id, v_caller);

    -- Minting FOR SOMEONE ELSE is an admin act. Minting for yourself is not:
    -- the token can only ever reach what you can already reach in the SPA.
    if v_target <> v_caller and not public.is_admin() then
        raise exception 'only an admin can create a token for another user'
          using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.profiles p
        where p.user_id = v_target and p.active
    ) then
        raise exception 'no active profile for that user' using errcode = '23503';
    end if;

    v_name := nullif(pg_catalog.btrim(coalesce(p_name, '')), '');
    if v_name is null then
        v_name := 'Claude';
    end if;
    v_name := pg_catalog.left(v_name, 60);

    -- GREATEST/LEAST are SQL constructs, not functions — they cannot be
    -- schema-qualified, and pinning search_path to '' does not hide them.
    v_days := greatest(1, least(coalesce(p_days, 365), 730));

    -- A cap, not a policy: five live tokens is more clients than anyone has,
    -- and an unbounded list is how a stale credential hides.
    select pg_catalog.count(*) into v_live
    from public.mcp_tokens t
    where t.user_id = v_target
      and t.revoked_at is null
      and t.expires_at > pg_catalog.now();

    if v_live >= 5 then
        raise exception 'that user already has 5 active tokens — revoke one first';
    end if;

    v_token := 'crp_'
      || pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '')
      || pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '');

    insert into public.mcp_tokens (
        user_id, name, token_prefix, token_hash,
        created_by, expires_at
    )
    values (
        v_target,
        v_name,
        pg_catalog.left(v_token, 12),
        pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(v_token, 'UTF8')), 'hex'),
        v_caller,
        pg_catalog.now() + pg_catalog.make_interval(days => v_days)
    )
    returning mcp_tokens.id, mcp_tokens.expires_at
    into v_id, v_expires;

    token_id   := v_id;
    token      := v_token;
    token_name := v_name;
    expires_at := v_expires;
    return next;
end;
$$;

comment on function public.mcp_token_create(text, uuid, int) is
  'Mints an MCP token and returns the plaintext ONCE — it is stored hashed '
  'and cannot be recovered. Self-service for the caller; p_user_id requires '
  'is_admin(). Lifetime clamped to 1-730 days, five live tokens per user.';

--------------------------------------------------------------------------
-- mcp_token_revoke — idempotent; returns true only for the call that
-- actually flipped the row, so the UI can tell "revoked" from "already was".
--------------------------------------------------------------------------
create or replace function public.mcp_token_revoke(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_caller uuid := auth.uid();
    v_owner  uuid;
    v_hit    int;
begin
    if v_caller is null then
        raise exception 'not signed in' using errcode = '42501';
    end if;

    select t.user_id into v_owner from public.mcp_tokens t where t.id = p_id;
    if v_owner is null then
        raise exception 'no such token' using errcode = 'P0002';
    end if;

    if v_owner <> v_caller and not public.is_admin() then
        raise exception 'not your token' using errcode = '42501';
    end if;

    update public.mcp_tokens t
       set revoked_at = pg_catalog.now(),
           revoked_by = v_caller
     where t.id = p_id
       and t.revoked_at is null;

    get diagnostics v_hit = row_count;
    return v_hit > 0;
end;
$$;

comment on function public.mcp_token_revoke(uuid) is
  'Revokes one MCP token. Own tokens, or any token for an admin. Idempotent: '
  'returns false if it was already revoked. The row is kept as audit history.';

--------------------------------------------------------------------------
-- mcp_token_resolve — the Edge Function''s ONLY service_role call.
--
-- Answers "whose token is this, and is it still good?" and nothing else. It
-- deliberately returns no account data: the caller''s next move is to mint a
-- JWT for this user and read as them.
--
-- last_used_at is stamped at most once every five minutes. A write per MCP
-- request would turn a read-only endpoint into a write endpoint and put a
-- row update in front of every tool call for a field nobody reads to the
-- minute.
--------------------------------------------------------------------------
create or replace function public.mcp_token_resolve(p_token text)
returns table (
    token_id            uuid,
    user_id             uuid,
    full_name           text,
    user_role           text,
    sales_rep_key       text,
    rep_group_vendor_id text,
    expires_at          timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_hash text;
    v_row  record;
begin
    if p_token is null or pg_catalog.length(p_token) < 20 then
        return;
    end if;

    v_hash := pg_catalog.encode(
        pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8')), 'hex');

    -- An inactive profile must not be reachable by token. This is the hole
    -- 010's closing note describes for account_assignments, closed here at
    -- the door rather than left for the policies: deactivating a user has to
    -- kill their MCP clients too, and unlike a browser JWT this credential
    -- does not expire on its own within the hour.
    --
    -- Every name is table-qualified: the OUT columns of a RETURNS TABLE are
    -- plpgsql variables, so a bare `user_id` here would be ambiguous.
    select t.id            as f_token_id,
           t.user_id       as f_user_id,
           p.full_name     as f_full_name,
           p.role          as f_role,
           p.sales_rep_key as f_rep_key,
           p.rep_group_vendor_id as f_vendor_id,
           t.expires_at    as f_expires
      into v_row
      from public.mcp_tokens t
      join public.profiles p on p.user_id = t.user_id
     where t.token_hash = v_hash
       and t.revoked_at is null
       and t.expires_at > pg_catalog.now()
       and p.active;

    if not found then
        return;
    end if;

    update public.mcp_tokens t
       set last_used_at = pg_catalog.now()
     where t.id = v_row.f_token_id
       and (t.last_used_at is null
            or t.last_used_at < pg_catalog.now() - pg_catalog.make_interval(mins => 5));

    token_id            := v_row.f_token_id;
    user_id             := v_row.f_user_id;
    full_name           := v_row.f_full_name;
    user_role           := v_row.f_role;
    sales_rep_key       := v_row.f_rep_key;
    rep_group_vendor_id := v_row.f_vendor_id;
    expires_at          := v_row.f_expires;
    return next;
end;
$$;

comment on function public.mcp_token_resolve(text) is
  'Resolves a plaintext MCP token to its user. service_role ONLY — it is the '
  'mcp Edge Function''s single privileged call, made before any data is '
  'read. Returns no account data by design. Rejects revoked, expired, and '
  'deactivated-profile tokens.';

--------------------------------------------------------------------------
-- Grants, per 017: definer functions are reachable only by the role that
-- needs them.
--------------------------------------------------------------------------
revoke execute on function public.mcp_token_create(text, uuid, int) from public, anon;
revoke execute on function public.mcp_token_revoke(uuid)            from public, anon;
revoke execute on function public.mcp_token_resolve(text)           from public, anon, authenticated;

grant execute on function public.mcp_token_create(text, uuid, int) to authenticated;
grant execute on function public.mcp_token_revoke(uuid)            to authenticated;
grant execute on function public.mcp_token_resolve(text)           to service_role;

/*----------------------------------------------------------------------------
  Post-migration checklist
  1. Deploy the function:  supabase functions deploy mcp --no-verify-jwt
     (--no-verify-jwt for the same reason as every other function here: the
     gateway's check would reject a token that is not a Supabase JWT, and the
     function authenticates the caller itself before touching any data.)
  2. Set the one secret the function needs:
       supabase secrets set MCP_JWT_SECRET=<Dashboard → Settings → API → JWT Secret>
     See supabase/functions/mcp/README.md for why, and for what to do if this
     project has retired its legacy HS256 secret.
  3. Run supabase/tests/034_mcp_access.sql against dev.
  4. Nothing to schedule and nothing to backfill — no token exists until a
     rep asks for one on /connect.
----------------------------------------------------------------------------*/
