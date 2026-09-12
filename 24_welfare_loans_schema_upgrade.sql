-- ============================================================
-- Oasis Club App — bring the live welfare_loans schema up to date.
--
-- Symptom: "Could not find the function public.propose_welfare_loan(...)".
-- Cause: the "adjustable profit + monthly default fine + due date" upgrade to
-- the welfare loans feature was written in Supabase/oasis_welfare_loans.sql but
-- never applied to the live database. So the live welfare_loans table is missing
-- newer columns (e.g. late_fee_per_month) and the live propose_welfare_loan()
-- still has the OLD parameter list — it doesn't match what the app now sends.
--
-- This migration is idempotent and safe to re-run:
--   1. adds any missing welfare_loans columns,
--   2. drops the old propose_welfare_loan overload(s) and recreates the current
--      one, and refreshes the related loan functions,
--   3. reloads the PostgREST schema cache.
-- Run this in the Supabase SQL editor.
-- ============================================================

-- ------------------------------------------------------------
-- 1) Columns the newer feature relies on. ADD ... IF NOT EXISTS is a no-op for
--    columns that already exist, so only the missing ones are created.
-- ------------------------------------------------------------
alter table public.welfare_loans add column if not exists interest_rate            numeric not null default 0;
alter table public.welfare_loans add column if not exists late_fee_per_month        numeric not null default 0;
alter table public.welfare_loans add column if not exists late_fee_accrued          numeric not null default 0;
alter table public.welfare_loans add column if not exists late_fee_months_charged   integer not null default 0;
alter table public.welfare_loans add column if not exists amount_due                numeric not null default 0;
alter table public.welfare_loans add column if not exists amount_repaid             numeric not null default 0;
alter table public.welfare_loans add column if not exists purpose                   text    not null default '';
alter table public.welfare_loans add column if not exists proposed_by               text;
alter table public.welfare_loans add column if not exists approver_1                text;
alter table public.welfare_loans add column if not exists approver_2                text;
alter table public.welfare_loans add column if not exists status                    text    not null default 'proposed';
alter table public.welfare_loans add column if not exists due_date                  date;
alter table public.welfare_loans add column if not exists disbursed_date            date;
alter table public.welfare_loans add column if not exists created_at                timestamptz not null default now();

-- ------------------------------------------------------------
-- 2a) Remove EVERY old overload of propose_welfare_loan (any signature), so the
--     single current signature below is the only one the app can resolve to.
-- ------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'propose_welfare_loan'
  loop
    execute 'drop function ' || r.sig;
  end loop;
end $$;

