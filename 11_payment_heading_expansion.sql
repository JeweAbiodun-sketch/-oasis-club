-- ============================================================
-- Oasis Club App — Payment heading expansion + joint approval
-- Run this against the live database, AFTER 06_payments_setup.sql.
-- Safe to re-run.
--
-- Two changes, by request:
--
-- 1) The UI's "What is this payment for?" dropdown has offered
--    Welfare contribution / Pledge / Grant for a while, but the
--    database's payment_type check constraint (and
--    submit_payment_evidence()'s own validation) never allowed
--    them — only 'dues' and 'building_project' — so submitting any
--    of those three has always failed. This adds them, plus a new
--    'loan' heading (loan repayment), to both the constraint and
--    the RPC's validation.
--
-- 2) approve_payment_evidence() now gives the Treasurer and
--    Financial Secretary equal authority to approve or reject proof
--    of payment. It also files the approved amount under its
--    correct heading label instead of lumping every non-dues
--    submission into a generic "Building Project contribution"
--    transaction line.
-- ============================================================

-- ============================================================
-- PART 1: allow the fuller set of payment headings.
-- ============================================================

alter table public.payment_submissions drop constraint if exists payment_submissions_payment_type_check;
alter table public.payment_submissions add constraint payment_submissions_payment_type_check
  check (payment_type in ('dues','building_project','welfare','pledge','grant','loan'));

create or replace function public.submit_payment_evidence(
  p_pin text,
  p_payment_type text,
  p_amount numeric,
  p_proof_url text,
  p_proof_name text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member_id text;
  v_new_id uuid;
begin
  select id into v_member_id from members
  where pin = p_pin and status not in ('suspended','dismissed');

  if v_member_id is null then
    raise exception 'PIN not recognized, or this member no longer has access';
  end if;

  if p_payment_type not in ('dues','building_project','welfare','pledge','grant','loan') then
    raise exception 'Not a recognized payment type';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero';
  end if;

  insert into payment_submissions (member_id, payment_type, amount, proof_url, proof_name)
  values (v_member_id, p_payment_type, p_amount, p_proof_url, p_proof_name)
  returning id into v_new_id;

  return v_new_id;
end;
$$;

-- ============================================================
-- PART 2: approval — Treasurer and Financial Secretary share the
-- same review authority, and each heading is recorded under its own
-- label rather than collapsing into "Building Project contribution".
-- ============================================================

create or replace function public.approve_payment_evidence(
  p_pin text,
  p_submission_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub record;
  v_member_name text;
  v_head_label text;
begin
  if not is_treasurer_or_financial_secretary_pin(p_pin) then
    raise exception 'The Treasurer and Financial Secretary can approve a payment submission';
  end if;

  select * into v_sub from payment_submissions where id = p_submission_id and status = 'pending';
  if v_sub is null then
    raise exception 'Submission not found or already reviewed';
  end if;

  select name into v_member_name from members where id = v_sub.member_id;

  if v_sub.payment_type = 'dues' then
    -- Deliberately additive (a member may submit evidence for several
    -- installments across the year). This differs from the manual
    -- "Edit dues paid" pencil icon on the Dues page, which overwrites
    -- the total outright -- that's intentional, not a bug to "fix".
    update members set dues_paid = coalesce(dues_paid,0) + v_sub.amount, updated_at = now() where id = v_sub.member_id;
  else
    v_head_label := case v_sub.payment_type
      when 'building_project' then 'Building Project contribution'
      when 'welfare' then 'Welfare contribution'
      when 'pledge' then 'Pledge'
      when 'grant' then 'Grant'
      when 'loan' then 'Loan repayment'
      else 'Payment'
    end;
    insert into transactions (id, desc_text, type, amount, date)
    values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' ('||v_head_label||')', 'income', v_sub.amount, current_date);
  end if;

  update payment_submissions
  set status = 'approved', reviewed_by = (select id from members where pin = p_pin limit 1), reviewed_at = now()
  where id = p_submission_id;
end;
$$;

-- ============================================================
-- Done.
-- ============================================================
