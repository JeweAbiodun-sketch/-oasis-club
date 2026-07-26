-- ============================================================
-- Oasis Club App — Route approved payment evidence into the
-- correct DEDICATED ledger, not just the general Finance statement.
-- Run this against the live database, AFTER 11_payment_heading_expansion.sql.
-- Safe to re-run (it only replaces one function).
--
-- Background
-- ----------
-- 11_payment_heading_expansion.sql made approve_payment_evidence()
-- file every non-dues submission as a labelled line in the general
-- Finance ledger (`transactions`). That keeps the cash in the club's
-- statement of account, but three payment types each have their own
-- dedicated page that the Finance line never reaches:
--
--   * Pledge          -> the Pledges page  (club_pledges table)
--   * Loan repayment  -> Welfare loans     (welfare_loans / welfare_loan_repayments)
--   * Welfare         -> Welfare Affair page (stored in the browser, localStorage
--                        'oasis-welfare-v1' — NOT in the database, so it CANNOT be
--                        written here; index.html's approvePayment() lodges it
--                        client-side after this RPC succeeds.)
--
-- This migration makes approval ADDITIVE: the durable Finance receipt
-- is still recorded (so the money can never fall out of the books),
-- and on top of that a Pledge also lands on the Pledges page and a
-- Loan repayment is applied against the member's active welfare loan.
--
-- Loan safety: a repayment is only auto-applied when the member has
-- EXACTLY ONE active loan (the unambiguous case). With zero or several
-- active loans it is left for the Welfare Committee to record manually
-- through their normal two-committee flow — the Finance line is tagged
-- "(Loan repayment — apply manually)" so nothing is silently lost.
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
  v_reviewer_id text;
  v_head_label text;
  v_active_loan_count integer;
  v_loan welfare_loans;
  v_total_due numeric;
begin
  if not is_treasurer_or_financial_secretary_pin(p_pin) then
    raise exception 'Only the Treasurer or Financial Secretary can approve a payment submission';
  end if;

  select * into v_sub from payment_submissions where id = p_submission_id and status = 'pending';
  if v_sub is null then
    raise exception 'Submission not found or already reviewed';
  end if;

  select name into v_member_name from members where id = v_sub.member_id;
  select id into v_reviewer_id from members where pin = p_pin limit 1;

  if v_sub.payment_type = 'dues' then
    -- Deliberately additive (a member may submit evidence for several
    -- installments across the year). This differs from the manual
    -- "Edit dues paid" pencil icon on the Dues page, which overwrites
    -- the total outright -- that's intentional, not a bug to "fix".
    update members set dues_paid = coalesce(dues_paid,0) + v_sub.amount, updated_at = now() where id = v_sub.member_id;

  elsif v_sub.payment_type = 'pledge' then
    -- Durable cash receipt in the statement of account...
    insert into transactions (id, desc_text, type, amount, date)
    values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' (Pledge)', 'income', v_sub.amount, current_date);
    -- ...and a matching entry on the Pledges page.
    insert into club_pledges (id, member_id, donor_name, amount, purpose, pledge_date, recorded_by)
    values (gen_random_uuid()::text, v_sub.member_id, coalesce(v_member_name,'Member'), v_sub.amount, 'Approved payment evidence', current_date, v_reviewer_id);

  elsif v_sub.payment_type = 'loan' then
    -- Only auto-apply when there is exactly one active loan for this member.
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
      -- Zero or several active loans: don't guess. Record the cash and flag it.
      insert into transactions (id, desc_text, type, amount, date)
      values (gen_random_uuid()::text, coalesce(v_member_name,'Member')||' (Loan repayment — apply manually)', 'income', v_sub.amount, current_date);
    end if;

  else
    -- building_project, welfare, grant -> labelled Finance receipt.
    -- (Welfare additionally shows on the Welfare page; that record is
    --  added client-side by approvePayment() since it lives in the
    --  browser, not the database.)
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
$$;

-- ============================================================
-- Done. approve_payment_evidence() keeps its existing signature and
-- grants, so nothing else needs changing on the database side.
-- ============================================================
