-- ============================================================
-- OPTIONAL one-time backfill. Run this ONCE, only AFTER
-- 14_dues_post_to_ledger.sql.
--
-- Dues that were already approved BEFORE migration 14 did not create
-- a `transactions` row. This inserts a receipt for every already-approved
-- dues submission so those historical approvals also show in the
-- financial statement.
--
-- WARNING: running this more than once will duplicate the receipts.
-- ============================================================

insert into transactions (id, desc_text, type, amount, date)
select gen_random_uuid()::text,
       coalesce(m.name,'Member')||' (Annual dues)',
       'income',
       ps.amount,
       coalesce(ps.reviewed_at::date, current_date)
from payment_submissions ps
left join members m on m.id = ps.member_id
where ps.payment_type = 'dues'
  and ps.status = 'approved';
