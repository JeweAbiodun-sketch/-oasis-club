-- ============================================================
-- Oasis Club — Welfare Committee Loans
-- Run this once in Supabase SQL Editor, alongside the earlier files.
-- ============================================================

-- 1. Loans table.
--    status: 'proposed' -> 'active' -> 'closed'  (or 'overdue', derived client-side from due_date)
--    Needs TWO distinct Welfare Committee member approvals before becoming 'active'.
create table if not exists welfare_loans (
  id text primary key,
  member_id text not null,                 -- borrower
  principal numeric not null,
  interest_rate numeric not null default 0,   -- percent, e.g. 5 for 5%
  late_fee_per_month numeric not null default 0,
  late_fee_accrued numeric not null default 0,
  late_fee_months_charged integer not null default 0,
  amount_due numeric not null,              -- principal + interest, computed at proposal time
  amount_repaid numeric not null default 0,
  purpose text not null,
  proposed_by text not null,                -- committee member PIN who proposed
  approver_1 text,                          -- committee member PIN, first approval
  approver_2 text,                          -- committee member PIN, second approval
  status text not null default 'proposed',  -- proposed | active | closed
  due_date date,
  disbursed_date date,
  created_at timestamptz not null default now()
);

create table if not exists welfare_loan_repayments (
  id text primary key,
  loan_id text not null references welfare_loans(id) on delete cascade,
  amount numeric not null,
  paid_date date not null,
  recorded_by text,
  created_at timestamptz not null default now()
);

alter table welfare_loans enable row level security;
alter table welfare_loan_repayments enable row level security;

alter table welfare_loans add column if not exists late_fee_per_month numeric not null default 0;
alter table welfare_loans add column if not exists late_fee_accrued numeric not null default 0;
alter table welfare_loans add column if not exists late_fee_months_charged integer not null default 0;

drop policy if exists "Allow read welfare loans" on welfare_loans;
create policy "Allow read welfare loans" on welfare_loans for select using (true);
drop policy if exists "Allow read welfare loan repayments" on welfare_loan_repayments;
create policy "Allow read welfare loan repayments" on welfare_loan_repayments for select using (true);

revoke insert, update, delete on welfare_loans from anon, authenticated;
revoke insert, update, delete on welfare_loan_repayments from anon, authenticated;

-- ------------------------------------------------------------
-- Helper: is this PIN a Welfare Committee member?
-- ------------------------------------------------------------
create or replace function is_welfare_committee_pin(p_pin text) returns boolean
language plpgsql
security definer
as $$
declare v_valid boolean;
begin
  select exists(
    select 1 from members where pin = p_pin and role = 'Welfare Committee'
  ) into v_valid;
  return v_valid;
end;
$$;

-- ------------------------------------------------------------
-- 2. Propose a loan (any Welfare Committee member).
-- ------------------------------------------------------------
create or replace function propose_welfare_loan(
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

-- ------------------------------------------------------------
-- Keep overdue fines in sync with the calendar.
-- Each full month after the due date adds the agreed fee once.
-- ------------------------------------------------------------
create or replace function apply_welfare_loan_late_fees()
returns void
language plpgsql
security definer
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

-- ------------------------------------------------------------
-- 3. Approve a loan. Needs two DIFFERENT committee members.
--    Becomes 'active' once the second distinct approval lands.
-- ------------------------------------------------------------
create or replace function approve_welfare_loan(
  p_committee_pin text,
  p_id text
) returns void
language plpgsql
security definer
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

-- ------------------------------------------------------------
-- 4. Record a repayment against an active loan.
-- ------------------------------------------------------------
create or replace function record_loan_repayment(
  p_committee_pin text,
  p_loan_id text,
  p_repayment_id text,
  p_amount numeric,
  p_paid_date date
) returns void
language plpgsql
security definer
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

grant execute on function is_welfare_committee_pin(text) to anon, authenticated;
grant execute on function propose_welfare_loan(text, text, text, numeric, numeric, numeric, text, date) to anon, authenticated;
grant execute on function apply_welfare_loan_late_fees() to anon, authenticated;
grant execute on function approve_welfare_loan(text, text) to anon, authenticated;
grant execute on function record_loan_repayment(text, text, text, numeric, date) to anon, authenticated;

alter publication supabase_realtime add table welfare_loans;
alter publication supabase_realtime add table welfare_loan_repayments;
