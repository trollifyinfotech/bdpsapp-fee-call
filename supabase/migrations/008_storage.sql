-- =====================================================================
-- Migration 008 : Storage buckets and policies
-- Path convention for every bucket: <school_id>/<anything>
-- so policies can verify school membership from the first folder name.
-- Buckets are PRIVATE (served through signed URLs) except school-logos
-- which is public-read so the login/registration pages can show logos.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('school-logos',      'school-logos',      true,  2097152,  array['image/png','image/jpeg','image/webp']),
  ('student-photos',    'student-photos',    false, 2097152,  array['image/png','image/jpeg','image/webp']),
  ('receipt-attachments','receipt-attachments', false, 5242880, array['image/png','image/jpeg','application/pdf']),
  ('rte-documents',     'rte-documents',     false, 5242880,  array['image/png','image/jpeg','application/pdf'])
on conflict (id) do nothing;

-- Registration logos are uploaded by the new (not yet approved) owner into  pending/<auth.uid()>/...
create policy "logos public read" on storage.objects for select using (bucket_id = 'school-logos');
create policy "logos pending upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'school-logos' and (storage.foldername(name))[1] = 'pending'
              and (storage.foldername(name))[2] = auth.uid()::text);
create policy "logos school upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'school-logos' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and public.has_perm(((storage.foldername(name))[1])::uuid, 'manage_settings'));

create policy "photos read" on storage.objects for select to authenticated
  using (bucket_id = 'student-photos' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
         and public.has_perm(((storage.foldername(name))[1])::uuid, 'view_student_list'));
create policy "photos write" on storage.objects for insert to authenticated
  with check (bucket_id = 'student-photos' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and (public.has_perm(((storage.foldername(name))[1])::uuid, 'add_student')
                   or public.has_perm(((storage.foldername(name))[1])::uuid, 'edit_student')));

create policy "receipt att read" on storage.objects for select to authenticated
  using (bucket_id = 'receipt-attachments' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
         and public.has_perm(((storage.foldername(name))[1])::uuid, 'view_fee_amounts'));
create policy "receipt att write" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipt-attachments' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and public.has_perm(((storage.foldername(name))[1])::uuid, 'collect_fee'));

create policy "rte read" on storage.objects for select to authenticated
  using (bucket_id = 'rte-documents' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
         and public.has_perm(((storage.foldername(name))[1])::uuid, 'manage_rte'));
create policy "rte write" on storage.objects for insert to authenticated
  with check (bucket_id = 'rte-documents' and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
              and public.has_perm(((storage.foldername(name))[1])::uuid, 'manage_rte'));
-- No UPDATE/DELETE policies on any bucket for end users: files are never silently removed.
