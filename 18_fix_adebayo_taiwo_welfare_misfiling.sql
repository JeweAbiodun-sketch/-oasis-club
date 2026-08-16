-- ============================================================
-- Oasis Club App — One-off data correction.
--
-- Incident (14 Aug 2026)
-- ----------------------
-- Adebayo Taiwo (member m007) made ONE ₦14,000 payment, but:
--   1. It was submitted under the wrong heading — "dues" — when it was
--      actually a WELFARE contribution.
--   2. The SAME receipt (proof file 1786737785703.jpg) was submitted
--      TWICE, ~1 min apart, and BOTH were approved.
--
-- Effect of the two dues approvals:
--   * members.dues_paid for m007 went 50,000 -> 78,000 (+14,000 twice).
--   * Two ₦14,000 "Annual dues" income lines were posted to Finance:
--       31cf95b4-f58c-4bb3-a406-37ee8aeb9ace  (20:15:58)
--       c3857d71-f06e-44f9-a4d7-9c2a2ac9b77b  (20:16:24)
--   * Nothing reached the Welfare Affair page (correct for a dues payment;
--     welfare only receives submissions filed under the Welfare heading).
--
-- Correct end state (as if it had been approved ONCE as welfare):
--   * dues_paid back to 50,000.
--   * ONE ₦14,000 income line in Finance, labelled "(Welfare contribution)".
--   * ONE ₦14,000 row on the Welfare Affair page, attached to the existing
--     2025/2026 levy event (wlf-lv-2526).
--   * The duplicate submission marked rejected; the surviving submission
--     reclassified to welfare so the member's history reads correctly.
--
-- Safe to re-run: dues_paid is SET to an absolute value (not decremented),
-- inserts use fixed ids with ON CONFLICT DO NOTHING, and deletes are by id.
-- Run in the Supabase SQL editor.
-- ============================================================

begin;

-- 1) Reverse BOTH wrongly-applied dues credits (50,000 is the pre-incident value).
update public.members
   set dues_paid = 50000,
       updated_at = now()
 where id = 'm007';

-- 2) Remove the two duplicate "Annual dues" Finance lines.
delete from public.transactions
 where id in (
   '31cf95b4-f58c-4bb3-a406-37ee8aeb9ace',
   'c3857d71-f06e-44f9-a4d7-9c2a2ac9b77b'
 );

-- 3) Post the single correct Welfare Finance receipt (money still in the books once).
insert into public.transactions (id, desc_text, type, amount, date)
values ('wlf-adj-m007-20260814', 'Adebayo Taiwo (Welfare contribution)', 'income', 14000, '2026-08-14')
on conflict (id) do nothing;

-- 4) Record the contribution on the Welfare Affair page, under the existing
--    2025/2026 levy event.
insert into public.welfare_contributions (id, event_id, member_id, amount, paid_date)
values ('wlf-lv-2526-m007', 'wlf-lv-2526', 'm007', 14000, '2026-08-14')
on conflict (id) do nothing;

-- 5) Tidy the submission history: reject the duplicate, reclassify the survivor.
update public.payment_submissions
   set status = 'rejected',
       rejection_reason = 'Duplicate of the same receipt — corrected 15 Aug 2026'
 where id = '39bb78cd-2bd9-483b-8b77-549e23fd3c3f';

update public.payment_submissions
   set payment_type = 'welfare'
 where id = '5ac0b52f-d438-4d7a-8aa8-cb3b8e618a91';

commit;

-- ------------------------------------------------------------
-- Verification (run separately after COMMIT). Expected:
--   members:               dues_paid = 50000
--   welfare_contributions: one row, amount 14000, event wlf-lv-2526
--   transactions:          one "(Welfare contribution)" line, no "Annual dues" 14000 on 2026-08-14
-- ------------------------------------------------------------
-- select id, name, dues_paid from public.members where id='m007';
-- select * from public.welfare_contributions where member_id='m007' and event_id='wlf-lv-2526';
-- select id, desc_text, amount, date from public.transactions
--   where desc_text ilike '%Taiwo%' and date='2026-08-14';
-- ============================================================
-- Done.
-- ============================================================
