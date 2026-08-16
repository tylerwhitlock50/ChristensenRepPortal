/*============================================================================
  034_contact_compliance_flags.sql
  Purpose: Carry the ERP's do-not-contact flags through to the CRM read.

  Why
  ---
  erp.dim_customer_contact has landed do_not_call_phone_flag,
  do_not_call_mobile_flag and do_not_email_flag since 032. v_account_contacts
  projects 5 of that table's 38 columns and drops all three, so ContactsCard
  renders a live tel: link on a contact the ERP has explicitly marked as
  do-not-call. The rep taps it, and neither they nor the app ever knew.

  Getting the phone flag RIGHT
  ----------------------------
  The view's `phone` column is coalesce(phone, mobile) — it shows whichever
  number exists, preferring the landline. So the flag that applies is the
  flag belonging to THE NUMBER ACTUALLY SHOWN, not a blanket OR of both. A
  contact who may be called at their desk but not on their cell must not be
  flagged when the desk number is the one on screen, and must be flagged when
  the cell is. Anything looser is either a false warning (reps stop believing
  the badge) or a missed one (the thing this migration exists to prevent).

  The rep-entered arm
  -------------------
  public.contacts has no such columns and gets `false`. A rep typed those in
  themselves; there is no ERP instruction attached to them. `false` rather
  than NULL so the UI never has to distinguish "allowed" from "unknown" for
  rows where the question does not arise.

  create-or-replace rules (same as 032): column positions are fixed, so the
  three new columns go LAST and nothing above them moves.
============================================================================*/

create or replace view public.v_account_contacts
with (security_invoker = true)
as
select
    'rep-' || c.id::text  as contact_key,
    'rep'::text           as source,
    c.id,
    c.customer_key,
    c.name,
    c.title,
    c.phone,
    c.email,
    c.is_primary,
    c.notes,
    c.updated_at,
    -- Rep-entered: no ERP instruction attached. See header.
    false                 as do_not_call,
    false                 as do_not_email
from public.contacts c
union all
select
    'erp-' || e.customer_contact_key,
    'erp',
    null::bigint,
    e.customer_key,
    coalesce(e.contact_name, e.contact_id),
    nullif(e.position, ''),
    coalesce(nullif(e.phone, ''), nullif(e.mobile, '')),
    nullif(e.email, ''),
    e.primary_contact_flag = 'Y',
    null::text,
    null::timestamptz,
    -- The flag for the number the row actually exposes, mirroring the
    -- coalesce above. Landline present → the landline's flag governs;
    -- otherwise the mobile's. No number at all → nothing to forbid.
    case
        when nullif(e.phone, '')  is not null then e.do_not_call_phone_flag  = 'Y'
        when nullif(e.mobile, '') is not null then e.do_not_call_mobile_flag = 'Y'
        else false
    end,
    coalesce(e.do_not_email_flag = 'Y', false)
from erp.dim_customer_contact e
-- Source keeps inactive assignments; the CRM shows active people only.
where e.contact_active_flag = 'Y';

comment on view public.v_account_contacts is
  'Merged contacts for one account: rep-entered rows (source=rep, editable, '
  'id set) plus active ERP contacts (source=erp, read-only). Always query '
  'with .eq(customer_key). security_invoker — RLS of both source tables '
  'applies. do_not_call/do_not_email carry the ERP contact-preference flags; '
  'do_not_call describes the number in THIS row''s phone column (landline '
  'when present, else mobile), not the contact in general.';

revoke all on public.v_account_contacts from anon, public;
grant select on public.v_account_contacts to authenticated;
