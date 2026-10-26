/*============================================================================
  20261013170000_unmapped_reps.sql — the ERP reps who have no portal account
  yet, for the admin's "create their account" button.

  Why
  ---
  Rollout is one rep at a time, and every one of them starts on the admin
  Users page: type the email, invent a password, type the name, type the rep
  code. All four are already in erp.dim_sales_rep. The admin should see the
  reps who are not mapped to a profile, with the email the ERP has for them,
  and create the account from that row.

  The list cannot be a plain query from the SPA: sales_rep_email is one of
  the contact columns that 20260901190300 column-revoked from authenticated,
  and that revoke is right — a rep has no business reading other reps'
  addresses. So this is a security definer function that returns rows only
  to a real admin and nothing at all to anyone else.

  What
  ----
  public.admin_unmapped_reps() — one row per erp.dim_sales_rep whose
  sales_rep_key is on no profile. Alongside the ERP fields it carries:

    customer_count         how many dim_customer rows the ERP assigns to the
                           rep today, so the admin can see who matters
    is_placeholder         the ETL's flags OR placeholder_rep_keys() — not a
                           person; admin-create-user would refuse the key
    email_profile_user_id  an existing profile already carries this email —
    email_profile_name     creating would 409; map the code on that user

  The email is lower-cased and trimmed, which is how admin-create-user
  stores it and how profiles.email compares.

  Read-only; no table changes; nothing for the view-as trigger sweep.
============================================================================*/

create or replace function public.admin_unmapped_reps()
returns table (
  sales_rep_key          text,
  sales_rep_name         text,
  sales_rep_email        text,
  vendor_id              text,
  sales_rep_type         text,
  customer_count         bigint,
  is_placeholder         boolean,
  email_profile_user_id  uuid,
  email_profile_name     text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.sales_rep_key,
    r.sales_rep_name,
    nullif(lower(trim(r.sales_rep_email)), '')                as sales_rep_email,
    r.vendor_id,
    r.sales_rep_type,
    (select count(*)
       from erp.dim_customer c
      where c.assigned_sales_rep_id = r.sales_rep_key)         as customer_count,
    (coalesce(r.is_placeholder_rep, false)
      or coalesce(r.is_unknown_sales_rep, false)
      or r.sales_rep_key = any (public.placeholder_rep_keys())) as is_placeholder,
    p.user_id                                                   as email_profile_user_id,
    p.full_name                                                 as email_profile_name
  from erp.dim_sales_rep r
  left join lateral (
    select p.user_id, p.full_name
      from public.profiles p
     where nullif(lower(trim(r.sales_rep_email)), '') is not null
       and lower(p.email) = lower(trim(r.sales_rep_email))
     order by p.created_at, p.user_id
     limit 1
  ) p on true
  where public.is_real_admin()
    and not exists (
      select 1 from public.profiles m
       where m.sales_rep_key = r.sales_rep_key
    )
  order by customer_count desc, r.sales_rep_name, r.sales_rep_key;
$$;

comment on function public.admin_unmapped_reps() is
  'ERP reps with no profile carrying their sales_rep_key, with the ERP email '
  'so an admin can create the account from the row. Returns nothing unless '
  'the credential-holder is an active admin (is_real_admin — view-as does '
  'not matter here). Security definer because sales_rep_email is '
  'column-revoked from authenticated (20260901190300).';

revoke execute on function public.admin_unmapped_reps() from public, anon;
grant  execute on function public.admin_unmapped_reps() to authenticated;
