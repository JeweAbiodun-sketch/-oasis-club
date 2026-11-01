-- ============================================================
-- Oasis Club App - Annual dues kept PER YEAR (year tabs on the Dues page)
-- Run once in the Supabase SQL Editor. Safe to re-run.
--
-- * dues_payments stores one row per member per year (e.g. 2025/2026).
-- * Existing amounts are copied in under the club's current dues year.
-- * members.dues_paid stays as "the current year's amount", so approving
--   a payment (approve_payment_evidence) keeps working unchanged.
--   A trigger mirrors every change to it into dues_payments.
-- * Changing the Year label on the Dues page switches members.dues_paid to
--   the amounts saved for that year (0 if none) - nothing is lost.
-- ============================================================

create table if not exists public.dues_payments (
  member_id  text not null,
  year_label text not null,
  amount     numeric not null default 0,
  updated_at timestamptz not null default now(),
  primary key (member_id, year_label)
);

alter table public.dues_payments enable row level security;
drop policy if exists dues_payments_read on public.dues_payments;
create policy dues_payments_read on public.dues_payments for select using (true);

-- Copy today's amounts under the current dues year (does not overwrite).
insert into public.dues_payments (member_id, year_label, amount)
select m.id, coalesce((select dues_year_label from public.club_meta where id = 1), '2025/2026'), coalesce(m.dues_paid, 0)
from public.members m
where coalesce(m.dues_paid, 0) > 0
on conflict (member_id, year_label) do nothing;

-- Officer sets one member's total for one year.
create or replace function public.officer_set_dues_year(
  p_officer_pin text, p_member_id text, p_year text, p_amount numeric
) returns void
language plpgsql security definer set search_path = public
as $fn$
begin
  if not is_officer_pin(p_officer_pin) then
    raise exception 'Incorrect officer PIN';
  end if;
  insert into dues_payments (member_id, year_label, amount, updated_at)
  values (p_member_id, p_year, greatest(coalesce(p_amount, 0), 0), now())
  on conflict (member_id, year_label)
  do update set amount = excluded.amount, updated_at = now();
  if p_year = (select dues_year_label from club_meta where id = 1) then
    update members set dues_paid = greatest(coalesce(p_amount, 0), 0), updated_at = now() where id = p_member_id;
  end if;
end;
$fn$;

-- Mirror members.dues_paid (current year) into dues_payments.
create or replace function public.sync_dues_current_year() returns trigger
language plpgsql security definer set search_path = public
as $fn$
declare v_year text;
begin
  select coalesce(dues_year_label, '2025/2026') into v_year from club_meta where id = 1;
  insert into dues_payments (member_id, year_label, amount, updated_at)
  values (new.id, v_year, coalesce(new.dues_paid, 0), now())
  on conflict (member_id, year_label)
  do update set amount = excluded.amount, updated_at = now();
  return new;
end;
$fn$;
drop trigger if exists trg_sync_dues_current_year on public.members;
create trigger trg_sync_dues_current_year
  after update of dues_paid on public.members
  for each row when (old.dues_paid is distinct from new.dues_paid)
  execute function public.sync_dues_current_year();

-- When the current dues year label changes, load that year's amounts.
create or replace function public.roll_dues_year() returns trigger
language plpgsql security definer set search_path = public
as $fn$
begin
  if new.dues_year_label is distinct from old.dues_year_label then
    update members m
       set dues_paid = coalesce((select d.amount from dues_payments d
                                  where d.member_id = m.id and d.year_label = new.dues_year_label), 0);
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_roll_dues_year on public.club_meta;
create trigger trg_roll_dues_year
  after update of dues_year_label on public.club_meta
  for each row execute function public.roll_dues_year();

do $$ begin
  alter publication supabase_realtime add table public.dues_payments;
exception when duplicate_object then null; when undefined_object then null;
end $$;

notify pgrst, 'reload schema';
