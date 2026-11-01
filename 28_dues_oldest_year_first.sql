-- ============================================================
-- Oasis Club App - Annual dues: oldest-year-first (rules 1-3)
-- Run ONCE in the Supabase SQL Editor, AFTER 27_dues_by_year.sql.
--
-- After this, members.dues_paid = TOTAL a member has ever paid towards annual dues.
-- The app splits that total across years: oldest unpaid year first, starting from
-- the financial year the member joined (30,000/yr through 2024/25, 50,000/yr from 2025/26).
-- approve_payment_evidence already ADDS to members.dues_paid, so it keeps working.
-- ============================================================

-- 1. Undo 27_dues_by_year.sql (per-year table + triggers are no longer used)
drop trigger  if exists trg_roll_dues_year          on public.club_meta;
drop trigger  if exists trg_sync_dues_current_year  on public.members;
drop function if exists public.roll_dues_year();
drop function if exists public.sync_dues_current_year();
drop function if exists public.officer_set_dues_year(text, text, text, numeric);
drop table    if exists public.dues_payments;

-- 2. Correct joined dates so the first dues year is right (first day of that financial year)
update public.members set joined = date '2021-10-01' where lower(btrim(name)) = 'ayorinde toyin adeniran';
update public.members set joined = date '2022-10-01' where lower(btrim(name)) = 'olatoye adekunle';
update public.members set joined = date '2022-10-01' where lower(btrim(name)) = 'ajibade adetayo';
update public.members set joined = date '2024-10-01' where lower(btrim(name)) = 'aina adewale';
update public.members set joined = date '2024-10-01' where lower(btrim(name)) = 'aborisade funso';

-- 3. Total annual dues paid to date, from the ledger (to 30 Mar 2026) + 25 Oct 2026 receipts
update public.members m
   set dues_paid = v.total, updated_at = now()
  from (values
    ('Ayodeji Bisi',               170000),
    ('Adebayo Lanre',              220000),
    ('Akanni Babatunde',           170000),
    ('Adebayo Taiwo',              195000),
    ('Olatunde Adekunle',          200000),
    ('Olawuyi Abiodun',            220000),
    ('Awoyemi Sunkanmi',           220000),
    ('Olatunji Matthew',           220000),
    ('Ogunleye Oladele',           220000),
    ('Babalola Adewumi',           125000),
    ('Ayorinde Toyin Adeniran',    165000),
    ('Olatoye Adekunle',           145000),
    ('Ajibade Adetayo',            100000),
    ('Onifade Mojisola Okeniyi',   130000),
    ('Aina Adewale',               100000),
    ('Aborisade Funso',             50000),
    ('Olayemi Bunmi',               25000),
    ('Awogbami Muyiwa',                 0),
    ('Tunde Badmos',                20000),
    ('Adebisi Olasunkanmi Joseph',      0),
    ('Abilomu David Adekunle',          0)
  ) as v(n, total)
 where lower(btrim(m.name)) = lower(btrim(v.n));

notify pgrst, 'reload schema';

-- 4. Check: 21 rows expected, each with the total above and the right joined date
select name, joined, dues_paid from public.members order by name;
