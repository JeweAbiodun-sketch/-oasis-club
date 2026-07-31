-- ============================================================
-- Oasis Club App - Clear TEST data from the Welfare loan / fund section.
-- Per the club: no money has actually been disbursed yet; everything
-- currently in these tables was entered only for testing.
--
-- This wipes the four DB tables behind the Welfare "loan & fund" section:
--   welfare_loan_repayments  (repayments -> deleted first, FK to loans)
--   welfare_loans            (committee loans)
--   welfare_release_requests (fund disbursement approvals)
--   welfare_purse_entries    (fund release / expense ledger)
--
-- It does NOT touch member welfare CONTRIBUTIONS (those live in the
-- browser, not the database) nor any other club data.
--
-- DESTRUCTIVE: review the counts first if unsure (see SELECT block),
-- then run the DELETEs. Run in the Supabase SQL editor.
-- ============================================================

-- Optional: see what is about to be removed before you run the deletes.
-- select
--   (select count(*) from public.welfare_loan_repayments)  as repayments,
--   (select count(*) from public.welfare_loans)            as loans,
--   (select count(*) from public.welfare_release_requests) as release_requests,
--   (select count(*) from public.welfare_purse_entries)    as purse_entries;

begin;

delete from public.welfare_loan_repayments;
delete from public.welfare_loans;
delete from public.welfare_release_requests;
delete from public.welfare_purse_entries;

commit;

notify pgrst, 'reload schema';

-- ============================================================
-- Done. The Welfare loan & fund section is now empty and ready for
-- real entries. (The realtime subscription will refresh open apps.)
-- ============================================================
