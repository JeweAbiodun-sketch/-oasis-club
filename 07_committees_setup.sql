-- ============================================================
-- Oasis Club App — Sub-Committees feature setup
-- Run this AFTER 01-06 setup scripts have already been run.
-- Safe to re-run.
--
-- This restores a feature that existed in an earlier branch of this
-- app's development (Committees, distinct from the main officer
-- roster page "Committee"): officers can create named sub-committees
-- (e.g. "Welfare Committee", "Building Committee"), assign active
-- members to them, and designate one chairperson per committee.
-- Other features (Welfare Loans) check membership of these
-- committees for access.
-- ============================================================

create table if not exists public.committees (
  id text primary key,
  name text not null unique,
  description text default '',
  created_at timestamptz not null default now()
);

create table if not exists public.committee_members (
  id text primary key,
  committee_id text not null references public.committees(id) on delete cascade,
  member_id text not null references public.members(id) on delete cascade,
  is_chair boolean not null default false,
  added_at timestamptz not null default now(),
  unique(committee_id, member_id)
);

alter table public.committees enable row level security;
alter table public.committee_members enable row level security;

drop policy if exists "committees are publicly readable" on public.committees;
create policy "committees are publicly readable" on public.committees
  for select to anon, authenticated
  using (true);

drop policy if exists "committee_members are publicly readable" on public.committee_members;
create policy "committee_members are publicly readable" on public.committee_members
  for select to anon, authenticated
  using (true);

-- ============================================================
-- RPC: create a committee. Officer login only.
-- ============================================================

create or replace function public.add_committee(
  p_officer_pin text,
  p_id text,
  p_name text,
  p_description text default ''
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Incorrect officer PIN';
  end if;
  if length(trim(p_name)) = 0 then
    raise exception 'Committee name cannot be empty';
  end if;
  insert into committees (id, name, description)
  values (p_id, trim(p_name), coalesce(p_description,''));
end;
$$;

grant execute on function public.add_committee(text,text,text,text) to anon, authenticated;

-- ============================================================
-- RPC: delete a committee (cascades to its members via FK).
-- ============================================================

create or replace function public.delete_committee(
  p_officer_pin text,
  p_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Incorrect officer PIN';
  end if;
  delete from committees where id = p_id;
end;
$$;

grant execute on function public.delete_committee(text,text) to anon, authenticated;

-- ============================================================
-- RPC: add a member to a committee, or update their chair status
-- if they're already on it (upsert by committee_id+member_id).
-- Setting is_chair=true clears any other chair on that committee
-- first, so there's always at most one chairperson.
-- ============================================================

create or replace function public.add_committee_member(
  p_officer_pin text,
  p_id text,
  p_committee_id text,
  p_member_id text,
  p_is_chair boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Incorrect officer PIN';
  end if;

  if p_is_chair then
    update committee_members set is_chair = false
    where committee_id = p_committee_id and is_chair = true;
  end if;

  insert into committee_members (id, committee_id, member_id, is_chair)
  values (p_id, p_committee_id, p_member_id, p_is_chair)
  on conflict (committee_id, member_id)
  do update set is_chair = excluded.is_chair;
end;
$$;

grant execute on function public.add_committee_member(text,text,text,text,boolean) to anon, authenticated;

-- ============================================================
-- RPC: remove a member from a committee.
-- ============================================================

create or replace function public.remove_committee_member(
  p_officer_pin text,
  p_committee_id text,
  p_member_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Incorrect officer PIN';
  end if;
  delete from committee_members
  where committee_id = p_committee_id and member_id = p_member_id;
end;
$$;

grant execute on function public.remove_committee_member(text,text,text) to anon, authenticated;

-- ============================================================
-- REALTIME
-- ============================================================
alter publication supabase_realtime add table public.committees;
alter publication supabase_realtime add table public.committee_members;

-- ============================================================
-- Done.
-- ============================================================
