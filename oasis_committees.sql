-- ============================================================
-- Oasis Club — Generalized Committees (add/remove committees and
-- their members; Welfare Committee's loan powers move onto this
-- system instead of being a role label).
-- Run this once in Supabase SQL Editor.
-- ============================================================

create table if not exists committees (
  id text primary key,
  name text not null unique,
  description text,
  created_at timestamptz not null default now()
);

create table if not exists committee_members (
  id text primary key,
  committee_id text not null references committees(id) on delete cascade,
  member_id text not null,
  is_chair boolean not null default false,
  added_at timestamptz not null default now(),
  unique(committee_id, member_id)
);

alter table committees enable row level security;
alter table committee_members enable row level security;

drop policy if exists "Allow read committees" on committees;
create policy "Allow read committees" on committees for select using (true);
drop policy if exists "Allow read committee_members" on committee_members;
create policy "Allow read committee_members" on committee_members for select using (true);

revoke insert, update, delete on committees from anon, authenticated;
revoke insert, update, delete on committee_members from anon, authenticated;

-- ------------------------------------------------------------
-- Officers manage committees (create/rename/delete) and their
-- membership (add/remove members, set chairperson).
-- ------------------------------------------------------------
create or replace function add_committee(
  p_officer_pin text,
  p_id text,
  p_name text,
  p_description text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to create committees';
  end if;
  insert into committees (id, name, description) values (p_id, p_name, p_description);
end;
$$;

create or replace function delete_committee(
  p_officer_pin text,
  p_id text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to delete committees';
  end if;
  delete from committees where id = p_id;
end;
$$;

create or replace function add_committee_member(
  p_officer_pin text,
  p_id text,
  p_committee_id text,
  p_member_id text,
  p_is_chair boolean
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to manage committee membership';
  end if;

  -- Only one chairperson per committee — demote anyone else currently marked as chair.
  if coalesce(p_is_chair,false) then
    update committee_members set is_chair = false
    where committee_id = p_committee_id and member_id <> p_member_id;
  end if;

  insert into committee_members (id, committee_id, member_id, is_chair)
  values (p_id, p_committee_id, p_member_id, coalesce(p_is_chair,false))
  on conflict (committee_id, member_id) do update set is_chair = excluded.is_chair;
end;
$$;

create or replace function remove_committee_member(
  p_officer_pin text,
  p_committee_id text,
  p_member_id text
) returns void
language plpgsql
security definer
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Not authorized to manage committee membership';
  end if;
  delete from committee_members where committee_id = p_committee_id and member_id = p_member_id;
end;
$$;

grant execute on function add_committee(text, text, text, text) to anon, authenticated;
grant execute on function delete_committee(text, text) to anon, authenticated;
grant execute on function add_committee_member(text, text, text, text, boolean) to anon, authenticated;
grant execute on function remove_committee_member(text, text, text) to anon, authenticated;

alter publication supabase_realtime add table committees;
alter publication supabase_realtime add table committee_members;

-- ------------------------------------------------------------
-- Seed the existing Welfare Committee and Project Committee so
-- they show up immediately instead of starting from empty.
-- Adjust/remove this block if you'd rather start blank.
-- ------------------------------------------------------------
insert into committees (id, name, description)
values
  ('committee_welfare', 'Welfare Committee', 'Manages welfare loans: receives disbursement from the Treasurer, approves and disburses loans, recoups repayments, and reports status monthly at the general meeting.'),
  ('committee_project', 'Project Committee', 'Oversees club building and development projects.')
on conflict (name) do nothing;

-- Carry over anyone currently marked role = 'Welfare Committee' into the
-- new committee_members table automatically, so no one loses access.
insert into committee_members (id, committee_id, member_id, is_chair)
select 'cm_' || m.id, 'committee_welfare', m.id, false
from members m
where m.role = 'Welfare Committee'
on conflict (committee_id, member_id) do nothing;

-- ------------------------------------------------------------
-- Update is_welfare_committee_pin (from oasis_welfare_loans.sql) so loan
-- approval/repayment recognizes membership via the new committees system,
-- not just the old role label. Falls back to the role label for anyone
-- not yet migrated, so nobody loses access.
-- ------------------------------------------------------------
create or replace function is_welfare_committee_pin(p_pin text) returns boolean
language plpgsql
security definer
as $$
declare
  v_member_id text;
  v_in_committee boolean;
begin
  select id into v_member_id from members where pin = p_pin limit 1;
  if v_member_id is null then
    return false;
  end if;

  select exists(
    select 1
    from committee_members cm
    join committees c on c.id = cm.committee_id
    where cm.member_id = v_member_id and c.name = 'Welfare Committee'
  ) into v_in_committee;

  if v_in_committee then
    return true;
  end if;

  -- Legacy fallback
  return exists(select 1 from members where id = v_member_id and role = 'Welfare Committee');
end;
$$;
