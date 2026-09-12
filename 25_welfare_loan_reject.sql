-- ============================================================
-- Oasis Club App — allow a welfare loan PROPOSAL to be rejected with a reason.
--
-- Mirrors the welfare release-request reject flow: any Welfare Committee member
-- can reject a loan that is still 'proposed', optionally giving a reason that is
-- stored and shown on the loan card. Approved/active/closed loans cannot be
-- rejected. Idempotent. Run in the Supabase SQL editor.
-- ============================================================

alter table public.welfare_loans add column if not exists rejection_reason text;
alter table public.welfare_loans add column if not exists rejected_by      text;

create or replace function public.reject_welfare_loan(
  p_committee_pin text,
  p_id text,
  p_reason text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_committee_id text;
  v_loan welfare_loans;
begin
  if not is_welfare_committee_pin(p_committee_pin) then
    raise exception 'Only Welfare Committee members can reject loans';
  end if;

  select id into v_committee_id from members where pin = p_committee_pin limit 1;

  select * into v_loan from welfare_loans where id = p_id;
  if v_loan.id is null then
    raise exception 'Loan not found';
  end if;
  if v_loan.status <> 'proposed' then
    raise exception 'Only a proposed loan can be rejected';
  end if;

  update welfare_loans
  set status = 'rejected',
      rejection_reason = nullif(trim(coalesce(p_reason,'')),''),
      rejected_by = v_committee_id
  where id = p_id;
end;
$$;

grant execute on function public.reject_welfare_loan(text, text, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- Done.
-- ============================================================
