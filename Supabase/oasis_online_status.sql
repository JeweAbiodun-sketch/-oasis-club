-- ============================================================
-- Oasis Club — Member Online Status & Last Seen
-- Run this once in Supabase SQL Editor, alongside the earlier files.
-- ============================================================

alter table members add column if not exists is_online boolean not null default false;
alter table members add column if not exists last_seen timestamptz;

create or replace function set_member_online_status(
  p_member_pin text,
  p_is_online boolean
) returns void
language plpgsql
security definer
as $$
begin
  update members
  set is_online = p_is_online,
      last_seen = now()
  where pin = p_member_pin;

  if not found then
    raise exception 'Invalid member PIN';
  end if;
end;
$$;

-- Called periodically while the member has the app open, so "last seen"
-- stays fresh even if they never explicitly toggle online/offline.
create or replace function touch_member_last_seen(
  p_member_pin text
) returns void
language plpgsql
security definer
as $$
begin
  update members set last_seen = now() where pin = p_member_pin;
end;
$$;

grant execute on function set_member_online_status(text, boolean) to anon, authenticated;
grant execute on function touch_member_last_seen(text) to anon, authenticated;
