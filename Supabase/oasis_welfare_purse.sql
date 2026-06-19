-- ============================================================
-- Oasis Club — Welfare Committee Purse (fund release + expenses)
-- Run this once in Supabase SQL Editor, alongside the earlier
-- oasis_welfare_loans.sql file (this extends it).
-- ============================================================

-- Each row is either a 'release' (Treasurer hands money to the
-- committee) or an 'expense' (committee spends money, NOT a loan
-- -- e.g. a one-off welfare gift, materials, event cost reported
-- at the monthly meeting).
create table if not exists welfare_purse_entries (
  id text primary key,
  entry_type text not null,        -- 'release' | 'expense'
  amount numeric not null,
  description text not null,
  recorded_by text,                -- member id (committee member or treasurer)
  entry_date date not null default current_date,
  created_at timestamptz not null default now()
);

alter table welfare_purse_entries enable row level security;

drop policy if exists "Allow read welfare purse entries" on welfare_purse_entries;
create policy "Allow read welfare purse entries" on welfare_purse_entries for select using (true);

revoke insert, update, delete on welfare_purse_entries from anon, authenticated;

-- ------------------------------------------------------------
-- Treasurer releases funds to the Welfare Committee.
-- ------------------------------------------------------------
create or replace function release_welfare_fund(
  p_officer_pin text,
  p_id text,
  p_amount numeric,
  p_description text,
  p_entry_date date
) returns void
language plpgsql
security definer
as $$
declare
  v_valid boolean := false;
  v_recorder_id text;
begin
  if p_officer_pin in ('7395','1064') then  -- treasurer, financial_secretary
    v_valid := true;
  end if;
  if not v_valid then
    select exists(
      select 1 from members where pin = p_officer_pin and role in ('Treasurer','Financial Secretary')
    ) into v_valid;
  end if;
  if not v_valid then
    raise exception 'Only the Treasurer or Financial Secretary can release welfare funds';
  end if;

  select id into v_recorder_id from members where pin = p_officer_pin limit 1;

  insert into welfare_purse_entries (id, entry_type, amount, description, recorded_by, entry_date)
  values (p_id, 'release', p_amount, p_description, v_recorder_id, p_entry_date);
end;
$$;

-- ------------------------------------------------------------
-- Welfare Committee logs a non-loan expense against the purse
-- (e.g. what they reported spending at the monthly meeting).
-- ------------------------------------------------------------
create or replace function log_welfare_expense(
  p_committee_pin text,
  p_id text,
  p_amount numeric,
  p_description text,
  p_entry_date date
) returns void
language plpgsql
security definer
as $$
declare
  v_recorder_id text;
begin
  if not is_welfare_committee_pin(p_committee_pin) then
    raise exception 'Only Welfare Committee members can log welfare expenses';
  end if;

  select id into v_recorder_id from members where pin = p_committee_pin limit 1;

  insert into welfare_purse_entries (id, entry_type, amount, description, recorded_by, entry_date)
  values (p_id, 'expense', p_amount, p_description, v_recorder_id, p_entry_date);
end;
$$;

grant execute on function release_welfare_fund(text, text, numeric, text, date) to anon, authenticated;
grant execute on function log_welfare_expense(text, text, numeric, text, date) to anon, authenticated;

alter publication supabase_realtime add table welfare_purse_entries;
