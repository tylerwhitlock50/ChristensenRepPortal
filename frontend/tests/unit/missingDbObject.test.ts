/**
 * Unit tests for isMissingDbObject in lib/supabase.ts.
 *
 * Run with:  npm run test:unit
 *
 * Same harness as ffl.test.ts: no framework, vite-node, non-zero exit on
 * failure. lib/supabase.ts builds the client at import, so this needs the
 * placeholder env that tests/unit/run.mjs sets.
 *
 * What matters: a preview running against a database without tonight's
 * migrations must read as "not there yet" (hide the feature), while every
 * real failure — RLS, timeout, network, an unexposed schema — must NOT, or a
 * broken feature would vanish silently instead of showing its error card.
 */
import { isMissingDbObject } from '../../src/lib/supabase'

let pass = 0
let fail = 0

function t(label: string, got: unknown, want: unknown) {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (ok) {
    pass++
    console.log(`ok   ${label}`)
  } else {
    fail++
    console.log(
      `FAIL ${label}  got=${JSON.stringify(got)} want=${JSON.stringify(want)}`,
    )
  }
}

/* --- PostgREST schema-cache codes --------------------------------------- */
t(
  'PGRST202 function not found',
  isMissingDbObject({
    code: 'PGRST202',
    message:
      'Could not find the function public.report_reorder_candidates(p_customer_key, p_limit) in the schema cache',
  }),
  true,
)
t(
  'PGRST205 table not found',
  isMissingDbObject({
    code: 'PGRST205',
    message: "Could not find the table 'public.v_new_thing' in the schema cache",
  }),
  true,
)
t(
  'PGRST204 column not found',
  isMissingDbObject({
    code: 'PGRST204',
    message: "Could not find the 'display_name' column of 'contacts' in the schema cache",
  }),
  true,
)

/* --- Postgres codes passed through -------------------------------------- */
t('42883 undefined function', isMissingDbObject({ code: '42883', message: 'x' }), true)
t(
  '42883 from a helper the new function calls',
  isMissingDbObject({ code: '42883', message: 'function public.helper(text) does not exist' }),
  true,
)
t(
  '42883 "operator does not exist" is a bug in a function that exists',
  isMissingDbObject({ code: '42883', message: 'operator does not exist: text = integer' }),
  false,
)
t('42P01 undefined table', isMissingDbObject({ code: '42P01', message: 'x' }), true)
t(
  '42703 undefined column (select of a new view column)',
  isMissingDbObject({
    code: '42703',
    message: 'column v_account_contacts.display_name does not exist',
  }),
  true,
)

/* --- message only (code stripped by a proxy) ---------------------------- */
t(
  'message: schema-cache function',
  isMissingDbObject({
    message: 'Could not find the function public.f(p_x) in the schema cache',
  }),
  true,
)
t(
  'message: relation does not exist',
  isMissingDbObject({ message: 'relation "public.v_new_thing" does not exist' }),
  true,
)
t(
  'message: function does not exist',
  isMissingDbObject({
    message: 'function public.f(text, integer) does not exist',
  }),
  true,
)

/* --- real failures stay failures ---------------------------------------- */
t('null', isMissingDbObject(null), false)
t('undefined', isMissingDbObject(undefined), false)
t(
  'RLS / grant',
  isMissingDbObject({ code: '42501', message: 'permission denied for function f' }),
  false,
)
t(
  'statement timeout',
  isMissingDbObject({
    code: '57014',
    message: 'canceling statement due to statement timeout',
  }),
  false,
)
t('network', isMissingDbObject({ message: 'Failed to fetch' }), false)
t(
  'erp schema not exposed is a config problem, not a missing object',
  isMissingDbObject({
    code: 'PGRST106',
    message: 'The schema must be one of the following: public',
  }),
  false,
)
t(
  'missing schema is not a missing object',
  isMissingDbObject({ code: '3F000', message: 'schema "erp" does not exist' }),
  false,
)
t(
  'JWT expired',
  isMissingDbObject({ code: 'PGRST301', message: 'JWT expired' }),
  false,
)

console.log(`\n${pass} passed, ${fail} failed`)
if (fail > 0) process.exit(1)
