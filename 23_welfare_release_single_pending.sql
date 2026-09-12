-- ============================================================
-- Oasis Club App — one pending welfare release request at a time.
--
-- Forestalls duplicate disbursements at the database level: the Treasurer /
-- Financial Secretary cannot create a new welfare fund release request while an
-- earlier one is still awaiting the President's decision. This backs up the same
-- guard in the app UI, so it holds even across devices or rapid double-taps.
--
-- This CREATE OR REPLACE keeps request_welfare_release()'s existing behaviour
-- (see 10_president_release_approval.sql) and only adds the pending-check.
-- Safe to re-run. Run this in the Supabase SQL editor.
-- ============================================================

create or replace function public.request_welfare_release(
  p_officer_pin text,
  p_id text,
  p_amount numeric,
  p_description text,
  p_entry_date date
)
returns void
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not is_treasurer_or_financial_secretary_pin(p_officer_pin) then
    raise exception 'Only the Treasurer or Financial Secretary can request a welfare fund release';
  end if;

  -- Only one release request may be awaiting the President at a time.
  if exists (select 1 from welfare_release_requests where status = 'pending') then
    raise exception 'A welfare release request is already awaiting the President''s approval. Please wait for it to be approved or rejected before sending another.';
  end if;

  insert into welfare_release_requests (id, amount, description, entry_date, requested_by, status)
  values (p_id, p_amount, p_description, p_entry_date, null, 'pending');
end;
$function$;

grant execute on function public.request_welfare_release(text, text, numeric, text, date) to anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- Done.
-- ============================================================
