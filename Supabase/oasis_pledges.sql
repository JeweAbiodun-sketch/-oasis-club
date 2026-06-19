-- ============================================================
-- Oasis Club — Pledges (standalone, separate from Welfare)
-- Run this once in Supabase SQL Editor.
-- ============================================================

create table if not exists club_pledges (
  id text primary key,
  member_id text,             -- nullable: some pledges are from non-members (e.g. diaspora donors)
  donor_name text not null,   -- always stored, even for members, for easy display
  amount numeric not null,    -- can be negative for refunds/transfers out
  purpose text,
  pledge_date date not null default current_date,
  recorded_by text,
  created_at timestamptz not null default now()
);

alter table club_pledges enable row level security;

drop policy if exists "Allow read club_pledges" on club_pledges;
create policy "Allow read club_pledges" on club_pledges for select using (true);

revoke insert, update, delete on club_pledges from anon, authenticated;

create or replace function add_club_pledge(
  p_officer_pin text,
  p_id text,
  p_donor_name text,
  p_member_id text,
  p_amount numeric,
  p_purpose text,
  p_pledge_date date
) returns void
language plpgsql
security definer
as $$
declare
  v_recorder_id text;
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to record pledges';
  end if;

  select id into v_recorder_id from members where pin = p_officer_pin limit 1;

  insert into club_pledges (id, member_id, donor_name, amount, purpose, pledge_date, recorded_by)
  values (p_id, p_member_id, p_donor_name, p_amount, p_purpose, p_pledge_date, v_recorder_id);
end;
$$;

create or replace function delete_club_pledge(
  p_officer_pin text,
  p_id text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to delete pledges';
  end if;
  delete from club_pledges where id = p_id;
end;
$$;

grant execute on function add_club_pledge(text, text, text, text, numeric, text, date) to anon, authenticated;
grant execute on function delete_club_pledge(text, text) to anon, authenticated;

alter publication supabase_realtime add table club_pledges;
