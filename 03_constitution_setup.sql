-- ============================================================
-- Oasis Club App — Constitution feature setup
-- Run this AFTER 01_setup.sql and 02_seed_data.sql have already
-- been run successfully. Safe to re-run.
-- ============================================================

-- Add columns to track the current constitution PDF, if not already present.
alter table public.club_meta add column if not exists constitution_url text;
alter table public.club_meta add column if not exists constitution_uploaded_at timestamptz;

-- ============================================================
-- STORAGE BUCKET
-- A public bucket so the PDF can be viewed/downloaded by anyone
-- with the link, same as the rest of the app's "anon key can read
-- everything" model. Uploads are technically open at the database
-- level too (matching the rest of this app's accepted security
-- tradeoff), and the upload BUTTON itself is hidden in the app for
-- anyone who isn't an officer or office holder.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('constitution', 'constitution', true, 10485760, array['application/pdf'])
on conflict (id) do update set
  public = true,
  file_size_limit = 10485760,
  allowed_mime_types = array['application/pdf'];

-- Allow anyone to read (matches the public bucket setting above, but
-- explicit policies are still required for the storage.objects table).
drop policy if exists "constitution is publicly readable" on storage.objects;
create policy "constitution is publicly readable" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'constitution');

-- Allow uploading and replacing the PDF. The app's own UI restricts
-- which sessions ever show the upload control; this policy mirrors
-- the same trust model already used for table writes elsewhere in
-- this app, rather than introducing a stricter, inconsistent rule
-- just for this one feature.
drop policy if exists "constitution can be uploaded" on storage.objects;
create policy "constitution can be uploaded" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'constitution');

drop policy if exists "constitution can be replaced" on storage.objects;
create policy "constitution can be replaced" on storage.objects
  for update to anon, authenticated
  using (bucket_id = 'constitution')
  with check (bucket_id = 'constitution');

-- ============================================================
-- Done. The app stores the resulting public URL in
-- club_meta.constitution_url after a successful upload.
-- ============================================================

-- Records the current constitution PDF's public URL after a successful
-- upload to the 'constitution' storage bucket. Allowed for either one
-- of the three officer-login PINs, or the PIN of a member who currently
-- holds one of the named offices (President, VP, Secretary, etc) --
-- matching who the app's UI shows the upload control to.
create or replace function public.officer_update_constitution_url(
  p_pin text,
  p_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_officeholder boolean;
begin
  select exists(
    select 1 from members
    where pin = p_pin
    and role in ('President','Vice-President','Secretary','Assistant Secretary','Treasurer','Financial Secretary','PRO')
    and status not in ('suspended','dismissed')
  ) into v_is_officeholder;

  if not is_officer_pin(p_pin) and not v_is_officeholder then
    raise exception 'Only club officers can update the constitution';
  end if;

  update club_meta set constitution_url = p_url, constitution_uploaded_at = now() where id = 1;
end;
$$;

grant execute on function public.officer_update_constitution_url(text,text) to anon, authenticated;
