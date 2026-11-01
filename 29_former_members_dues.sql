-- ============================================================
-- Oasis Club App - Former members' dues history
-- Run ONCE in the Supabase SQL Editor (after 28_dues_oldest_year_first.sql).
--
-- Members who are no longer with the club are kept in their own small table so they
-- do not count toward the 25-member cap and cannot log in. The Dues page shows them
-- only in the financial years they actually paid in (totals from the TRANSACTIONS ledger).
-- If a name is already in the Members list (e.g. in the Archive), that member's record is
-- updated instead, so nobody appears twice.
-- ============================================================

create table if not exists public.dues_former_members (
  id         text primary key,
  name       text not null,
  joined     date,
  total_paid numeric not null default 0,
  note       text
);
alter table public.dues_former_members enable row level security;
drop policy if exists dues_former_members_read on public.dues_former_members;
create policy dues_former_members_read on public.dues_former_members for select using (true);

-- Name, total annual dues paid (ledger), first dues year (first day of that financial year)
create temp table _former (n text, total numeric, joined date) on commit drop;
insert into _former values
  ('Atolani Femi',  50000, date '2020-10-01'),
  ('Adetoyi Dare',  10000, date '2022-10-01'),
  ('Falade Taiwo',   6000, date '2020-10-01');

-- Already in the Members list (any status)? Update that record.
update public.members m
   set dues_paid = f.total, joined = f.joined, updated_at = now()
  from _former f
 where lower(btrim(m.name)) = lower(btrim(f.n));

-- Otherwise keep them in the former-members table.
insert into public.dues_former_members (id, name, joined, total_paid)
select 'former-' || regexp_replace(lower(f.n), '[^a-z]+', '-', 'g'), f.n, f.joined, f.total
  from _former f
 where not exists (select 1 from public.members m where lower(btrim(m.name)) = lower(btrim(f.n)))
on conflict (id) do update set total_paid = excluded.total_paid, joined = excluded.joined;

notify pgrst, 'reload schema';

-- Check: who is in the Archive, and who was added to the former-members table
select 'archived member' as kind, name, status, joined, dues_paid as total from public.members where status in ('suspended','dismissed','inactive')
union all
select 'former member', name, 'former', joined, total_paid from public.dues_former_members
order by 1, 2;
