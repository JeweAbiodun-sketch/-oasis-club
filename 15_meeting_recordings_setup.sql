-- ============================================================
-- Oasis Club App - Meeting Recordings (audio archive) setup.
-- A place to post the audio of each monthly/general meeting for
-- reference, alongside the written Meeting minutes.
-- Run AFTER 04_news_setup.sql. Safe to re-run.
--
-- Trust model matches the rest of the app: any active member can
-- LISTEN, but only an officer-login PIN can add or remove a recording
-- (same as Meeting minutes). Enforced by the RPCs below via is_officer_pin().
-- ============================================================

-- ------------------------------------------------------------
-- TABLE
-- ------------------------------------------------------------
create table if not exists public.meeting_recordings (
  id uuid primary key default gen_random_uuid(),
  uploaded_by text references public.members(id) on delete set null,
  title text not null,
  meeting_date date not null,
  meeting_type text,
  note text,
  audio_url text not null,
  audio_name text,
  duration_seconds integer,
  file_size bigint,
  created_at timestamptz not null default now()
);

alter table public.meeting_recordings enable row level security;

drop policy if exists "meeting_recordings are publicly readable" on public.meeting_recordings;
create policy "meeting_recordings are publicly readable" on public.meeting_recordings
  for select to anon, authenticated
  using (true);

-- ------------------------------------------------------------
-- STORAGE BUCKET for the audio files.
-- Public bucket, same model as news-attachments. 100 MB per-file cap.
-- Broad audio mime list so phone recordings, WhatsApp voice notes and
-- the app's own compressed MP3 output are all accepted. octet-stream is
-- included because some browsers report m4a/opus that way.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('meeting-recordings', 'meeting-recordings', true, 104857600, array[
  'audio/mpeg','audio/mp3','audio/mp4','audio/x-m4a','audio/m4a','audio/aac',
  'audio/ogg','audio/opus','audio/wav','audio/x-wav','audio/webm',
  'audio/3gpp','audio/amr','video/mp4','video/webm','application/octet-stream'
])
on conflict (id) do update set
  public = true,
  file_size_limit = 104857600,
  allowed_mime_types = array[
    'audio/mpeg','audio/mp3','audio/mp4','audio/x-m4a','audio/m4a','audio/aac',
    'audio/ogg','audio/opus','audio/wav','audio/x-wav','audio/webm',
    'audio/3gpp','audio/amr','video/mp4','video/webm','application/octet-stream'
  ];

drop policy if exists "meeting recordings are publicly readable" on storage.objects;
create policy "meeting recordings are publicly readable" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'meeting-recordings');

drop policy if exists "meeting recordings can be uploaded" on storage.objects;
create policy "meeting recordings can be uploaded" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'meeting-recordings');

-- ------------------------------------------------------------
-- RPC: add a recording. Officer-login PIN only.
-- ------------------------------------------------------------
create or replace function public.add_meeting_recording(
  p_officer_pin text,
  p_title text,
  p_meeting_date date,
  p_meeting_type text,
  p_note text,
  p_audio_url text,
  p_audio_name text,
  p_duration_seconds integer default null,
  p_file_size bigint default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uploader_id text;
  v_new_id uuid;
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Only an Executive Officer can post a meeting recording';
  end if;

  if length(trim(coalesce(p_title,''))) = 0 then
    raise exception 'Title cannot be empty';
  end if;

  if length(trim(coalesce(p_audio_url,''))) = 0 then
    raise exception 'A recording file is required';
  end if;

  select id into v_uploader_id from members where pin = p_officer_pin limit 1;

  insert into meeting_recordings
    (uploaded_by, title, meeting_date, meeting_type, note, audio_url, audio_name, duration_seconds, file_size)
  values
    (v_uploader_id, trim(p_title), p_meeting_date, nullif(trim(coalesce(p_meeting_type,'')),''),
     nullif(trim(coalesce(p_note,'')),''), p_audio_url, p_audio_name, p_duration_seconds, p_file_size)
  returning id into v_new_id;

  return v_new_id;
end;
$fn$;

grant execute on function public.add_meeting_recording(text,text,date,text,text,text,text,integer,bigint) to anon, authenticated;

-- ------------------------------------------------------------
-- RPC: delete a recording. Officer-login PIN only.
-- (Removing the storage object is done client-side after this succeeds.)
-- ------------------------------------------------------------
create or replace function public.delete_meeting_recording(
  p_officer_pin text,
  p_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Only an Executive Officer can remove a meeting recording';
  end if;

  delete from meeting_recordings where id = p_id;

  if not found then
    raise exception 'Recording not found';
  end if;
end;
$fn$;

grant execute on function public.delete_meeting_recording(text,uuid) to anon, authenticated;

-- ------------------------------------------------------------
-- REALTIME
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'meeting_recordings'
  ) then
    alter publication supabase_realtime add table public.meeting_recordings;
  end if;
end $$;

notify pgrst, 'reload schema';

-- ============================================================
-- Done.
-- ============================================================
