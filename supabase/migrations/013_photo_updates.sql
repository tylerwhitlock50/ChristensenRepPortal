/*============================================================================
  013_photo_updates.sql

  Why: 004_app_crm.sql created public.photos and 007/010 gave it select,
  insert and admin-delete policies — but no UPDATE policy. That turned out to
  matter for a reason nobody anticipated when the table was written.

  A rep takes photos DURING a visit survey, before the visit row exists, so
  those rows are inserted with visit_id = null. The visit id only exists after
  the survey is saved. With no update policy the rep cannot attach it, so every
  photo taken inside a survey stays permanently unlinked from the visit it
  documents — which is exactly the structured field intelligence the PRD is
  asking for (goal #4).

  The same gap also means a rep cannot fix a typo in their own caption.

  Scope is deliberately narrow: the AUTHOR of a photo may update it, and only
  while they still have access to the account. Admins may update any photo on
  any account they can see. The WITH CHECK repeats the predicate so a photo
  cannot be re-pointed at an account the caller does not own — without it,
  UPDATE ... SET customer_key = '<someone else's>' would be legal.

  Follows 010's pattern: invariant predicates wrapped in scalar subqueries so
  they are InitPlans evaluated once per query, not once per row.
============================================================================*/

drop policy if exists "update own photos" on public.photos;
create policy "update own photos" on public.photos
  for update to authenticated
  using (
    (select public.is_admin())
    or (
      created_by = (select auth.uid())
      and customer_key in (select public.my_customer_keys())
    )
  )
  with check (
    (select public.is_admin())
    or (
      created_by = (select auth.uid())
      and customer_key in (select public.my_customer_keys())
    )
  );

comment on policy "update own photos" on public.photos is
  'Lets the author attach visit_id after a survey is saved, and edit their own '
  'caption/category. WITH CHECK repeats the predicate so a photo cannot be '
  'moved to an account the caller does not own.';