-- ------------------------------------------------------------
-- 2b) Current loan functions (from Supabase/oasis_welfare_loans.sql).
-- ------------------------------------------------------------
create or replace function public.propose_welfare_loan(
  p_committee_pin text,
  p_id text,
  p_member_id text,
  p_principal numeric,
  p_interest_rate numeric,
  p_late_fee_per_month numeric,
  p_purpose text,
  p_due_date date
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_committee_id text;
begin
  if not is_welfare_committee_pin(p_committee_pin) then
    raise exception 'Only Welfare Committee members can propose loans';
  end if;

  select id into v_committee_id from members where pin = p_committee_pin limit 1;

  insert into welfare_loans (
    id, member_id, principal, interest_rate, late_fee_per_month, amount_due, purpose,
    proposed_by, status, due_date
  ) values (
    p_id, p_member_id, p_principal, p_interest_rate, coalesce(p_late_fee_per_month,0),
    p_principal + (p_principal * p_interest_rate / 100.0),
    p_purpose, v_committee_id, 'proposed', p_due_date
  );
end;
$$;

create or replace function public.apply_welfare_loan_late_fees()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan record;
  v_months_overdue integer;
  v_new_months integer;
  v_increment numeric;
begin
  for v_loan in
    select id, due_date, late_fee_per_month, late_fee_months_charged
    from welfare_loans
    where status = 'active'
      and due_date is not null
      and due_date < current_date
      and coalesce(late_fee_per_month,0) > 0
  loop
    v_months_overdue := (extract(year from age(current_date, v_loan.due_date))::int * 12)
      + extract(month from age(current_date, v_loan.due_date))::int;
    v_new_months := greatest(v_months_overdue - coalesce(v_loan.late_fee_months_charged,0), 0);
    if v_new_months > 0 then
      v_increment := v_new_months * coalesce(v_loan.late_fee_per_month,0);
      update welfare_loans
      set late_fee_accrued = coalesce(late_fee_accrued,0) + v_increment,
          late_fee_months_charged = coalesce(late_fee_months_charged,0) + v_new_months
      where id = v_loan.id;
    end if;
  end loop;
end;
$$;

create or replace function public.approve_welfare_loan(
  p_committee_pin text,
  p_id text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan welfare_loans;
  v_committee_id text;
begin
  if not is_welfare_committee_pin(p_committee_pin) then
    raise exception 'Only Welfare Committee members can approve loans';
  end if;

  select id into v_committee_id from members where pin = p_committee_pin limit 1;

  select * into v_loan from welfare_loans where id = p_id;
  if v_loan.id is null then
    raise exception 'Loan not found';
  end if;
  if v_loan.status <> 'proposed' then
    raise exception 'Loan is not awaiting approval';
  end if;
  if v_loan.proposed_by = v_committee_id then
    raise exception 'The member who proposed this loan cannot also approve it';
  end if;

  if v_loan.approver_1 is null then
    update welfare_loans set approver_1 = v_committee_id where id = p_id;
  elsif v_loan.approver_1 <> v_committee_id and v_loan.approver_2 is null then
    update welfare_loans
    set approver_2 = v_committee_id, status = 'active', disbursed_date = current_date
    where id = p_id;
  elsif v_loan.approver_1 = v_committee_id then
    raise exception 'You have already approved this loan — a different committee member must give the second approval';
  end if;
end;
$$;

create or replace function public.record_loan_repayment(
  p_committee_pin text,
  p_loan_id text,
  p_repayment_id text,
  p_amount numeric,
  p_paid_date date
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loan welfare_loans;
  v_committee_id text;
  v_new_total numeric;
  v_total_due numeric;
begin
  if not is_welfare_committee_pin(p_committee_pin) then
    raise exception 'Only Welfare Committee members can record repayments';
  end if;

  perform apply_welfare_loan_late_fees();
  select id into v_committee_id from members where pin = p_committee_pin limit 1;

  select * into v_loan from welfare_loans where id = p_loan_id;
  if v_loan.id is null then
    raise exception 'Loan not found';
  end if;
  if v_loan.status <> 'active' then
    raise exception 'Loan is not active';
  end if;

  insert into welfare_loan_repayments (id, loan_id, amount, paid_date, recorded_by)
  values (p_repayment_id, p_loan_id, p_amount, p_paid_date, v_committee_id);

  v_new_total := v_loan.amount_repaid + p_amount;
  v_total_due := v_loan.amount_due + coalesce(v_loan.late_fee_accrued,0);

  update welfare_loans
  set amount_repaid = v_new_total,
      status = case when v_new_total >= v_total_due then 'closed' else status end
  where id = p_loan_id;
end;
$$;

-- ------------------------------------------------------------
-- 3) Grants + refresh the PostgREST schema cache so the app sees the changes.
-- ------------------------------------------------------------
grant execute on function public.propose_welfare_loan(text,text,text,numeric,numeric,numeric,text,date) to anon, authenticated;
grant execute on function public.apply_welfare_loan_late_fees() to anon, authenticated;
grant execute on function public.approve_welfare_loan(text,text) to anon, authenticated;
grant execute on function public.record_loan_repayment(text,text,text,numeric,date) to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- Done.
-- ============================================================
