-- ============================================================
-- Oasis Club App - Make approved DUES payments also appear in the
-- financial statement (Overview "Account balance" + Financial year).
-- Run AFTER 12_payment_evidence_ledger_routing.sql. Safe to re-run.
--
-- The Overview balance and the Financial year page are built purely
-- from the `transactions` ledger. Until now approve_payment_evidence()
-- filed an approved dues payment ONLY as an increment to members.dues_paid
-- (shown on the Dues page) but never wrote a `transactions` row, so dues
-- income never appeared in the financial statement. This version keeps
-- everything migration 12 did and ALSO records a receipt in `transactions`
-- for approved dues, like pledges / welfare / grants already do.
--
-- NOTE: from now on do NOT also hand-enter approved dues as manual ledger
-- entries on the Financial year page, or they will be counted twice.
-- ============================================================

drop function if exists public.approve_payment_evidence(text, text);

create or replace function public.approve_payment_evidence(
  p_pin text,
  p_submission_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_sub record;
  v_member_name text;
  v_reviewer_id text;
  v_head_label text;
  v_active_loan_count integer;
  v_loan welfare_loans;
  v_total_due numeric;
begin
  if not is_treasurer_or_financial_secretary_pin(p_pin) then
    raise exception 'The Treasurer and Financial Secretary can approve a payment submission';
  end if;

  select * into v_sub from payment_submissions where id = p_submission_id and status = 'pending';
  if v_sub is null then
    raise exception 'Submission not found or already reviewed';
  end if;

  select name into v_member_name from members where id = v_sub.member_id;
  select id into v_reviewer_id from members where pin = p_pin limit 1;

  if v_sub.payment_type = 'dues' then
    -- Additive: a member may submit evidence for several installments.
    update members set dues_paid = coalesce(dues_paid,0) + v_sub.amount, updated_at = now() where id = v_sub.member_id;

    -- Also record the cash in the financial statement (Overview balance
    -- and Financial year receipts).
    insert into transactions (id, desc_text, type, amount, date)
    values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' (Annual dues)', 'income', v_sub.amount, current_date);

  elsif v_sub.payment_type = 'pledge' then
    insert into transactions (id, desc_text, type, amount, date)
    values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' (Pledge)', 'income', v_sub.amount, current_date);
    insert into club_pledges (id, member_id, donor_name, amount, purpose, pledge_date, recorded_by)
    values (gen_random_uuid()::text, v_sub.member_id, coalesce(v_member_name,'Member'), v_sub.amount, 'Approved payment evidence', current_date, v_reviewer_id);

  elsif v_sub.payment_type = 'loan' then
    perform apply_welfare_loan_late_fees();
    select count(*) into v_active_loan_count from welfare_loans
      where member_id = v_sub.member_id and status = 'active';

    if v_active_loan_count = 1 then
      select * into v_loan from welfare_loans
        where member_id = v_sub.member_id and status = 'active' limit 1;

      insert into welfare_loan_repayments (id, loan_id, amount, paid_date, recorded_by)
      values (gen_random_uuid()::text, v_loan.id, v_sub.amount, current_date, v_reviewer_id);

      v_total_due := v_loan.amount_due + coalesce(v_loan.late_fee_accrued,0);
      update welfare_loans
        set amount_repaid = amount_repaid + v_sub.amount,
            status = case when (amount_repaid + v_sub.amount) >= v_total_due then 'closed' else status end
        where id = v_loan.id;

      insert into transactions (id, desc_text, type, amount, date)
      values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' (Loan repayment)', 'income', v_sub.amount, current_date);
    else
      insert into transactions (id, desc_text, type, amount, date)
      values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' (Loan repayment - apply manually)', 'income', v_sub.amount, current_date);
    end if;

  else
    v_head_label := case v_sub.payment_type
      when 'building_project' then 'Building Project contribution'
      when 'welfare' then 'Welfare contribution'
      when 'grant' then 'Grant'
      else 'Payment'
    end;
    insert into transactions (id, desc_text, type, amount, date)
    values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' ('||v_head_label||')', 'income', v_sub.amount, current_date);
  end if;

  update payment_submissions
  set status = 'approved', reviewed_by = v_reviewer_id, reviewed_at = now()
  where id = p_submission_id;
end;
$fn$;

notify pgrst, 'reload schema';
