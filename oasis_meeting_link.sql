-- ============================================================
-- Oasis Club — Meeting Link on Events
-- Lets officers attach a Google Meet (or any video call) link
-- when creating an event, shown as a "Join Meeting" button.
-- Run this once in Supabase SQL Editor.
-- ============================================================

alter table club_events add column if not exists meeting_link text;

-- Remove the old 8-parameter version so there's only one signature.
drop function if exists add_club_event(text, text, text, date, text, text, text, text);

create or replace function add_club_event(
  p_officer_pin text,
  p_id text,
  p_title text,
  p_date date,
  p_time text,
  p_location text,
  p_type text,
  p_description text,
  p_meeting_link text default null
) returns void
language plpgsql
security definer
as $$
declare
  v_creator_id text;
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to post events';
  end if;
  select id into v_creator_id from members where pin = p_officer_pin limit 1;
  insert into club_events (id, title, date, time, location, type, description, created_by_member_id, meeting_link)
  values (p_id, p_title, p_date, p_time, p_location, coalesce(p_type,'general'), p_description, v_creator_id, p_meeting_link);
end;
$$;

grant execute on function add_club_event(text, text, text, date, text, text, text, text, text) to anon, authenticated;
