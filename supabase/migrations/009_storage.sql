/*============================================================================
  009_storage.sql
  Purpose: Private Storage bucket for account photos. Object paths follow
           <customer_key>/<uuid>.<ext> so RLS can gate by account from the
           path's first folder. The public.photos table (004) holds the
           metadata row pointing at storage_path.
============================================================================*/

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('account-photos', 'account-photos', false,
        10485760,                                   -- 10 MB per photo
        array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do nothing;

create policy "read account photos" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'account-photos'
    and public.has_account_access((storage.foldername(name))[1])
  );

create policy "upload account photos" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'account-photos'
    and public.has_account_access((storage.foldername(name))[1])
  );

create policy "admin deletes account photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'account-photos' and public.is_admin());
