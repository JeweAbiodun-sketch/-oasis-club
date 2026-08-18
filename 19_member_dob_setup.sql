-- ============================================================
-- Oasis Club App - Fix: enable member Date of Birth on the LIVE database.
--
-- WHY THIS EXISTS
-- The birthday features (Overview board, News "Birthday Spotlight",
-- profile "Date of birth") were shipped in the app + in the MASTER
-- migration, but that migration was never applied to the live Supabase.
-- As a result the live database has NO `dob` column and the live
-- update_member_profile() function has NO p_dob parameter. Every
-- birthday members "saved" errored server-side and fell back to that
-- device's localStorage only -- so nothing was ever shared.
--
-- Running this once repairs it. Safe and idempotent (re-runnable).
-- Run in: Supabase Dashboard -> SQL Editor -> paste -> Run.
-- ============================================================

-- 1) Add the dob column (idempotent).
alter table public.members add column if not exists dob text not null default '';

-- 2) Replace update_member_profile with the version that accepts & stores
--    the birthday. We drop the old 6-argument version first; the new
--    7-argument version below still satisfies older callers because every
--    added parameter has a default (PostgREST matches named args to it).
drop function if exists public.update_member_profile(text,text,text,text,text,text);

create or replace function public.update_member_profile(
  p_member_id   text,
  p_current_pin text,
  p_name        text,
  p_phone       text default '',
  p_email       text default '',
  p_photo       text default null,
  p_dob         text default null
) returns void language plpgsql security definer
set search_path = public
as $$
begin
  if not exists (select 1 from members where id = p_member_id and pin = p_current_pin) then
    raise exception 'Unauthorized: incorrect PIN';
  end if;
  update members
     set name  = p_name,
         phone = coalesce(p_phone, ''),
         email = coalesce(p_email, ''),
         photo = case when p_photo is null then photo else p_photo end,
         dob   = coalesce(p_dob, dob)
   where id = p_member_id;
end;
$$;

grant execute on function public.update_member_profile(text,text,text,text,text,text,text) to anon, authenticated;

-- 3) Tell PostgREST to pick up the new column + function signature.
notify pgrst, 'reload schema';

-- ============================================================
-- Done. After this runs, members can save birthdays to the shared
-- database. Existing birthdays that are currently stuck in a member's
-- local storage will sync up the next time that member opens the app
-- (see the app-side auto-sync), or when they press Save on their profile.
-- ============================================================
