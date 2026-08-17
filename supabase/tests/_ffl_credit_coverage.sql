/*============================================================================
  _ffl_credit_coverage.sql — a QUESTION, not a test.

      psql "$DATABASE_URL" -f supabase/tests/_ffl_credit_coverage.sql

  Read-only. Leading underscore because it asserts nothing; it reports how
  much of the compliance data actually exists so a decision can be made with
  numbers instead of hope.

  ── Why this file exists ───────────────────────────────────────────────────
  "Landed" is not "maintained". The commission columns are the proof: fully
  populated in the schema, and not accurate, because accounting never
  maintained them. This codebase has been bitten once before too —
  015_account_last_order_date.sql exists solely because
  dim_customer.last_order_date is "the ERP's unmaintained field, NULL for
  most accounts", and AccountView.vue still carries the workaround.

  ffl_expiration_raw comes from CUSTOMER.USER_5 — a free-form user-defined
  field, which is the classic home for stale data — so it deserves the same
  suspicion before anything is built on top of it.

  ── The decision this answers ──────────────────────────────────────────────
  The account-page strip (components/AccountShipReadiness.vue) is already
  safe under any result: it renders NOTHING when a field is blank or
  unparseable, so sparse data makes it quiet rather than wrong.

  What is gated on these numbers is the TERRITORY-WIDE "FFLs expiring in the
  next 60 days" watchlist, which is deliberately NOT built yet.

      Build the watchlist  ONLY IF expiry_parses_as_date is a clear majority
                           of accounts_with_any_ffl.

  A watchlist over sparse data reads as "everyone not listed is fine", which
  is worse than having no watchlist at all — it converts missing data into a
  false all-clear on a compliance question.

  The same test governs whether credit_limit_amount is worth promoting beyond
  the account page.
============================================================================*/

\echo ''
\echo '=== FFL coverage across ACTIVE accounts ==='

select
    count(*)                                             as active_accounts,
    count(nullif(btrim(ffl_license_number), ''))         as have_license_number,
    count(nullif(btrim(ffl_expiration_raw), ''))         as have_expiry_string,
    count(*) filter (
        where nullif(btrim(ffl_license_number), '') is not null
           or nullif(btrim(ffl_expiration_raw), '') is not null
    )                                                    as have_any_ffl,
    -- Rough proxy for "the UI's parser will accept this": contains something
    -- shaped like a date. lib/ffl.ts is stricter (it also rejects implausible
    -- years), so treat this as an UPPER BOUND on what will actually parse.
    count(*) filter (
        where ffl_expiration_raw ~ '\d{1,4}[/-]\d{1,2}[/-]\d{2,4}'
    )                                                    as expiry_parses_as_date,
    count(*) filter (
        where nullif(btrim(ffl_expiration_raw), '') is not null
          and ffl_expiration_raw !~ '\d{1,4}[/-]\d{1,2}[/-]\d{2,4}'
    )                                                    as expiry_present_but_unparseable
from erp.dim_customer
where active_flag = 'Y';

\echo ''
\echo '=== What the unparseable values actually look like (top 15) ==='
\echo '--- if these are all one weird-but-consistent format, extend FORMATS'
\echo '--- in frontend/src/lib/ffl.ts rather than writing them off.'

select btrim(ffl_expiration_raw) as raw_value, count(*) as accounts
from erp.dim_customer
where active_flag = 'Y'
  and nullif(btrim(ffl_expiration_raw), '') is not null
  and ffl_expiration_raw !~ '\d{1,4}[/-]\d{1,2}[/-]\d{2,4}'
group by 1
order by 2 desc, 1
limit 15;

\echo ''
\echo '=== Credit coverage across ACTIVE accounts ==='

select
    count(*)                                    as active_accounts,
    count(nullif(btrim(credit_status), ''))     as have_credit_status,
    count(credit_limit_amount)                  as have_credit_limit,
    count(*) filter (where credit_limit_amount > 0) as have_nonzero_limit,
    count(nullif(btrim(ar_terms_rule_id), ''))  as have_terms
from erp.dim_customer
where active_flag = 'Y';

\echo ''
\echo '=== Which credit_status values exist, and would we flag them? ==='
\echo '--- lib/ffl.ts isCreditBlocked() matches: hold|block|suspend|stop|'
\echo '--- revoke|inactive|delinquent. Anything blocking in this list that'
\echo '--- the pattern misses is a miss worth fixing.'

select
    coalesce(nullif(btrim(credit_status), ''), '(blank)') as credit_status,
    count(*) as accounts,
    btrim(credit_status) ~* 'hold|block|suspend|stop|revoke|inactive|delinquent'
        as would_be_flagged
from erp.dim_customer
where active_flag = 'Y'
group by 1, 3
order by 2 desc;

\echo ''
\echo '=== Ship-to FFLs ==='
\echo '--- bi.vw_DimCustomer says the SHIP-TO value is authoritative. If this'
\echo '--- is well populated and diverges from the customer-level field, the'
\echo '--- strip should prefer it (it currently reads customer-level only).'

select
    count(*)                                       as active_ship_tos,
    count(nullif(btrim(ffl_license_number), ''))   as have_license_number,
    count(nullif(btrim(ffl_expiration_raw), ''))   as have_expiry_string
from erp.dim_ship_to
where active_flag = 'Y';
